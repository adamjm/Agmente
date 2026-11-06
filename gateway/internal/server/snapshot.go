package server

// Turn snapshots and git/turnDiff (PLAN 3.15, FR-27, D-036). At the start and end of each turn
// the gateway records the project's files as a git tree. It never runs `git add`, so no clean
// filter, hook or attribute program can run (T-27): files are hashed with `hash-object
// --no-filters`, put in a temporary index, and written as a tree. The objects go to a store of
// the gateway's own, with the repository's objects as an alternate, so the repository is not
// changed: its index, refs and object folder stay as they were.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const (
	snapshotStartBudget = 20 * time.Second // the prompt waits at most this long for the start snapshot
	snapshotEndBudget   = 30 * time.Second
	turnDiffWait        = 35 * time.Second
)

var treeID = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

// snapshotEnv is the object store the snapshot commands use.
func (s *Server) snapshotDir(p store.Project) string {
	return filepath.Join(s.projectHome(p.ID), "snapshots")
}

func (s *Server) snapshotEnv(p store.Project, gitDir string, extra ...string) []string {
	env := []string{
		"GIT_OBJECT_DIRECTORY=" + filepath.Join(s.snapshotDir(p), "objects"),
		"GIT_ALTERNATE_OBJECT_DIRECTORIES=" + filepath.Join(gitDir, "objects"),
	}
	return append(env, extra...)
}

// takeSnapshot records the project's current files as a tree and returns its id.
func (s *Server) takeSnapshot(ctx context.Context, p store.Project) (string, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var (
		wg                      sync.WaitGroup
		cached, others, deleted gitResult
		gitDirRes               gitResult
		errs                    [4]error
	)
	run := func(i int, res *gitResult, args ...string) {
		defer wg.Done()
		*res, errs[i] = s.runGit(ctx, p, nil, nil, args...)
	}
	wg.Add(4)
	go run(0, &cached, "ls-files", "-s", "-z")
	go run(1, &others, "ls-files", "-z", "--others", "--exclude-standard")
	go run(2, &deleted, "ls-files", "-z", "--deleted")
	go run(3, &gitDirRes, "rev-parse", "--absolute-git-dir")
	wg.Wait()
	for i, res := range []gitResult{cached, others, deleted, gitDirRes} {
		if errs[i] != nil {
			return "", errs[i]
		}
		if res.Truncated {
			return "", errors.New("the file list is too long for a snapshot")
		}
	}
	gitDir := strings.TrimSpace(string(gitDirRes.Out))
	if !filepath.IsAbs(gitDir) {
		return "", errors.New("unexpected git directory")
	}

	gone := map[string]bool{}
	for _, f := range bytes.Split(deleted.Out, []byte{0}) {
		gone[string(f)] = true
	}
	var paths []string
	seen := map[string]bool{}
	add := func(path string) {
		if path == "" || seen[path] || gone[path] || strings.ContainsAny(path, "\n\r") {
			return // hash-object --stdin-paths reads one path per line
		}
		seen[path] = true
		paths = append(paths, path)
	}
	for _, rec := range bytes.Split(cached.Out, []byte{0}) {
		if _, path, ok := strings.Cut(string(rec), "\t"); ok {
			add(path)
		}
	}
	for _, f := range bytes.Split(others.Out, []byte{0}) {
		add(string(f))
	}

	// Only regular files go in. A symlink would be hashed as the file it points to, and a pipe
	// would block the hash; the gateway looks at the type itself, without opening anything.
	var files, modes []string
	for _, rel := range paths {
		info, err := os.Lstat(filepath.Join(p.Path, rel))
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		mode := "100644"
		if info.Mode()&0o111 != 0 {
			mode = "100755"
		}
		files, modes = append(files, rel), append(modes, mode)
	}

	if err := os.MkdirAll(filepath.Join(s.snapshotDir(p), "objects"), 0o700); err != nil {
		return "", err
	}
	hashes := [][]byte{}
	if len(files) > 0 {
		res, err := s.runGit(ctx, p, s.snapshotEnv(p, gitDir), []byte(strings.Join(files, "\n")+"\n"), "hash-object", "--no-filters", "-w", "--stdin-paths")
		if err != nil {
			return "", err
		}
		if res.Truncated {
			return "", errors.New("the hash list is too long for a snapshot")
		}
		hashes = bytes.Fields(res.Out)
		if len(hashes) != len(files) {
			return "", fmt.Errorf("hash-object returned %d ids for %d files", len(hashes), len(files))
		}
	}
	var info bytes.Buffer
	for i, rel := range files {
		fmt.Fprintf(&info, "%s %s 0\t%s\x00", modes[i], hashes[i], rel)
	}
	var rnd [6]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		return "", err
	}
	index := filepath.Join(s.snapshotDir(p), "index-"+hex.EncodeToString(rnd[:]))
	defer os.Remove(index)
	env := s.snapshotEnv(p, gitDir, "GIT_INDEX_FILE="+index)
	if _, err := s.runGit(ctx, p, env, info.Bytes(), "update-index", "-z", "--index-info"); err != nil {
		return "", err
	}
	res, err := s.runGit(ctx, p, env, nil, "write-tree")
	if err != nil {
		return "", err
	}
	tree := strings.TrimSpace(string(res.Out))
	if !treeID.MatchString(tree) {
		return "", errors.New("unexpected tree id")
	}
	return tree, nil
}

