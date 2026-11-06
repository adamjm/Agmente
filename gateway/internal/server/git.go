package server

// Read-only git state for phones (PLAN 3.14, FR-27, FR-29, FR-30, D-034, D-035):
// _agmente/git/status, git/diff and git/log. Every command runs through runGit.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const (
	rpcGitFailed = -32000
	logDefault   = 50
	logMax       = 200
)

// secretPatterns is the FR-30 deny-list. A path is secret when any of its components matches one
// (case-insensitive), so everything under a folder called "secrets" is hidden too.
var secretPatterns = []string{".env", ".env.*", "*.pem", "*.key", "*.p12", "*.p8", "id_rsa*", "*secret*", ".npmrc", ".netrc"}

func isSecretPath(p string) bool {
	for _, part := range strings.Split(p, "/") {
		lower := strings.ToLower(part)
		for _, pat := range secretPatterns {
			if ok, _ := path.Match(pat, lower); ok {
				return true
			}
		}
	}
	return false
}

// secretExcludes are pathspecs that make git leave the deny-list out of a whole-tree diff.
func secretExcludes() []string {
	out := []string{}
	for _, pat := range secretPatterns {
		out = append(out, ":(exclude,glob,icase)**/"+pat, ":(exclude,glob,icase)**/"+pat+"/**")
	}
	return out
}

type gitFile struct {
	Path    string `json:"path"`
	Status  string `json:"status"`
	Staged  bool   `json:"staged"`
	Added   *int64 `json:"added"`
	Removed *int64 `json:"removed"`

	orig string // the old path of a rename or copy
}

// gitState is what the last git/status said about a project: the only source of diff paths (FR-29).
type gitState struct {
	paths map[string]*gitFile
}

type gitStates struct {
	mu sync.Mutex
	m  map[string]*gitState
}

func (g *gitStates) set(project string, st *gitState) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.m == nil {
		g.m = map[string]*gitState{}
	}
	g.m[project] = st
}

func (g *gitStates) get(project string) *gitState {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.m[project]
}

// gitProject resolves params.projectId.
func (s *Server) gitProject(ctx context.Context, params *jsonv.Value) (*store.Project, *rpcError) {
	id, ok := params.Get("projectId").StringValue()
	if !ok || id == "" {
		return nil, invalidParams("projectId is required")
	}
	p, err := s.store.ProjectByID(ctx, id)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	return p, nil
}

// gitError maps a failed git run to the phone. Git's own text stays on the gateway.
func gitError(err error) *rpcError {
	var ee *gitExitError
	switch {
	case errors.Is(err, errGitTimeout):
		return &rpcError{Code: rpcGitFailed, Message: "git timeout"}
	case errors.As(err, &ee) && strings.Contains(ee.Stderr, "not a git repository"):
		return &rpcError{Code: rpcGitFailed, Message: "not a git repository"}
	default:
		return &rpcError{Code: rpcGitFailed, Message: "git failed"}
	}
}

func (s *Server) gitStatus(ctx context.Context, params *jsonv.Value) (any, *rpcError) {
	p, rerr := s.gitProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	res, _, rerr := s.statusResult(ctx, *p)
	if rerr != nil {
		return nil, rerr
	}
	return res, nil
}

// statusResult runs git status for a project, remembers its paths as the diff allow-list (FR-29),
// and returns the result and its hash. The watcher (watch.go) calls it too.
func (s *Server) statusResult(ctx context.Context, project store.Project) (map[string]any, string, *rpcError) {
	p := &project
	var (
		wg                sync.WaitGroup
		st, unstg, cached gitResult
		stErr, uErr, cErr error
		statusArgs        = []string{"status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"}
		numstat           = []string{"diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z"}
		numstatCached     = append(append([]string{}, numstat...), "--cached")
	)
	run := func(res *gitResult, err *error, args []string) {
		defer wg.Done()
		*res, *err = s.runGit(ctx, *p, nil, nil, args...)
	}
	wg.Add(3)
	go run(&st, &stErr, statusArgs)
	go run(&unstg, &uErr, numstat)
	go run(&cached, &cErr, numstatCached)
	wg.Wait()
	for _, err := range []error{stErr, uErr, cErr} {
		if err != nil {
			return nil, "", gitError(err)
		}
	}
	branch, files := parseStatus(st.Out)
	counts := map[string][2]int64{}
	binary := map[string]bool{}
	for _, out := range [][]byte{unstg.Out, cached.Out} {
		for path, c := range parseNumstat(out) {
			if c[0] < 0 {
				binary[path] = true
				continue
			}
			prev := counts[path]
			counts[path] = [2]int64{prev[0] + c[0], prev[1] + c[1]}
		}
	}
	state := &gitState{paths: map[string]*gitFile{}}
	for i := range files {
		f := &files[i]
		if c, ok := counts[f.Path]; ok && !binary[f.Path] {
			a, r := c[0], c[1]
			f.Added, f.Removed = &a, &r
		}
		state.paths[f.Path] = f
		if f.orig != "" {
			state.paths[f.orig] = f
		}
	}
	s.gits.set(p.ID, state)
	// The hash covers the status, the line counts, and the size and modification time of each
	// listed file, so any further edit to a modified or untracked file changes it, even one that
	// leaves the status and the counts as they were. A touch changes it too: one extra refresh.
	var stamps bytes.Buffer
	for _, f := range files {
		if info, err := os.Lstat(filepath.Join(p.Path, f.Path)); err == nil {
			fmt.Fprintf(&stamps, "%s\x00%d\x00%d\x00", f.Path, info.Size(), info.ModTime().UnixNano())
		}
	}
	sum := sha256.Sum256(bytes.Join([][]byte{st.Out, unstg.Out, cached.Out, stamps.Bytes()}, []byte{0, 0}))
	branch["files"] = files
	branch["hash"] = hex.EncodeToString(sum[:])
	branch["truncated"] = st.Truncated
	return branch, branch["hash"].(string), nil
}

