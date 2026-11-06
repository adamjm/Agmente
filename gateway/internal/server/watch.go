package server

// git/changed (PLAN 3.16, FR-27, NFR-9, D-037). A socket that has asked for a project's git status
// gets `_agmente/git/changed {projectId, hash}` when that status changes, debounced 500 ms and at
// most twice a second. While at least one socket is watching a project, the gateway looks at the
// project's files every 500 ms; with none, it looks at nothing.
//
// It looks with stat, not with an OS file watcher, so it adds no dependency and behaves the same
// on macOS and Linux (D-037). A change in the fingerprint of the files only starts a check: the
// notification goes out when git's own status hash differs from the last one sent, so a change to
// an ignored file sends nothing.

import (
	"context"
	"encoding/binary"
	"hash/fnv"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
)

const (
	watchInterval = 500 * time.Millisecond // NFR-9: the debounce, and so at most 2 notifications a second
	watchMaxFiles = 200000
)

// skipDirs are folders of dependencies and build caches that hold many files and are almost
// always ignored by git. A change inside one starts no check (git/status still sees it).
var skipDirs = map[string]bool{
	"node_modules": true, ".venv": true, "venv": true, "__pycache__": true, "target": true,
	".gradle": true, "Pods": true, ".build": true, "DerivedData": true, ".next": true, ".cache": true,
}

type gitWatch struct {
	mu       sync.Mutex
	clients  map[*client]struct{}
	lastHash string
}

type gitWatches struct {
	mu sync.Mutex
	m  map[string]*gitWatch
}