// turnSnapshots tracks the end snapshots that are still being taken.
type turnSnapshots struct {
	mu      sync.Mutex
	pending map[string]chan struct{} // "<session>/<turn>" -> closed when the end snapshot is stored
	turn    map[string]int64         // session -> the turn that is running
}

func snapKey(session string, turn int64) string { return fmt.Sprintf("%s/%d", session, turn) }

// snapshotTurnStart takes the start snapshot of the turn that was just logged, and remembers its
// number. It waits for the snapshot, because the agent must not change files first. A failure is
// audited and the turn goes on without a diff.
func (a *projectAgent) snapshotTurnStart(sessionID string) {
	ctx, cancel := context.WithTimeout(context.Background(), snapshotStartBudget)
	defer cancel()
	turn, err := a.s.store.TurnCount(ctx, sessionID)
	if err != nil || turn == 0 {
		return
	}
	a.s.snaps.mu.Lock()
	if a.s.snaps.turn == nil {
		a.s.snaps.turn = map[string]int64{}
	}
	a.s.snaps.turn[sessionID] = turn
	a.s.snaps.mu.Unlock()
	tree, err := a.s.takeSnapshot(ctx, a.project())
	if err != nil {
		a.s.audit.Log("snapshot_failed", a.fields(audit.Fields{Reason: "start"}))
		return
	}
	if err := a.s.store.SetStartTree(ctx, sessionID, turn, tree); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "snapshot"}))
	}
}

// snapshotTurnEnd takes the end snapshot in the background; turnDiff waits for it.
func (a *projectAgent) snapshotTurnEnd(sessionID string) {
	a.s.snaps.mu.Lock()
	turn, ok := a.s.snaps.turn[sessionID]
	delete(a.s.snaps.turn, sessionID)
	if !ok {
		a.s.snaps.mu.Unlock()
		return
	}
	if a.s.snaps.pending == nil {
		a.s.snaps.pending = map[string]chan struct{}{}
	}
	done := make(chan struct{})
	a.s.snaps.pending[snapKey(sessionID, turn)] = done
	a.s.snaps.mu.Unlock()
	go func() {
		defer func() {
			if r := recover(); r != nil {
				a.s.audit.Log("panic", a.fields(audit.Fields{Reason: fmt.Sprintf("%T", r)}))
			}
			a.s.snaps.mu.Lock()
			delete(a.s.snaps.pending, snapKey(sessionID, turn))
			a.s.snaps.mu.Unlock()
			close(done)
		}()
		ctx, cancel := context.WithTimeout(context.Background(), snapshotEndBudget)
		defer cancel()
		tree, err := a.s.takeSnapshot(ctx, a.project())
		if err != nil {
			a.s.audit.Log("snapshot_failed", a.fields(audit.Fields{Reason: "end"}))
			return
		}
		if err := a.s.store.SetEndTree(ctx, sessionID, turn, tree); err != nil {
			a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "snapshot"}))
		}
	}()
}