// parseStatus reads `status --porcelain=v2 --branch -z`.
func parseStatus(out []byte) (map[string]any, []gitFile) {
	res := map[string]any{"branch": nil, "upstream": nil, "ahead": 0, "behind": 0}
	files := []gitFile{}
	fields := bytes.Split(out, []byte{0})
	for i := 0; i < len(fields); i++ {
		line := string(fields[i])
		switch {
		case strings.HasPrefix(line, "# branch.head "):
			if h := strings.TrimPrefix(line, "# branch.head "); h != "(detached)" {
				res["branch"] = h
			}
		case strings.HasPrefix(line, "# branch.upstream "):
			res["upstream"] = strings.TrimPrefix(line, "# branch.upstream ")
		case strings.HasPrefix(line, "# branch.ab "):
			var a, b int
			if _, err := fmt.Sscanf(line, "# branch.ab +%d -%d", &a, &b); err == nil {
				res["ahead"], res["behind"] = a, b
			}
		case strings.HasPrefix(line, "1 "):
			if parts := strings.SplitN(line, " ", 9); len(parts) == 9 {
				files = append(files, statusFile(parts[1], parts[8], ""))
			}
		case strings.HasPrefix(line, "2 "):
			if parts := strings.SplitN(line, " ", 10); len(parts) == 10 {
				orig := ""
				if i+1 < len(fields) {
					i++
					orig = string(fields[i])
				}
				files = append(files, statusFile(parts[1], parts[9], orig))
			}
		case strings.HasPrefix(line, "u "):
			if parts := strings.SplitN(line, " ", 11); len(parts) == 11 {
				f := statusFile(parts[1], parts[10], "")
				f.Status = "conflicted"
				files = append(files, f)
			}
		case strings.HasPrefix(line, "? "):
			files = append(files, gitFile{Path: line[2:], Status: "untracked"})
		}
	}
	return res, files
}

func statusFile(xy, path, orig string) gitFile {
	letter := xy[1]
	if letter == '.' {
		letter = xy[0]
	}
	names := map[byte]string{'M': "modified", 'A': "added", 'D': "deleted", 'R': "renamed", 'C': "copied", 'T': "type_changed"}
	status := names[letter]
	if status == "" {
		status = "modified"
	}
	return gitFile{Path: path, Status: status, Staged: xy[0] != '.', orig: orig}
}

// parseNumstat reads `diff --numstat -z`: path -> {added, removed}; {-1, -1} for a binary file.
func parseNumstat(out []byte) map[string][2]int64 {
	res := map[string][2]int64{}
	fields := bytes.Split(out, []byte{0})
	for i := 0; i < len(fields); i++ {
		parts := strings.SplitN(string(fields[i]), "\t", 3)
		if len(parts) != 3 {
			continue
		}
		path := parts[2]
		if path == "" && i+2 < len(fields) { // rename: "a\tr\t", then old, then new
			path = string(fields[i+2])
			i += 2
		}
		a, errA := strconv.ParseInt(parts[0], 10, 64)
		r, errR := strconv.ParseInt(parts[1], 10, 64)
		if errA != nil || errR != nil {
			res[path] = [2]int64{-1, -1}
			continue
		}
		res[path] = [2]int64{a, r}
	}
	return res
}

