package server

import (
	"bytes"
	"strings"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/mcpservers"
)

const testID = "0123456789abcdef0123456789abcdef"

// testServer is a Server with only what the gateway's MCP list needs: a state folder and an audit log.
func testServer(t *testing.T) (*Server, *bytes.Buffer) {
	t.Helper()
	var buf bytes.Buffer
	return &Server{cfg: &config.Config{StateDir: t.TempDir()}, audit: audit.New(&buf)}, &buf
}

func parseJSON(t *testing.T, s string) *jsonv.Value {
	t.Helper()
	v, err := jsonv.Parse([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// A gateway entry whose name the phone already uses is not sent: the agent never gets two servers
// with one name, and the audit line names the reason only (D-107).
func TestMergeDropsAGatewayEntryWhosePhoneNameIsInUse(t *testing.T) {
	s, buf := testServer(t)
	lib := s.library()
	gw, err := lib.Put(mcpservers.Input{Name: "docs", Transport: "http", URL: "https://mcp.example.test/mcp"})
	if err != nil {
		t.Fatal(err)
	}
	a := newProjectAgent(s, "p1")
	entries, kept := s.agentMCPEntries(a, []string{gw.ID})
	if len(kept) != 1 {
		t.Fatalf("kept = %v", kept)
	}
	own := parseJSON(t, `[{"type":"http","name":"docs","url":"https://phone.example.test/mcp","headers":[]}]`)
	merged := s.mergeMCP(a, own, entries)
	if len(merged.Arr) != 1 || merged.Arr[0].Get("url").Kind != jsonv.String || merged.Arr[0].Get("url").Str != "https://phone.example.test/mcp" {
		t.Fatalf("merged = %s", merged.Marshal())
	}
	if !strings.Contains(buf.String(), `"reason":"name_in_use"`) {
		t.Fatalf("no audit line: %s", buf.String())
	}
}

// _meta: the gateway's key is read and removed; other keys stay; an empty _meta goes too.
func TestEnabledIDsAreReadAndTheirKeyIsRemoved(t *testing.T) {
	p := parseJSON(t, `{"cwd":"/x","_meta":{"acpcode/mcpEnabled":["`+testID+`"],"bob/mode":"plan"}}`)
	ids, given := enabledIDsValue(p)
	if !given {
		t.Fatal("the ids were not found")
	}
	got, ok := mcpIDsValue(ids)
	if !ok || len(got) != 1 || got[0] != testID {
		t.Fatalf("ids = %v, %v", got, ok)
	}
	dropEnabledIDs(p)
	if string(p.Get("_meta").Marshal()) != `{"bob/mode":"plan"}` {
		t.Fatalf("_meta = %s", p.Get("_meta").Marshal())
	}

	only := parseJSON(t, `{"cwd":"/x","_meta":{"acpcode/mcpEnabled":[]}}`)
	dropEnabledIDs(only)
	if only.Get("_meta") != nil || strings.Contains(string(only.Marshal()), "_meta") {
		t.Fatalf("an empty _meta was left: %s", only.Marshal())
	}
}

// A list of ids: an array of 32-digit lowercase hex strings, at most MaxEntries, repeats dropped.
func TestMCPIDsValueAcceptsOnlyIDLists(t *testing.T) {
	if got, ok := mcpIDsValue(parseJSON(t, `["`+testID+`","`+testID+`"]`)); !ok || len(got) != 1 {
		t.Fatalf("a repeat: %v, %v", got, ok)
	}
	for _, bad := range []string{`"` + testID + `"`, `[1]`, `["NOT-AN-ID"]`, `["0123456789ABCDEF0123456789ABCDEF"]`, `[null]`} {
		if _, ok := mcpIDsValue(parseJSON(t, bad)); ok {
			t.Errorf("%s was accepted", bad)
		}
	}
	long := make([]string, 0, mcpservers.MaxEntries+1)
	for i := 0; i <= mcpservers.MaxEntries; i++ {
		long = append(long, `"`+strings.Repeat("0", 31)+string(rune('a'+i%6))+`"`)
	}
	if _, ok := mcpIDsValue(parseJSON(t, "["+strings.Join(long, ",")+"]")); ok {
		t.Fatal("a list longer than MaxEntries was accepted")
	}
}

// The agent gets an http entry with its URL and headers, or a stdio entry with its command, args
// and environment. Never both shapes in one entry.
func TestAgentServerJSONHasOneShape(t *testing.T) {
	h := agentServerJSON(mcpservers.Full{
		Entry:   mcpservers.Entry{Name: "docs", Transport: "http", URL: "https://mcp.example.test/mcp"},
		Secrets: mcpservers.Secrets{Headers: []mcpservers.Pair{{Name: "X-Api-Key", Value: "v"}}},
	})
	if got := string(h.Marshal()); got != `{"name":"docs","type":"http","url":"https://mcp.example.test/mcp","headers":[{"name":"X-Api-Key","value":"v"}]}` {
		t.Fatalf("http = %s", got)
	}
	l := agentServerJSON(mcpservers.Full{
		Entry:   mcpservers.Entry{Name: "local", Transport: "stdio", Command: "/bin/tool"},
		Secrets: mcpservers.Secrets{Args: []string{"-x"}, Env: []mcpservers.Pair{{Name: "K", Value: "v"}}},
	})
	if got := string(l.Marshal()); got != `{"name":"local","command":"/bin/tool","args":["-x"],"env":[{"name":"K","value":"v"}]}` {
		t.Fatalf("stdio = %s", got)
	}
}

// A session whose turn is open cannot change its set; nothing is stored (D-107).
func TestSetSessionMCPIsRefusedWhileATurnIsOpen(t *testing.T) {
	s, _ := testServer(t)
	a := newProjectAgent(s, "p1")
	a.pending[1] = &pendingRequest{turn: "sess-1", method: "session/prompt"}
	closed, rerr := a.setSessionMCP("sess-1", nil, map[string]bool{})
	if closed || rerr == nil || rerr.Code != rpcRefused {
		t.Fatalf("closed=%v rerr=%+v", closed, rerr)
	}
	if rerr.Data.(map[string]any)["reason"] != "turn_open" {
		t.Fatalf("reason = %+v", rerr.Data)
	}
	// An open approval refuses too.
	delete(a.pending, 1)
	if _, rerr := a.setSessionMCP("sess-1", nil, map[string]bool{"sess-1": true}); rerr == nil || rerr.Code != rpcRefused {
		t.Fatalf("an approval did not refuse: %+v", rerr)
	}
}
