package server

// Unit tests for git at project creation and the push path (D-105). The push tests run the real
// step scripts on the host with hostRunner, and stub the one command that has network access.

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// failingRunner fails the git command whose argv holds failOn, and runs every other command.
type failingRunner struct {
	runner
	failOn string
}

func (r failingRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	for _, a := range argv {
		if a == r.failOn {
			return gitResult{}, errors.New("stub failure")
		}
	}
	return r.runner.exec(ctx, p, home, argv, extraEnv, stdin)
}

// recordingRunner keeps every one-off command and refuses to run the network one.
type recordingRunner struct {
	runner
	calls []oneOffCmd
}

func (r *recordingRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	r.calls = append(r.calls, c)
	if c.network {
		return gitResult{}, errors.New("stub: the push container does not run in unit tests")
	}
	return r.runner.oneOff(ctx, p, home, c, stdin)
}

func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.invalid"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func createParams(t *testing.T, parent, name string, extra map[string]any) *jsonv.Value {
	t.Helper()
	m := map[string]any{"createFolder": true, "name": name, "path": parent}
	for k, v := range extra {
		m[k] = v
	}
	return jsonParams(t, m)
}

func TestRemoteRules(t *testing.T) {
	hosts := []string{"github.com"}
	ok := []string{"https://github.com/owner/repo.git", "https://GitHub.com/owner/repo", "https://github.com/a/b_c.d-e.git"}
	for _, raw := range ok {
		if host, rerr := checkGitRemote(raw, hosts); rerr != nil || host != "github.com" {
			t.Errorf("%q should be accepted: host %q, %+v", raw, host, rerr)
		}
	}
	bad := map[string]string{
		"http://github.com/x/y.git":                       "https://",
		"ssh://git@github.com/x/y.git":                    "https://",
		"git@github.com:x/y.git":                          "https://",
		"ext::sh -c touch% /tmp/x":                        "spaces",
		"file:///etc/passwd":                              "https://",
		"-oProxyCommand=x":                                "https://",
		"https://user:pw@github.com/x/y":                  "user name",
		"https://u@github.com/x/y":                        "user name",
		"https://github.com:443/x/y.git":                  "port",
		"https://evil.example/x/y.git":                    "allow-list",
		"https://github.com/":                             "repository path",
		"https://github.com/x?y=1":                        "query",
		"https://github.com/x/../y":                       "repository path",
		"https://github.com/x y":                          "spaces",
		"https://github.com/x#frag":                       "query",
		"https://github.com/x\n":                          "spaces",
		"https://github.com/owner/é.git":                  "ASCII",
		"https://github.com/" + strings.Repeat("a", 2100): "characters",
	}
	for raw, want := range bad {
		_, rerr := checkGitRemote(raw, hosts)
		if rerr == nil || !strings.Contains(rerr.Message, want) {
			t.Errorf("%q should be refused (%s), got %+v", raw, want, rerr)
		}
		if rerr != nil && strings.Contains(rerr.Message, "pw") {
			t.Errorf("%q: the refusal text repeats the URL: %q", raw, rerr.Message)
		}
	}
}

func TestGitInitCreatesRepositoryAndOrigin(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	p, folderCreated, gitRes, rerr := s.createProject(context.Background(), createParams(t, root, "fresh", map[string]any{
		"gitInit": true, "gitRemote": "https://github.com/owner/repo.git",
	}))
	if rerr != nil {
		t.Fatalf("create: %+v", rerr)
	}
	if !folderCreated || gitRes == nil {
		t.Fatalf("folderCreated %v, git %+v", folderCreated, gitRes)
	}
	if !gitRes.Initialized || gitRes.Branch != "" || !gitRes.Unborn || gitRes.Remote == nil || *gitRes.Remote != "https://github.com/owner/repo.git" {
		t.Fatalf("git result: %+v", gitRes)
	}
	folder := filepath.Join(root, "fresh")
	if info, err := os.Stat(filepath.Join(folder, ".git")); err != nil || !info.IsDir() {
		t.Fatalf(".git: %v", err)
	}
	if got := gitIn(t, folder, "config", "--local", "remote.origin.url"); got != "https://github.com/owner/repo.git" {
		t.Fatalf("origin = %q", got)
	}
	if got := gitIn(t, folder, "symbolic-ref", "HEAD"); got != "refs/heads/main" {
		t.Fatalf("HEAD = %q", got)
	}
	if _, err := os.Stat(s.projectHome(p.ID)); err != nil {
		t.Fatalf("the project home: %v", err)
	}
}

