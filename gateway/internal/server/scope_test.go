package server

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// scopeTestServer is a server with one token (id "phone", identity "owner") and one root. The token
// is full scope unless the test sets the client's scope.
func scopeTestServer(t *testing.T) (*Server, *syncBuffer, string) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "root")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	raw := fmt.Sprintf(`{
		"listen": {"host": "127.0.0.1", "port": 0},
		"tokens": [{"id": "phone", "identity": "owner", "sha256": %q}],
		"agent": {"command": ["/bin/false"]},
		"projects": {"roots": [%q]},
		"stateDir": %q,
		"runner": {"kind": "host", "allowHost": true}
	}`, HashToken("scope-test-token-abcdefgh"), root, filepath.Join(dir, "state"))
	v, err := jsonv.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Validate(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil { // the gateway's state dir exists before it starts
		t.Fatal(err)
	}
	db, err := store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	logs := &syncBuffer{}
	s := New(cfg, audit.New(logs), db)
	t.Cleanup(s.Shutdown)
	return s, logs, root
}

// scopedClient is a gateway client with no socket, as the phone's token of this scope.
func scopedClient(scope string) *client {
	return &client{
		who: audit.Who{Identity: "owner", Device: "phone", Scope: scope},
		ctx: context.Background(), out: make(chan []byte, 16), done: make(chan struct{}),
	}
}

// sendAs runs one message through handleMessage and reports what the reply carried. answered is
// false when no reply was sent (a notification, or a response that is dropped).
func sendAs(t *testing.T, s *Server, c *client, body string) (result any, rerr *rpcError, answered bool) {
	t.Helper()
	reply := func(_ *jsonv.Value, res any, e *rpcError) {
		answered = true
		result, rerr = res, e
	}
	s.handleMessage(context.Background(), c, websocket.MessageText, []byte(body), reply)
	return result, rerr, answered
}

func TestIntentScopeDeniesSessionLoadAndMCPServersOnCreate(t *testing.T) {
	s, logs, root := scopeTestServer(t)
	c := scopedClient(config.ScopeIntent)

	cases := map[string]string{
		"session/load":               fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"s1","cwd":%q,"mcpServers":[]}}`, root),
		"sessions/create mcpServers": `{"jsonrpc":"2.0","id":2,"method":"_acpcode/sessions/create","params":{"cwd":"` + root + `","mcpServers":[],"prompt":[{"type":"text","text":"hi"}]}}`,
		"session/new mcpServers":     fmt.Sprintf(`{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":%q,"mcpServers":[{"name":"x"}]}}`, root),
		"session/list":               `{"jsonrpc":"2.0","id":4,"method":"session/list","params":{}}`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			_, rerr, answered := sendAs(t, s, c, body)
			if !answered || rerr == nil {
				t.Fatalf("answered=%v err=%v: want a refusal", answered, rerr)
			}
			if rerr.Code != -32003 {
				t.Fatalf("code = %d (%s), want -32003", rerr.Code, rerr.Message)
			}
		})
	}
	if !strings.Contains(logs.String(), `"event":"scope_denied"`) || !strings.Contains(logs.String(), `"scope":"intent"`) {
		t.Fatalf("no scope_denied audit line with the scope: %s", logs.String())
	}
}

func TestIntentScopeAllowsInitializeAndOnlyItsOwnCalls(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	c := scopedClient(config.ScopeIntent)
	result, rerr, answered := sendAs(t, s, c, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}`)
	if rerr != nil || !answered || result == nil {
		t.Fatalf("intent token refused initialize: %v", rerr)
	}
	if err := scopeDenial(config.ScopeIntent, "_acpcode/sessions/prompt", nil); err != nil {
		t.Fatalf("intent token refused sessions/prompt: %v", err.Message)
	}
	if err := scopeDenial(config.ScopeIntent, "_acpcode/projects/list", nil); err != nil {
		t.Fatalf("intent token refused projects/list: %v", err.Message)
	}
}

func TestFullScopeTokenIsAllowedEverything(t *testing.T) {
	methods := []string{
		"initialize", "session/new", "session/load", "session/list", "session/prompt", "session/cancel",
		"_acpcode/sessions/create", "_acpcode/sessions/prompt", "_acpcode/projects/create",
		"_acpcode/connector/approve", "_acpcode/connector/revoke", "_acpcode/git/push", "", "some/other",
	}
	mcp, err := jsonv.Parse([]byte(`{"mcpServers":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range methods {
		if rerr := scopeDenial(config.ScopeFull, m, mcp); rerr != nil {
			t.Fatalf("full scope refused %q: %s", m, rerr.Message)
		}
	}
	// A full token reaches the connector handler: with the connector off that is method-not-found,
	// not the scope's -32003.
	s, _, _ := scopeTestServer(t)
	_, rerr, answered := sendAs(t, s, scopedClient(config.ScopeFull), `{"jsonrpc":"2.0","id":2,"method":"_acpcode/connector/approve","params":{"pairingId":"p","scope":{"allProjects":true}}}`)
	if !answered || rerr == nil || rerr.Code == -32003 {
		t.Fatalf("full token was scope-refused on connector approve: %+v", rerr)
	}
}

func TestUnknownScopeFailsClosed(t *testing.T) {
	s, _, _ := scopeTestServer(t)
	for _, scope := range []string{"", "admin", "FULL", "intent "} {
		c := scopedClient(scope)
		_, rerr, answered := sendAs(t, s, c, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
		if !answered || rerr == nil || rerr.Code != -32003 {
			t.Fatalf("scope %q: initialize answered=%v err=%+v, want -32003", scope, answered, rerr)
		}
		if err := scopeDenial(scope, "session/prompt", nil); err == nil {
			t.Fatalf("scope %q allowed session/prompt", scope)
		}
	}
}

func TestConnectorApproveRefusedForIntentScope(t *testing.T) {
	s, logs, _ := scopeTestServer(t)
	c := scopedClient(config.ScopeIntent)
	for _, method := range []string{"_acpcode/connector/approve", "_acpcode/connector/revoke"} {
		body := fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"method":%q,"params":{"pairingId":"p","grantId":"g","scope":{"allProjects":true}}}`, method)
		_, rerr, answered := sendAs(t, s, c, body)
		if !answered || rerr == nil || rerr.Code != -32003 {
			t.Fatalf("%s for intent: answered=%v err=%+v, want -32003", method, answered, rerr)
		}
	}
	if !strings.Contains(logs.String(), "_acpcode/connector/approve") {
		t.Fatalf("the refused approve is not in the audit log: %s", logs.String())
	}
}

func TestIntentScopeDropsPermissionAnswers(t *testing.T) {
	s, logs, _ := scopeTestServer(t)
	c := scopedClient(config.ScopeIntent)
	_, _, answered := sendAs(t, s, c, `{"jsonrpc":"2.0","id":"perm-1","result":{"outcome":{"outcome":"selected","optionId":"allow"}}}`)
	if answered {
		t.Fatal("an intent token's permission answer got a reply; it must be dropped silently")
	}
	if !strings.Contains(logs.String(), `"event":"scope_denied"`) {
		t.Fatalf("the dropped answer is not audited: %s", logs.String())
	}
}
