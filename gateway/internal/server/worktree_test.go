package server

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

type worktreeEnv struct {
	s      *Server
	db     *store.Store
	root   string
	parent store.Project
	log    *bytes.Buffer
}

// newWorktreeEnv is a host-runner server with one root, runners "default" and "claude", and a git
// repository with one commit registered as project "aaaaaaaaaaaa".
func newWorktreeEnv(t *testing.T) *worktreeEnv {
	t.Helper()
	s, db, root, _ := folderTestServer(t)
	s.cfg.Runners = []config.AgentRunner{
		{ID: "default", Name: "Bob", Command: []string{"/bin/false"}},
		{ID: "claude", Name: "Claude Code", Command: []string{"/bin/false"}},
	}
	s.cfg.DefaultRunner = "default"
	log := &bytes.Buffer{}
	s.audit = audit.New(log)
	repo := filepath.Join(root, "app")
	if err := os.Mkdir(repo, 0o700); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "init", "-q", "-b", "main")
	if err := os.WriteFile(filepath.Join(repo, "a.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "add", ".")
	gitIn(t, repo, "commit", "-q", "-m", "one")
	parent := store.Project{ID: "aaaaaaaaaaaa", Name: "App", Path: repo, DefaultMode: "agent", Runner: "default",
		DenyPaths: []string{"*.pem"}, WatchSkip: []string{"dist"}, Created: "2026-11-27T00:00:00.000Z"}
	if err := db.CreateProject(context.Background(), parent); err != nil {
		t.Fatal(err)
	}
	return &worktreeEnv{s: s, db: db, root: root, parent: parent, log: log}
}

func callWorktree(t *testing.T, s *Server, params string) (map[string]any, *rpcError) {
	t.Helper()
	var gotErr *rpcError
	var got any
	called := 0
	reply := func(_ *jsonv.Value, result any, rerr *rpcError) { called++; got, gotErr = result, rerr }
	v, err := jsonv.Parse([]byte(params))
	if err != nil {
		t.Fatal(err)
	}
	s.serveCreateWorktree(audit.Who{Identity: "owner", Device: "phone"}, jsonv.Str("1"), v, reply)
	if called != 1 {
		t.Fatalf("reply called %d times", called)
	}
	m, _ := got.(map[string]any)
	return m, gotErr
}

func wantRefused(t *testing.T, e *worktreeEnv, params, contains string) {
	t.Helper()
	before := projectCount(t, e.db)
	_, rerr := callWorktree(t, e.s, params)
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("%s: want -32602, got %+v", params, rerr)
	}
	if !strings.Contains(rerr.Message, contains) {
		t.Errorf("message %q does not contain %q", rerr.Message, contains)
	}
	if n := projectCount(t, e.db); n != before {
		t.Errorf("projects %d -> %d after a refusal", before, n)
	}
}

func TestWorktreeCreateRegistersAChildProject(t *testing.T) {
	e := newWorktreeEnv(t)
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa","runner":"claude"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	path, _ := out["path"].(string)
	if filepath.Dir(path) != e.root {
		t.Errorf("path %q is not a sibling of the parent in the root %q", path, e.root)
	}
	if !isInsideRoots(path, e.s.roots) {
		t.Errorf("path %q is outside the roots", path)
	}
	prefix := e.parent.Path + "-claude-"
	if !strings.HasPrefix(path, prefix) || len(path) != len(prefix)+8 {
		t.Errorf("path %q is not <parent>-claude-<8 hex>", path)
	}
	suffix := strings.TrimPrefix(path, prefix)
	branch := "acpcode/claude/" + suffix
	if out["branch"] != branch || out["parentId"] != "aaaaaaaaaaaa" || out["runner"] != "claude" {
		t.Errorf("reply = %v", out)
	}
	if out["name"] != "App (Claude Code)" || out["defaultMode"] != "agent" || out["autoApprove"] != false {
		t.Errorf("reply = %v", out)
	}
	child, err := e.db.ProjectByID(context.Background(), out["id"].(string))
	if err != nil || child == nil {
		t.Fatalf("child not stored: %v", err)
	}
	if child.ParentID != e.parent.ID || child.Branch != branch || child.Runner != "claude" || child.Path != path {
		t.Errorf("stored child = %+v", *child)
	}
	if strings.Join(child.DenyPaths, ",") != "*.pem" || strings.Join(child.WatchSkip, ",") != "dist" {
		t.Errorf("deny/skip not copied: %+v", *child)
	}
	if _, err := os.Stat(e.s.projectHome(child.ID)); err != nil {
		t.Errorf("no project home: %v", err)
	}
	if got := gitIn(t, path, "rev-parse", "--abbrev-ref", "HEAD"); got != branch {
		t.Errorf("worktree is on %q, want %q", got, branch)
	}
	if _, err := os.Stat(filepath.Join(path, "a.txt")); err != nil {
		t.Errorf("worktree has no checkout: %v", err)
	}
	logged := e.log.String()
	if !strings.Contains(logged, `"event":"worktree_create"`) || !strings.Contains(logged, child.ID) {
		t.Errorf("no audit line: %s", logged)
	}
	if strings.Contains(logged, e.root) {
		t.Errorf("audit line holds a path: %s", logged)
	}
}