// watchBaseline is the fingerprint of a project's folder taken before a git/status runs, when no
// watch runs yet (D-065). A new watch starts from it, so a change made while git runs is seen, and
// a change inside a skipped folder is not (the status would list it, but no check is gated by it).
// It returns 0 when there is nothing to take; the watch then checks once, which is harmless.
func (s *Server) watchBaseline(ctx context.Context, params *jsonv.Value) uint64 {
	pid, ok := params.Get("projectId").StringValue()
	if !ok {
		return 0
	}
	s.watches.mu.Lock()
	_, running := s.watches.m[pid]
	s.watches.mu.Unlock()
	if running {
		return 0
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil || p == nil {
		return 0
	}
	return fingerprint(p.Path, newWatchSkipper(p.WatchSkip))
}

// watchGit adds a socket to a project's watchers. hash is the status hash it was just given, and
// baseline the fingerprint from watchBaseline, used only when this call starts the watch.
func (s *Server) watchGit(c *client, projectID, hash string, baseline uint64) {
	s.watches.mu.Lock()
	defer s.watches.mu.Unlock()
	if s.watches.m == nil {
		s.watches.m = map[string]*gitWatch{}
	}
	w := s.watches.m[projectID]
	if w == nil {
		w = &gitWatch{clients: map[*client]struct{}{}, lastHash: hash}
		s.watches.m[projectID] = w
		s.audit.Log("git_watch_start", with(c.who, audit.Fields{Project: projectID}))
		go s.watchLoop(projectID, w, baseline)
	}
	w.mu.Lock()
	w.clients[c] = struct{}{}
	w.mu.Unlock()
}

// live returns the sockets still open, dropping the others.
func (w *gitWatch) live() []*client {
	w.mu.Lock()
	defer w.mu.Unlock()
	var out []*client
	for c := range w.clients {
		if c.closing.Load() || c.ctx.Err() != nil {
			delete(w.clients, c)
			continue
		}
		out = append(out, c)
	}
	return out
}

func (s *Server) watchLoop(projectID string, w *gitWatch, baseline uint64) {
	defer func() {
		if r := recover(); r != nil {
			s.audit.Log("panic", audit.Fields{Project: projectID, Reason: "git_watch"})
		}
	}()
	stop := func() bool { // under the map lock, so a socket that joins now starts a new loop
		s.watches.mu.Lock()
		defer s.watches.mu.Unlock()
		if len(w.live()) > 0 {
			return false
		}
		delete(s.watches.m, projectID)
		s.audit.Log("git_watch_stop", audit.Fields{Project: projectID})
		return true
	}
	ctx := context.Background()
	project, err := s.store.ProjectByID(ctx, projectID)
	if err != nil || project == nil {
		stop()
		return
	}
	// Compared with the fingerprint from before the status (watchBaseline), so a change after it
	// starts a check. A change before it is in the status already and needs none.
	last := baseline
	dirty := false
	ticker := time.NewTicker(watchInterval)
	defer ticker.Stop()
	for range ticker.C {
		if stop() {
			return
		}
		// Read the project again each tick, so an addWatchSkip takes effect without a restart (D-065).
		if p, err := s.store.ProjectByID(ctx, projectID); err == nil && p != nil {
			project = p
		}
		now := fingerprint(project.Path, newWatchSkipper(project.WatchSkip))
		if now != last {
			last, dirty = now, true
			continue // wait for a quiet interval: the debounce
		}
		if !dirty {
			continue
		}
		dirty = false
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		_, hash, rerr := s.statusResult(cctx, *project)
		cancel()
		if rerr != nil {
			continue
		}
		w.mu.Lock()
		changed := hash != w.lastHash
		w.lastHash = hash
		w.mu.Unlock()
		if !changed {
			continue
		}
		msg := jsonv.Obj()
		msg.Set("jsonrpc", jsonv.Str("2.0"))
		msg.Set("method", jsonv.Str("_agmente/git/changed"))
		params := jsonv.Obj()
		params.Set("projectId", jsonv.Str(projectID))
		params.Set("hash", jsonv.Str(hash))
		msg.Set("params", params)
		line := msg.Marshal()
		for _, c := range w.live() {
			c.send(line)
		}
		s.audit.Log("rpc", audit.Fields{Dir: "out", Method: "_agmente/git/changed", Project: projectID})
	}
}

// fingerprint hashes the name, size, modification time and mode of every file in the project,
// without .git (only its HEAD, index, packed-refs and refs, which a commit or checkout changes)
// and without the folders in skipDirs or in the project's watchSkip (D-065).
func fingerprint(root string, skip watchSkipper) uint64 {
	h := fnv.New64a()
	var buf [24]byte
	add := func(rel string, info fs.FileInfo) {
		h.Write([]byte(rel))
		binary.LittleEndian.PutUint64(buf[0:], uint64(info.Size()))
		binary.LittleEndian.PutUint64(buf[8:], uint64(info.ModTime().UnixNano()))
		binary.LittleEndian.PutUint64(buf[16:], uint64(info.Mode()))
		h.Write(buf[:])
	}
	count := 0
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			if rel == ".git" {
				fingerprintGit(path, add)
				return filepath.SkipDir
			}
			if rel != "." && skip.skips(d.Name(), filepath.ToSlash(rel)) { // the root itself is never skipped
				return filepath.SkipDir
			}
			// A folder's own modification time changes when an entry is added or removed, even
			// in a skipped folder below it; the entries themselves are in the hash, so the
			// folder is not (git does not track empty folders either).
			return nil
		}
		if count++; count > watchMaxFiles {
			return filepath.SkipAll
		}
		if info, err := d.Info(); err == nil {
			add(rel, info)
		}
		return nil
	})
	return h.Sum64()
}

func fingerprintGit(gitDir string, add func(string, fs.FileInfo)) {
	for _, name := range []string{"HEAD", "index", "packed-refs", "MERGE_HEAD"} {
		if info, err := os.Lstat(filepath.Join(gitDir, name)); err == nil {
			add(".git/"+name, info)
		}
	}
	_ = filepath.WalkDir(filepath.Join(gitDir, "refs"), func(path string, d fs.DirEntry, err error) error {
		if err == nil {
			if info, err := d.Info(); err == nil {
				rel, _ := filepath.Rel(filepath.Dir(gitDir), path)
				add(rel, info)
			}
		}
		return nil
	})
}