func TestGitRemoteRefusedBeforeTheFolderExists(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	_, _, _, rerr := s.createProject(context.Background(), createParams(t, root, "refused", map[string]any{
		"gitInit": true, "gitRemote": "http://github.com/owner/repo.git",
	}))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want -32602, got %+v", rerr)
	}
	if _, err := os.Lstat(filepath.Join(root, "refused")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the folder exists after a refusal: %v", err)
	}
}

func TestGitOptionsNeedANewFolderAndAnOrigin(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	existing := filepath.Join(root, "existing")
	if err := os.Mkdir(existing, 0o700); err != nil {
		t.Fatal(err)
	}
	cases := []map[string]any{
		{"path": existing, "gitInit": true},
		{"createFolder": true, "gitRemote": "https://github.com/o/r.git"}, // remote without gitInit
	}
	for i, c := range cases {
		base := map[string]any{"name": "x", "path": root, "createFolder": true}
		if i == 0 {
			base = map[string]any{"name": "x", "path": existing}
		}
		for k, v := range c {
			base[k] = v
		}
		_, _, _, rerr := s.createProject(context.Background(), jsonParams(t, base))
		if rerr == nil || rerr.Code != rpcInvalidParams {
			t.Fatalf("case %d: want -32602, got %+v", i, rerr)
		}
	}
	if _, err := os.Lstat(filepath.Join(root, "x")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused create made a folder: %v", err)
	}
	if _, err := os.Stat(filepath.Join(existing, ".git")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a refused create touched an existing folder")
	}
}

func TestRollbackRemovesFolderAndTheGitItMade(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	// git init succeeds and writes .git; the remote step then fails, so the call must undo both.
	s.runner = failingRunner{runner: s.runner, failOn: "remote"}
	_, _, _, rerr := s.createProject(context.Background(), createParams(t, root, "rolled", map[string]any{
		"gitInit": true, "gitRemote": "https://github.com/owner/repo.git",
	}))
	if rerr == nil || rerr.Code != rpcInternal {
		t.Fatalf("want -32603, got %+v", rerr)
	}
	if _, err := os.Lstat(filepath.Join(root, "rolled")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the folder (or its .git) is left behind: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Join(s.cfg.StateDir, "homes"))
	if len(entries) != 0 {
		t.Fatalf("a project home was left behind: %d", len(entries))
	}
	if n := projectCount(t, db); n != 0 {
		t.Fatalf("projects after rollback = %d", n)
	}
}

func TestNeutralizeRemovesHostileConfigAndKeepsTheOrigin(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	repo := filepath.Join(root, "hostile")
	if err := os.Mkdir(repo, 0o700); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "init", "-q", "-b", "main")
	gitIn(t, repo, "config", "--local", "credential.helper", "!echo hostile")
	gitIn(t, repo, "config", "--local", "core.sshCommand", "touch /tmp/acpcode-should-not-run")
	gitIn(t, repo, "config", "--local", "url.https://evil.example/.insteadOf", "https://github.com/")
	gitIn(t, repo, "config", "--local", "url.https://evil.example/.pushInsteadOf", "https://github.com/")
	gitIn(t, repo, "config", "--local", "remote.origin.url", "https://github.com/owner/repo.git")
	gitIn(t, repo, "config", "--local", "remote.origin.pushurl", "https://evil.example/x.git")
	gitIn(t, repo, "config", "--local", "http.proxy", "http://evil.example:3128")
	p := store.Project{ID: "0123456789ab", Name: "hostile", Path: repo, Created: time.Now().UTC().Format(time.RFC3339)}
	if err := db.CreateProject(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	out, err := s.runner.oneOff(context.Background(), p, s.projectHome(p.ID), oneOffCmd{argv: []string{"sh", "-c", pushConfigScript, "sh", ""}, vars: gitEnv(s.projectHome(p.ID), nil)}, nil)
	if err != nil {
		t.Fatalf("config step: %v", err)
	}
	cfg := parsePushConfig(out.Out)
	if !objectIDPattern.MatchString(cfg.hash) {
		t.Fatalf("hash %q", cfg.hash)
	}
	if urls := cfg.remotes["origin"]; len(urls) != 1 || urls[0] != "https://github.com/owner/repo.git" {
		t.Fatalf("origin urls = %v (the pushurl must be gone and only the origin kept)", urls)
	}
	left := gitIn(t, repo, "config", "--local", "--list")
	for _, key := range []string{"credential.helper", "core.sshcommand", "insteadof", "pushurl", "http.proxy"} {
		if strings.Contains(strings.ToLower(left), key) {
			t.Errorf("config still holds %s:\n%s", key, left)
		}
	}
	if _, err := os.Stat("/tmp/acpcode-should-not-run"); err == nil {
		t.Fatal("core.sshCommand ran")
	}
}