func TestWorktreeDefaultsToTheParentsRunner(t *testing.T) {
	e := newWorktreeEnv(t)
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	if out["runner"] != "default" || out["name"] != "App (Bob)" || !strings.Contains(out["path"].(string), "-default-") {
		t.Errorf("reply = %v", out)
	}
}

func TestWorktreeRefusals(t *testing.T) {
	e := newWorktreeEnv(t)
	wantRefused(t, e, `{"projectId":"nope"}`, "unknown project")
	wantRefused(t, e, `{}`, "projectId is required")
	wantRefused(t, e, `{"projectId":"aaaaaaaaaaaa","runner":"nosuch"}`, "runner must be")
	wantRefused(t, e, `{"projectId":"aaaaaaaaaaaa","runner":7}`, "runner must be")

	// not a git repository
	plain := filepath.Join(e.root, "plain")
	if err := os.Mkdir(plain, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := e.db.CreateProject(context.Background(), store.Project{ID: "bbbbbbbbbbbb", Name: "plain", Path: plain, Runner: "default"}); err != nil {
		t.Fatal(err)
	}
	wantRefused(t, e, `{"projectId":"bbbbbbbbbbbb"}`, "not a git repository")

	// a repository with no commit
	empty := filepath.Join(e.root, "empty")
	if err := os.Mkdir(empty, 0o700); err != nil {
		t.Fatal(err)
	}
	gitIn(t, empty, "init", "-q", "-b", "main")
	if err := e.db.CreateProject(context.Background(), store.Project{ID: "cccccccccccc", Name: "empty", Path: empty, Runner: "default"}); err != nil {
		t.Fatal(err)
	}
	wantRefused(t, e, `{"projectId":"cccccccccccc"}`, "at least one commit")

	// a folder inside a repository is not the repository
	sub := filepath.Join(e.parent.Path, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := e.db.CreateProject(context.Background(), store.Project{ID: "dddddddddddd", Name: "sub", Path: sub, Runner: "default"}); err != nil {
		t.Fatal(err)
	}
	wantRefused(t, e, `{"projectId":"dddddddddddd"}`, "not a git repository")

	// a worktree project cannot have a worktree
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	wantRefused(t, e, `{"projectId":"`+out["id"].(string)+`"}`, "worktree project cannot")
}

func TestWorktreeNeedsTheSrtRunner(t *testing.T) {
	for _, kind := range []string{"apple", "podman"} {
		e := newWorktreeEnv(t)
		e.s.cfg.Runner.Kind = kind
		wantRefused(t, e, `{"projectId":"aaaaaaaaaaaa"}`, "separate worktrees need the srt runner")
		entries, _ := filepath.Glob(e.parent.Path + "-*")
		if len(entries) != 0 {
			t.Errorf("%s: a folder was made: %v", kind, entries)
		}
	}
}

func TestWorktreeRemoveUndoesTheWorktreeAndBranch(t *testing.T) {
	e := newWorktreeEnv(t)
	path := e.parent.Path + "-claude-deadbeef"
	gitIn(t, e.parent.Path, "worktree", "add", "-q", "-b", "acpcode/claude/deadbeef", path)
	e.s.removeWorktree(e.parent, path, "acpcode/claude/deadbeef")
	if _, err := os.Lstat(path); err == nil {
		t.Error("the folder is left behind")
	}
	if got := gitIn(t, e.parent.Path, "branch", "--list", "acpcode/*"); got != "" {
		t.Errorf("branch left behind: %q", got)
	}
	if got := gitIn(t, e.parent.Path, "worktree", "list", "--porcelain"); strings.Contains(got, "deadbeef") {
		t.Errorf("worktree left registered: %s", got)
	}
}

// The srt settings of a worktree project: the git folders it needs, never hooks or config.
func TestWorktreeSrtSettings(t *testing.T) {
	e := newWorktreeEnv(t)
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa","runner":"claude"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	child, _ := e.db.ProjectByID(context.Background(), out["id"].(string))
	cfg := &config.Config{Roots: []string{e.root}, StateDir: e.s.cfg.StateDir, Runner: config.Runner{Kind: "srt", SRT: "/opt/homebrew/bin/srt"}}
	r := &srtRunner{cfg: cfg}
	home := e.s.projectHome(child.ID)
	s := r.settings(*child, home, srtSpec{})

	common := filepath.Join(e.parent.Path, ".git")
	wt := filepath.Join(common, "worktrees", filepath.Base(child.Path))
	write := strings.Join(s.Filesystem.AllowWrite, "\n")
	for _, want := range []string{wt, filepath.Join(common, "objects"), filepath.Join(common, "refs"), filepath.Join(common, "logs"), filepath.Join(common, "packed-refs")} {
		if !contains(s.Filesystem.AllowWrite, want) {
			t.Errorf("allowWrite lacks %s:\n%s", want, write)
		}
	}
	for _, bad := range []string{filepath.Join(common, "hooks"), filepath.Join(common, "config"), common, e.parent.Path} {
		if contains(s.Filesystem.AllowWrite, bad) {
			t.Errorf("allowWrite holds %s", bad)
		}
	}
	for _, w := range s.Filesystem.AllowWrite {
		if strings.HasPrefix(w, filepath.Join(common, "hooks")) || strings.HasPrefix(w, filepath.Join(common, "config")) {
			t.Errorf("allowWrite holds %s", w)
		}
	}
	if !contains(s.Filesystem.AllowRead, common) {
		t.Errorf("allowRead lacks the common git dir: %v", s.Filesystem.AllowRead)
	}
	if contains(s.Filesystem.AllowRead, e.parent.Path) {
		t.Errorf("the parent's working files are readable: %v", s.Filesystem.AllowRead)
	}
	if !contains(s.Filesystem.DenyRead, e.root) {
		t.Errorf("the project root is no longer denied: %v", s.Filesystem.DenyRead)
	}

	// The gateway's own git commands may write the shared config, never hooks.
	g := r.settings(*child, home, srtSpec{gitConfig: true})
	if !contains(g.Filesystem.AllowWrite, filepath.Join(common, "config")) || contains(g.Filesystem.AllowWrite, filepath.Join(common, "hooks")) {
		t.Errorf("git spec allowWrite = %v", g.Filesystem.AllowWrite)
	}

	// The same child with a .git file that points at a git folder of another repository (no
	// back-link to this folder) gets nothing extra.
	forged := store.Project{ID: "ffffffffffff", Path: filepath.Join(e.root, "forged")}
	if err := os.Mkdir(forged.Path, 0o700); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(common, "worktrees", filepath.Base(child.Path))
	if err := os.WriteFile(filepath.Join(forged.Path, ".git"), []byte("gitdir: "+other+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := r.settings(forged, e.s.projectHome(forged.ID), srtSpec{})
	if contains(f.Filesystem.AllowWrite, other) || contains(f.Filesystem.AllowRead, common) {
		t.Errorf("a forged .git file widened the sandbox: %v", f.Filesystem.AllowWrite)
	}
}

func TestSrtSettingsAreUnchangedForAnOrdinaryProject(t *testing.T) {
	e := newWorktreeEnv(t)
	cfg := &config.Config{Roots: []string{e.root}, StateDir: e.s.cfg.StateDir, Runner: config.Runner{Kind: "srt", SRT: "/opt/homebrew/bin/srt"}}
	r := &srtRunner{cfg: cfg}
	home := e.s.projectHome(e.parent.ID)
	s := r.settings(e.parent, home, srtSpec{})
	if got, want := strings.Join(s.Filesystem.AllowWrite, " "), strings.Join(uniq([]string{e.parent.Path, home}), " "); got != want {
		t.Errorf("allowWrite = %q, want %q", got, want)
	}
	if got, want := strings.Join(s.Filesystem.AllowRead, " "), strings.Join(uniq([]string{e.parent.Path, home}), " "); got != want {
		t.Errorf("allowRead = %q, want %q", got, want)
	}
	// While a worktree is being made, the parent's git may write that one folder, then it may not.
	release := allowPendingWorktree(e.parent.Path, e.parent.Path+"-x-1")
	during := r.settings(e.parent, home, srtSpec{gitConfig: true})
	release()
	after := r.settings(e.parent, home, srtSpec{gitConfig: true})
	if !contains(during.Filesystem.AllowWrite, e.parent.Path+"-x-1") || contains(after.Filesystem.AllowWrite, e.parent.Path+"-x-1") {
		t.Errorf("pending allowance: during %v after %v", during.Filesystem.AllowWrite, after.Filesystem.AllowWrite)
	}
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

// A turn in a worktree project shows its edited file in the turn diff: the snapshot finds the
// objects in the parent's git folder (--git-common-dir).
func TestSnapshotOfAWorktreeProject(t *testing.T) {
	e := newWorktreeEnv(t)
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	child, _ := e.db.ProjectByID(context.Background(), out["id"].(string))
	ctx := context.Background()
	start, err := e.s.takeSnapshot(ctx, *child)
	if err != nil {
		t.Fatalf("start snapshot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child.Path, "a.txt"), []byte("two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	end, err := e.s.takeSnapshot(ctx, *child)
	if err != nil {
		t.Fatalf("end snapshot: %v", err)
	}
	diff, rerr := e.s.gitTreeDiff(ctx, *child, start, end, "")
	if rerr != nil {
		t.Fatalf("diff: %+v", rerr)
	}
	text, _ := diff["diff"].(string)
	if !strings.Contains(text, "-one") || !strings.Contains(text, "+two") || !strings.Contains(text, "a.txt") {
		t.Errorf("diff = %q", text)
	}
	// The parent's own repository is untouched: no stray files in its index or work tree.
	if got := gitIn(t, e.parent.Path, "status", "--porcelain"); got != "" {
		t.Errorf("parent status = %q", got)
	}
}

func TestCommonGitDirIsTheSameForAnOrdinaryRepo(t *testing.T) {
	e := newWorktreeEnv(t)
	res, err := e.s.runGit(context.Background(), e.parent, nil, nil, "rev-parse", "--git-common-dir")
	if err != nil {
		t.Fatal(err)
	}
	abs, err := e.s.runGit(context.Background(), e.parent, nil, nil, "rev-parse", "--absolute-git-dir")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := commonGitDir(e.parent, res.Out), strings.TrimSpace(string(abs.Out)); got != want {
		t.Errorf("common dir %q, absolute git dir %q", got, want)
	}
}

// The push scripts read and neutralize the common git folder's config in a worktree project, where
// .git is a file.
func TestPushConfigStepWorksInAWorktree(t *testing.T) {
	e := newWorktreeEnv(t)
	gitIn(t, e.parent.Path, "config", "--local", "remote.origin.url", "https://github.com/owner/repo.git")
	gitIn(t, e.parent.Path, "config", "--local", "credential.helper", "!echo hostile")
	gitIn(t, e.parent.Path, "config", "--local", "core.sshCommand", "touch "+filepath.Join(e.root, "should-not-exist"))
	gitIn(t, e.parent.Path, "config", "--local", "remote.origin.pushurl", "https://evil.example/x.git")
	out, rerr := callWorktree(t, e.s, `{"projectId":"aaaaaaaaaaaa"}`)
	if rerr != nil {
		t.Fatalf("refused: %+v", rerr)
	}
	child, _ := e.db.ProjectByID(context.Background(), out["id"].(string))
	if fi, err := os.Lstat(filepath.Join(child.Path, ".git")); err != nil || !fi.Mode().IsRegular() {
		t.Fatalf(".git of the worktree is not a file: %v", err)
	}
	home := e.s.projectHome(child.ID)
	res, err := e.s.runner.oneOff(context.Background(), *child, home, oneOffCmd{argv: []string{"sh", "-c", pushConfigScript, "sh", ""}, vars: gitEnv(home, nil)}, nil)
	if err != nil {
		t.Fatalf("config step: %v", err)
	}
	cfg := parsePushConfig(res.Out)
	if urls := cfg.remotes["origin"]; len(urls) != 1 || urls[0] != "https://github.com/owner/repo.git" {
		t.Errorf("origin = %v", urls)
	}
	if cfg.head != "refs/heads/"+child.Branch {
		t.Errorf("head = %q, want the worktree's branch", cfg.head)
	}
	if !objectIDPattern.MatchString(cfg.headCommit) {
		t.Errorf("headcommit = %q", cfg.headCommit)
	}
	want := strings.TrimSpace(gitIn(t, e.parent.Path, "hash-object", ".git/config"))
	if cfg.hash != want {
		t.Errorf("hash = %q, want the hash of the common config %q", cfg.hash, want)
	}
	left := strings.ToLower(gitIn(t, e.parent.Path, "config", "--local", "--list"))
	for _, key := range []string{"credential.helper", "core.sshcommand", "pushurl"} {
		if strings.Contains(left, key) {
			t.Errorf("common config still holds %s:\n%s", key, left)
		}
	}
	// The push step's own check: the same hash passes, a changed config stops it (exit 3).
	run := func(hash string) error {
		cmd := exec.Command("sh", "-c", `set -eu`+pushNeutralize+`[ "$(git hash-object "$cfgfile")" = "$1" ] || exit 3`, "sh", hash)
		cmd.Dir = child.Path
		cmd.Env = gitEnv(home, nil)
		return cmd.Run()
	}
	if err := run(cfg.hash); err != nil {
		t.Errorf("unchanged config refused: %v", err)
	}
	if err := run(strings.Repeat("0", 40)); err == nil {
		t.Error("a changed config was accepted")
	}
}
