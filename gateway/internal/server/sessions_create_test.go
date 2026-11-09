package server

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// The create call when the agent answers session/new and then takes no more input. The session exists,
// the prompt is never written, and the caller gets -32015 with sessionId and promptSent false. The
// wire suite (test/sessions-create.test.mjs) covers the other create errors through the process; this
// case needs a pipe the test controls, so it runs here.
func TestCreateWithPromptNotAcceptedGives32015WithPromptSentFalse(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "root")
	project := filepath.Join(root, "project")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}
	raw := []byte(fmt.Sprintf(`{
		"listen": {"host": "127.0.0.1", "port": 0},
		"tokens": [{"id": "phone", "identity": "owner", "sha256": %q}],
		"agent": {"command": ["/bin/false"]},
		"projects": {"roots": [%q]},
		"stateDir": %q,
		"runner": {"kind": "host", "allowHost": true}
	}`, fmt.Sprintf("%064d", 1), root, filepath.Join(dir, "state")))
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Validate(v)
	if err != nil {
		t.Fatal(err)
	}
	db, err := store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	ctx := context.Background()
	if err := db.CreateProject(ctx, store.Project{ID: "p1", Name: "p", Path: project, Created: "2026-11-09T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	s := New(cfg, audit.New(&syncBuffer{}), db)
	t.Cleanup(s.pushCancel)

	// A fake agent process whose stdin and stdout are pipes the test holds. The gateway has the agent
	// running, so it writes straight to these pipes and starts nothing.
	inR, inW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = outW.Close(); _ = inW.Close() })
	proc := &agentProcess{stdin: inW, stdout: outR, exited: make(chan struct{}), stdoutDone: make(chan struct{})}
	a := s.agent("p1")
	a.mu.Lock()
	a.proc = proc
	a.path = project
	a.setState(agentRunning)
	a.mu.Unlock()
	go a.readLoop(proc)

	go func() {
		line, err := bufio.NewReader(inR).ReadBytes('\n')
		if err != nil {
			return
		}
		req, err := jsonv.Parse(line)
		if err != nil {
			return
		}
		id, _ := req.Get("id").Int()
		_ = inR.Close() // from here the agent takes no more input: the prompt write fails
		_, _ = fmt.Fprintf(outW, `{"jsonrpc":"2.0","id":%d,"result":{"sessionId":"sess-1","modes":{"currentModeId":"agent"}}}`+"\n", id)
	}()

	var gotErr *rpcError
	var gotResult any
	reply := func(_ *jsonv.Value, result any, rerr *rpcError) {
		gotErr, gotResult = rerr, result
	}
	params, err := jsonv.Parse([]byte(fmt.Sprintf(`{"cwd":%q,"prompt":[{"type":"text","text":"hello"}]}`, project)))
	if err != nil {
		t.Fatal(err)
	}
	s.serveCreate(audit.Who{Identity: "owner", Device: "phone", Scope: config.ScopeFull}, jsonv.Str("7"), params, reply)

	if gotErr == nil {
		t.Fatalf("create answered with a result, want -32015: %#v", gotResult)
	}
	if gotErr.Code != -32015 {
		t.Fatalf("code = %d (%s), want -32015", gotErr.Code, gotErr.Message)
	}
	data, ok := gotErr.Data.(map[string]any)
	if !ok || data["sessionId"] != "sess-1" || data["promptSent"] != false {
		t.Fatalf("data = %#v, want sessionId sess-1 and promptSent false", gotErr.Data)
	}
	if sid, err := db.SessionProject(ctx, "sess-1"); err != nil || sid != "p1" {
		t.Fatalf("the session must exist after a refused prompt: project %q, err %v", sid, err)
	}
}