func (s *Server) gitDiff(ctx context.Context, params *jsonv.Value) (any, *rpcError) {
	p, rerr := s.gitProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	staged := false
	if v := params.Get("staged"); !v.IsNull() {
		if v.Kind != jsonv.Bool {
			return nil, invalidParams("staged must be true or false")
		}
		staged = v.B
	}
	from, to := params.Get("fromTree"), params.Get("toTree")
	if !from.IsNull() || !to.IsNull() {
		f, okF := from.StringValue()
		t, okT := to.StringValue()
		if !okF || !okT || !treeID.MatchString(f) || !treeID.MatchString(t) {
			return nil, invalidParams("fromTree and toTree must both be tree ids")
		}
		path := ""
		if pv := params.Get("path"); !pv.IsNull() {
			var ok bool
			if path, ok = pv.StringValue(); !ok || path == "" {
				return nil, invalidParams("path must be a file path from this diff")
			}
		}
		out, rerr := s.gitTreeDiff(ctx, *p, f, t, path)
		if rerr != nil {
			return nil, rerr
		}
		return out, nil
	}
	base := []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color"}
	if staged {
		base = append(base, "--cached")
	}

	if pv := params.Get("path"); !pv.IsNull() {
		target, ok := pv.StringValue()
		if !ok || target == "" {
			return nil, invalidParams("path must be a file path from the last status")
		}
		state := s.gits.get(p.ID)
		if state == nil {
			return nil, invalidParams("call git/status first: a diff path must come from the current status")
		}
		f := state.paths[target]
		if f == nil {
			return nil, invalidParams("path is not in the current status")
		}
		if isSecretFor(p.DenyPaths, target) {
			return hiddenDiff([]string{target}), nil
		}
		var res gitResult
		var err error
		if f.Status == "untracked" {
			res, err = s.runGit(ctx, *p, nil, nil, "diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--", "/dev/null", target)
			var ee *gitExitError
			if errors.As(err, &ee) && ee.Code == 1 { // --no-index exits 1 when the files differ
				err = nil
			}
		} else {
			res, err = s.runGit(ctx, *p, nil, nil, append(base, "--", ":(literal)"+target)...)
		}
		if err != nil {
			return nil, gitError(err)
		}
		return map[string]any{"diff": string(res.Out), "truncated": res.Truncated, "hidden": []string{}}, nil
	}

	// Whole tree: the deny-list is excluded by git, then its changed files are named.
	args := append(append(base, "--", "."), secretExcludesFor(p.DenyPaths)...)
	res, err := s.runGit(ctx, *p, nil, nil, args...)
	if err != nil {
		return nil, gitError(err)
	}
	hidden := []string{}
	if state := s.gits.get(p.ID); state != nil {
		for name, f := range state.paths {
			if f.Staged == staged && f.orig != name && isSecretFor(p.DenyPaths, name) {
				hidden = append(hidden, name)
			}
		}
	}
	sort.Strings(hidden)
	out := hiddenDiff(hidden)
	out["diff"] = string(res.Out) + out["diff"].(string)
	out["truncated"] = res.Truncated
	return out, nil
}

// hiddenDiff names files whose content the deny-list hides.
func hiddenDiff(names []string) map[string]any {
	var b strings.Builder
	for _, n := range names {
		fmt.Fprintf(&b, "secret file changed: %s (content hidden)\n", n)
	}
	return map[string]any{"diff": b.String(), "truncated": false, "hidden": names}
}

func (s *Server) gitLog(ctx context.Context, params *jsonv.Value) (any, *rpcError) {
	p, rerr := s.gitProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	limit := int64(logDefault)
	if v := params.Get("limit"); !v.IsNull() {
		n, ok := v.Int()
		if !ok || n < 1 || n > logMax {
			return nil, invalidParams("limit must be an integer from 1 to %d", logMax)
		}
		limit = n
	}
	skip := int64(0)
	if v := params.Get("cursor"); !v.IsNull() {
		str, ok := v.StringValue()
		n, err := strconv.ParseInt(str, 10, 64)
		if !ok || err != nil || n < 0 {
			return nil, invalidParams("cursor must be a value from a previous git/log")
		}
		skip = n
	}
	res, err := s.runGit(ctx, *p, nil, nil, "log", "--no-color", "--no-show-signature", "-z",
		"--format=%H%x1f%an%x1f%aI%x1f%s", "-n", strconv.FormatInt(limit+1, 10), "--skip", strconv.FormatInt(skip, 10))
	var ee *gitExitError
	if errors.As(err, &ee) && strings.Contains(ee.Stderr, "does not have any commits") {
		return map[string]any{"commits": []any{}}, nil
	}
	if err != nil {
		return nil, gitError(err)
	}
	commits := []map[string]string{}
	for _, rec := range bytes.Split(res.Out, []byte{0}) {
		parts := strings.SplitN(strings.TrimLeft(string(rec), "\n"), "\x1f", 4)
		if len(parts) != 4 {
			continue
		}
		commits = append(commits, map[string]string{"hash": parts[0], "shortHash": parts[0][:min(7, len(parts[0]))], "author": parts[1], "date": parts[2], "subject": parts[3]})
	}
	out := map[string]any{}
	if int64(len(commits)) > limit {
		commits = commits[:limit]
		out["nextCursor"] = strconv.FormatInt(skip+limit, 10)
	}
	out["commits"] = commits
	return out, nil
}