// gitTreeDiff diffs two trees with the deny-list applied, using the snapshot object store.
func (s *Server) gitTreeDiff(ctx context.Context, p store.Project, from, to string, path string) (map[string]any, *rpcError) {
	gitDirRes, err := s.runGit(ctx, p, nil, nil, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return nil, gitError(err)
	}
	env := s.snapshotEnv(p, strings.TrimSpace(string(gitDirRes.Out)))
	names, err := s.runGit(ctx, p, env, nil, "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", from, to, "--")
	if err != nil {
		return nil, gitError(err)
	}
	changed := map[string]bool{}
	for _, f := range bytes.Split(names.Out, []byte{0}) {
		if len(f) > 0 {
			changed[string(f)] = true
		}
	}
	hidden := []string{}
	for name := range changed {
		if isSecretFor(p.DenyPaths, name) {
			hidden = append(hidden, name)
		}
	}
	sort.Strings(hidden)
	args := []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color", from, to, "--"}
	if path != "" {
		if !changed[path] {
			return nil, invalidParams("path is not in this diff")
		}
		if isSecretFor(p.DenyPaths, path) {
			return hiddenDiff([]string{path}), nil
		}
		args = append(args, ":(literal)"+path)
	} else {
		args = append(append(args, "."), secretExcludesFor(p.DenyPaths)...)
	}
	res, err := s.runGit(ctx, p, env, nil, args...)
	if err != nil {
		return nil, gitError(err)
	}
	out := map[string]any{"diff": string(res.Out), "truncated": res.Truncated, "hidden": []string{}}
	if path == "" {
		stub := hiddenDiff(hidden)
		out["diff"] = string(res.Out) + stub["diff"].(string)
		out["hidden"] = hidden
	}
	return out, nil
}

// gitTurnDiff answers _agmente/git/turnDiff {sessionId, turn}.
func (s *Server) gitTurnDiff(ctx context.Context, params *jsonv.Value) (any, *rpcError) {
	sid, ok := params.Get("sessionId").StringValue()
	if !ok || sid == "" {
		return nil, invalidParams("sessionId is required")
	}
	turn, ok := params.Get("turn").Int()
	if !ok || turn < 1 {
		return nil, invalidParams("turn must be a positive integer")
	}
	projectID, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	if projectID == "" {
		return nil, invalidParams("unknown session")
	}
	p, err := s.store.ProjectByID(ctx, projectID)
	if err != nil || p == nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	s.snaps.mu.Lock()
	wait := s.snaps.pending[snapKey(sid, turn)]
	s.snaps.mu.Unlock()
	if wait != nil {
		select {
		case <-wait:
		case <-time.After(turnDiffWait):
		case <-ctx.Done():
			return nil, &rpcError{Code: rpcGitFailed, Message: "cancelled"}
		}
	}
	start, end, _, err := s.store.Snapshot(ctx, sid, turn)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read snapshots"}
	}
	switch {
	case start == "":
		return nil, &rpcError{Code: rpcGitFailed, Message: "no snapshot for this turn"}
	case end == "":
		s.snaps.mu.Lock()
		running := s.snaps.turn[sid] == turn
		s.snaps.mu.Unlock()
		if running {
			return nil, &rpcError{Code: rpcGitFailed, Message: "turn is still running"}
		}
		return nil, &rpcError{Code: rpcGitFailed, Message: "no snapshot for this turn"}
	}
	out, rerr := s.gitTreeDiff(ctx, *p, start, end, "")
	if rerr != nil {
		return nil, rerr
	}
	out["fromTree"], out["toTree"] = start, end
	return out, nil
}