func TestPushNeedsConfirmAndRunsNothing(t *testing.T) {
	s, db, _, _ := folderTestServer(t)
	defer db.Close()
	rec := &recordingRunner{runner: s.runner}
	s.runner = rec
	seedCredential(t, s, db, "github.com", "tok-abcdefghijklmnop")
	for _, params := range []map[string]any{
		{"projectId": "0123456789ab", "credentialId": "000000000001"},
		{"projectId": "0123456789ab", "credentialId": "000000000001", "confirm": false},
		{"projectId": "0123456789ab", "credentialId": "000000000001", "confirm": "yes"},
	} {
		_, rerr := s.gitPush(context.Background(), audit.Who{Identity: "owner"}, jsonParams(t, params))
		if rerr == nil || rerr.Code != rpcInvalidParams || !strings.Contains(rerr.Message, "confirm") {
			t.Fatalf("want a confirm refusal for %v, got %+v", params, rerr)
		}
	}
	if len(rec.calls) != 0 {
		t.Fatalf("%d containers ran without confirm", len(rec.calls))
	}
}

// seedCredential stores a profile and its token file the way setGitCredential does.
func seedCredential(t *testing.T, s *Server, db *store.Store, host, token string) string {
	t.Helper()
	id := "000000000001"
	if err := s.ensureCredentialsDir(); err != nil {
		t.Fatal(err)
	}
	if err := writeFileAtomic(s.credentialPath(id), []byte(token)); err != nil {
		t.Fatal(err)
	}
	if err := db.SetGitCredential(context.Background(), store.GitCredential{ID: id, Name: "test", Host: host, Created: "2026-11-08T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	return id
}

// pushRepo makes a repository with one commit, an origin URL, and a project row for it.
func pushRepo(t *testing.T, s *Server, db *store.Store, root, origin string, files map[string]string) store.Project {
	t.Helper()
	repo := filepath.Join(root, "pushrepo")
	if err := os.Mkdir(repo, 0o700); err != nil {
		t.Fatal(err)
	}
	gitIn(t, repo, "init", "-q", "-b", "main")
	gitIn(t, repo, "remote", "add", "origin", origin)
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(repo, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	gitIn(t, repo, "add", "-A")
	gitIn(t, repo, "commit", "-q", "-m", "init")
	p := store.Project{ID: "0123456789ab", Name: "pushrepo", Path: repo, Created: "2026-11-08T00:00:00.000Z"}
	if err := db.CreateProject(context.Background(), p); err != nil {
		t.Fatal(err)
	}
	return p
}

func pushParams(t *testing.T, extra map[string]any) *jsonv.Value {
	t.Helper()
	m := map[string]any{"projectId": "0123456789ab", "credentialId": "000000000001", "confirm": true}
	for k, v := range extra {
		m[k] = v
	}
	return jsonParams(t, m)
}

func TestPushRefusesARemoteOutsideTheAllowList(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	rec := &recordingRunner{runner: s.runner}
	s.runner = rec
	seedCredential(t, s, db, "github.com", "tok-abcdefghijklmnop")
	pushRepo(t, s, db, root, "https://evil.example/owner/repo.git", map[string]string{"a.txt": "x"})
	_, rerr := s.gitPush(context.Background(), audit.Who{Identity: "owner"}, pushParams(t, nil))
	if rerr == nil || !strings.Contains(rerr.Message, "origin") {
		t.Fatalf("want a remote refusal, got %+v", rerr)
	}
	if len(rec.calls) != 1 || rec.calls[0].network {
		t.Fatalf("only the config step may run before the refusal: %d calls", len(rec.calls))
	}
}

func TestPushSecretScanBlocksAnEnvFileUnlessAllowed(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	rec := &recordingRunner{runner: s.runner}
	s.runner = rec
	token := "tok-abcdefghijklmnop"
	seedCredential(t, s, db, "github.com", token)
	pushRepo(t, s, db, root, "https://github.com/owner/repo.git", map[string]string{"a.txt": "x", ".env": "API=1\n"})

	_, rerr := s.gitPush(context.Background(), audit.Who{Identity: "owner"}, pushParams(t, nil))
	if rerr == nil || rerr.Code != rpcInvalidParams || !strings.Contains(rerr.Message, "look like secrets") {
		t.Fatalf("want a secret refusal, got %+v", rerr)
	}
	files, _ := rerr.Data.(map[string]any)["files"].([]string)
	if len(files) != 1 || files[0] != ".env" {
		t.Fatalf("named files = %v", rerr.Data)
	}
	for _, c := range rec.calls {
		if c.network {
			t.Fatal("the push container started after a secret refusal")
		}
	}

	// allowSecretFiles reaches the push step. The stub refuses the network, so it fails there, and
	// the token is named in the push container's environment only, never in its argv.
	rec.calls = nil
	_, rerr = s.gitPush(context.Background(), audit.Who{Identity: "owner"}, pushParams(t, map[string]any{"allowSecretFiles": true}))
	if rerr == nil || rerr.Message != "git push failed" {
		t.Fatalf("want the push step to run and fail with the stub, got %+v", rerr)
	}
	last := rec.calls[len(rec.calls)-1]
	if !last.network {
		t.Fatal("the last command must be the push, on the default network")
	}
	if len(last.secrets) != 1 || last.secrets[0] != tokenEnv+"="+token {
		t.Fatalf("the token must be passed as a secret to the push container: %v", last.secrets)
	}
	for _, a := range append(append([]string{}, last.argv...), last.vars...) {
		if strings.Contains(a, token) {
			t.Fatalf("the token appears in argv or the container's variables: %q", a)
		}
	}
	for _, c := range rec.calls[:len(rec.calls)-1] {
		if c.network {
			t.Fatal("a step other than the push has network access")
		}
	}
}

func TestSecretScanFindsAPrivateKeyHeaderInContent(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	defer db.Close()
	rec := &recordingRunner{runner: s.runner}
	s.runner = rec
	seedCredential(t, s, db, "github.com", "tok-abcdefghijklmnop")
	pushRepo(t, s, db, root, "https://github.com/owner/repo.git", map[string]string{"notes.txt": "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n"})
	_, rerr := s.gitPush(context.Background(), audit.Who{Identity: "owner"}, pushParams(t, nil))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want a refusal for a key header, got %+v", rerr)
	}
	files, _ := rerr.Data.(map[string]any)["files"].([]string)
	if len(files) != 1 || files[0] != "notes.txt" {
		t.Fatalf("named files = %v", rerr.Data)
	}
}

func TestConnectionSecureRefusesAPlainProxiedConnection(t *testing.T) {
	mk := func(peer string, headers map[string]string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = peer
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		return r
	}
	cases := []struct {
		name  string
		req   *http.Request
		trust bool
		want  bool
	}{
		{"direct loopback, no proxy", mk("127.0.0.1:5000", nil), false, true},
		{"proxy https", mk("127.0.0.1:5000", map[string]string{"X-Forwarded-Proto": "https"}), true, true},
		{"proxy http is refused", mk("127.0.0.1:5000", map[string]string{"X-Forwarded-Proto": "http"}), true, false},
		{"last entry decides", mk("127.0.0.1:5000", map[string]string{"X-Forwarded-Proto": "https, http"}), true, false},
		{"no header from the proxy", mk("127.0.0.1:5000", nil), true, true},
		{"header not trusted without trustProxy", mk("127.0.0.1:5000", map[string]string{"X-Forwarded-Proto": "http"}), false, true},
	}
	for _, c := range cases {
		if got := connectionSecure(c.req, c.trust); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

// jsonParams parses a request object the way the dispatcher does.
func jsonParams(t *testing.T, m map[string]any) *jsonv.Value {
	t.Helper()
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}
