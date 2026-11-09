package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
)

const scopeTestToken = "scope-test-token-abcdefgh"

// dialAs opens a socket to the test server with the token. A refused upgrade returns the response.
func dialAs(t *testing.T, ts *httptest.Server, token string) (*websocket.Conn, *http.Response, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	url := "ws" + strings.TrimPrefix(ts.URL, "http")
	return websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}},
	})
}

// callOver sends one request on the socket and returns the reply's raw text.
func callOver(t *testing.T, conn *websocket.Conn, body string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, []byte(body)); err != nil {
		t.Fatalf("write: %v", err)
	}
	_, data, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(data)
}

// expectClosedRevoked waits for the socket to be closed with the revoked-token code.
func expectClosedRevoked(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _, err := conn.Read(ctx)
	if err == nil {
		t.Fatal("the socket still delivers messages after its token was revoked")
	}
	if code := websocket.CloseStatus(err); code != revokedClosedCode {
		t.Fatalf("close status = %d (%v), want %d", code, err, revokedClosedCode)
	}
}

func TestRevokedTokenRefusedOnNextRequestWithoutRestart(t *testing.T) {
	s, logs, _ := scopeTestServer(t)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)

	conn, _, err := dialAs(t, ts, scopeTestToken)
	if err != nil {
		t.Fatalf("dial before revoke: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	if got := callOver(t, conn, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`); !strings.Contains(got, `"result"`) {
		t.Fatalf("initialize before revoke: %s", got)
	}

	// The list changes while the gateway runs: the socket's next request is refused and the socket closes.
	s.setRevoked([]string{"phone"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}`)); err != nil {
		t.Fatalf("write after revoke: %v", err)
	}
	expectClosedRevoked(t, conn)
	if !strings.Contains(logs.String(), `"event":"token_revoked"`) {
		t.Fatalf("no token_revoked audit line: %s", logs.String())
	}

	// A new connection with the same token is refused at the upgrade, with no restart.
	if _, resp, err := dialAs(t, ts, scopeTestToken); err == nil {
		t.Fatal("a revoked token opened a new socket")
	} else if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("reconnect with a revoked token: %v (status %v), want 401", err, resp)
	}
}

func TestRevokedListReloadsOnSIGHUP(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	ts := httptest.NewServer(s)
	t.Cleanup(ts.Close)

	conn, _, err := dialAs(t, ts, scopeTestToken)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	if s.isRevoked("phone") {
		t.Fatal("the token is revoked before any list exists")
	}

	// The owner's revoke-token command writes the list and sends SIGHUP. The gateway reloads on it.
	if err := WriteRevokedTokens(s.cfg.StateDir, []string{"phone"}); err != nil {
		t.Fatal(err)
	}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGHUP)
	done := make(chan struct{})
	go func() { s.ReloadOnSIGHUP(sigs); close(done) }()
	defer func() {
		signal.Stop(sigs)
		close(sigs)
		<-done
	}()
	if err := syscall.Kill(os.Getpid(), syscall.SIGHUP); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for !s.isRevoked("phone") {
		if time.Now().After(deadline) {
			t.Fatal("SIGHUP did not reload the revoked-token list")
		}
		time.Sleep(10 * time.Millisecond)
	}
	expectClosedRevoked(t, conn)
	if _, resp, err := dialAs(t, ts, scopeTestToken); err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("reconnect after SIGHUP reload: %v, want 401", err)
	}
}

func TestRevokedListSurvivesRestart(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	if err := WriteRevokedTokens(s.cfg.StateDir, []string{"phone"}); err != nil {
		t.Fatal(err)
	}
	restarted := New(s.cfg, audit.New(&syncBuffer{}), s.store)
	t.Cleanup(restarted.Shutdown)
	if err := restarted.LoadRevoked(); err != nil {
		t.Fatal(err)
	}
	if !restarted.isRevoked("phone") || restarted.isRevoked("other") {
		t.Fatal("the saved list did not load at start")
	}
}

func TestDamagedRevokedListStopsStartAndKeepsMemory(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	if err := os.WriteFile(RevokedPath(s.cfg.StateDir), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.LoadRevoked(); err == nil {
		t.Fatal("a damaged list loaded without error: a revocation could be lost")
	}
	s.setRevoked([]string{"phone"})
	if err := s.reloadRevoked(); err == nil {
		t.Fatal("a damaged list reloaded without error")
	}
	if !s.isRevoked("phone") {
		t.Fatal("a failed reload dropped the revocation in memory")
	}
}

func TestRevokedListWriteIsOwnerOnly(t *testing.T) {
	dir := t.TempDir()
	if err := WriteRevokedTokens(dir, []string{"b", "a"}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, revokedFileName))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v, want 0600", info.Mode().Perm())
	}
	ids, err := ReadRevokedTokens(dir)
	if err != nil || len(ids) != 2 || ids[0] != "a" {
		t.Fatalf("read back %v (%v), want sorted [a b]", ids, err)
	}
}

func TestProjectCreateRefusesHomeFolder(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	home := filepath.Join(filepath.Dir(s.cfg.StateDir), "home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	s.roots = []string{home} // a root at $HOME: the create must still refuse it

	params, err := jsonv.Parse([]byte(`{"path":` + jsonQuote(home) + `,"name":"home"}`))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, rerr := s.createProject(context.Background(), params)
	if rerr == nil {
		t.Fatal("a project at $HOME was created")
	}
	if rerr.Code != rpcInvalidParams || !strings.Contains(rerr.Message, "Rule: no project root at or above $HOME") {
		t.Fatalf("refusal %d %q does not name the rule", rerr.Code, rerr.Message)
	}
}

func TestProjectCreateAllowsFolderUnderHome(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	home := filepath.Join(filepath.Dir(s.cfg.StateDir), "home")
	project := filepath.Join(home, "work", "app")
	if err := os.MkdirAll(project, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	s.roots = []string{filepath.Join(home, "work")}

	params, err := jsonv.Parse([]byte(`{"path":` + jsonQuote(project) + `,"name":"app"}`))
	if err != nil {
		t.Fatal(err)
	}
	p, _, _, rerr := s.createProject(context.Background(), params)
	if rerr != nil {
		t.Fatalf("a project under $HOME was refused: %d %s", rerr.Code, rerr.Message)
	}
	if p == nil || p.Path != project {
		t.Fatalf("project = %+v, want path %s", p, project)
	}
}

func jsonQuote(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

// The config's own rule is tested in the config package; this keeps the server's copy of the rule
// honest against the same helper.
func TestProjectAboveHomeMatchesConfigRule(t *testing.T) {
	home := "/Users/owner"
	for path, want := range map[string]bool{"/": true, "/Users": true, "/Users/owner": true, "/Users/owner/work": false, "/Users/ownerx": false} {
		if got := config.AtOrAboveHome(path, home); got != want {
			t.Fatalf("AtOrAboveHome(%q, %q) = %v, want %v", path, home, got, want)
		}
	}
}
