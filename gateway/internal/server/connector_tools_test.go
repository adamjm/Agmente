package server

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"

	"agmente/gateway/internal/store"
)

// openBridgeStore opens a store with one project and two sessions, for the bridge reads.
func openBridgeStore(t *testing.T) (*store.Store, *connectorBridge) {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	ctx := context.Background()
	if err := db.CreateProject(ctx, store.Project{ID: "p1", Name: "p", Path: "/work/alpha", Created: "2026-11-07T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	for _, sid := range []string{"s1", "s2"} {
		if err := db.RecordSession(ctx, sid, "p1"); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{store: db, agents: map[string]*projectAgent{}, perms: map[string]*permission{}}
	return db, &connectorBridge{s: s}
}

// The running tools of a turn are the tool calls with no terminal update, from the turn's own events.
func TestRunningToolsAreTheOpenToolCallsOfTheCurrentTurn(t *testing.T) {
	db, b := openBridgeStore(t)
	ctx := context.Background()
	update := func(sid, body string) {
		t.Helper()
		if _, err := db.AppendEvent(ctx, sid, "update", []byte(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"`+sid+`","update":`+body+`}}`)); err != nil {
			t.Fatal(err)
		}
	}
	// An earlier turn left a tool call open: it is not running in the current turn.
	if _, err := db.AppendEvent(ctx, "s1", "turn_started", []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	update("s1", `{"sessionUpdate":"tool_call","toolCallId":"old","title":"Old open tool"}`)
	if _, err := db.AppendEvent(ctx, "s1", "turn_ended", []byte(`{"params":{"stopReason":"end_turn"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := db.AppendEvent(ctx, "s1", "turn_started", []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	update("s1", `{"sessionUpdate":"tool_call","toolCallId":"a","title":"Read file"}`)
	update("s1", `{"sessionUpdate":"tool_call","toolCallId":"b","title":"Run tests"}`)
	update("s1", `{"sessionUpdate":"tool_call_update","toolCallId":"a","status":"completed"}`)
	update("s1", `{"sessionUpdate":"tool_call","toolCallId":"c","title":"Edit file"}`)
	update("s1", `{"sessionUpdate":"tool_call_update","toolCallId":"c","status":"failed"}`)
	update("s1", `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"not a tool"}}`)

	got, err := b.runningTools(ctx, "s1")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"Run tests"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("running tools = %v, want %v", got, want)
	}
}

// The stop reason is the last turn's, from its turn_ended event; an error is "error".
func TestStopReasonIsTheLastTurnsEnd(t *testing.T) {
	db, b := openBridgeStore(t)
	ctx := context.Background()
	if got, err := b.stopReason(ctx, "s2"); err != nil || got != "" {
		t.Fatalf("no turn yet: %q %v", got, err)
	}
	if _, err := db.AppendEvent(ctx, "s2", "turn_ended", []byte(`{"jsonrpc":"2.0","method":"_agmente/turn_ended","params":{"sessionId":"s2","stopReason":"max_tokens"}}`)); err != nil {
		t.Fatal(err)
	}
	if got, _ := b.stopReason(ctx, "s2"); got != "max_tokens" {
		t.Fatalf("stop reason = %q", got)
	}
	if _, err := db.AppendEvent(ctx, "s2", "turn_ended", []byte(`{"jsonrpc":"2.0","method":"_agmente/turn_ended","params":{"sessionId":"s2","error":{"code":-1}}}`)); err != nil {
		t.Fatal(err)
	}
	if got, _ := b.stopReason(ctx, "s2"); got != "error" {
		t.Fatalf("an error turn: %q", got)
	}
}

// The turn collects the agent's message text for its session, answers with the stop reason, and
// ignores everything else: other sessions, thoughts, permission requests and other answers.
func TestConnectorTurnCollectsTheReplyAndEndsOnItsAnswer(t *testing.T) {
	s := &Server{agents: map[string]*projectAgent{}}
	turn := &connectorTurn{s: s, pid: "p1", sid: "s1", reqID: "connector-1", done: make(chan struct{})}
	turn.c = &client{out: make(chan []byte, 16), done: make(chan struct{})}
	feed := func(msg string) { turn.observe([]byte(msg)) }

	feed(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hel"}}}}`)
	feed(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"other","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"WRONG"}}}}`)
	feed(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"WRONG"}}}}`)
	feed(`{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s1"}}`)
	feed(`{"jsonrpc":"2.0","id":"other-request","result":{"stopReason":"end_turn"}}`)
	select {
	case <-turn.Done():
		t.Fatal("a turn is not done before its own answer")
	default:
	}
	feed(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}`)
	feed(`{"jsonrpc":"2.0","id":"connector-1","result":{"stopReason":"end_turn"}}`)

	select {
	case <-turn.Done():
	default:
		t.Fatal("the answer to the prompt must finish the turn")
	}
	out := turn.Outcome()
	if out.Reply != "hello" || out.StopReason != "end_turn" || out.Err != "" {
		t.Fatalf("outcome = %+v", out)
	}
	if !turn.c.closing.Load() {
		t.Fatal("the turn's client is closed once the turn ends, so nothing more is queued to it")
	}
}

func TestConnectorTurnAnAgentErrorIsStopReasonError(t *testing.T) {
	s := &Server{agents: map[string]*projectAgent{}}
	turn := &connectorTurn{s: s, pid: "p1", sid: "s1", reqID: "connector-2", done: make(chan struct{})}
	turn.c = &client{out: make(chan []byte, 4), done: make(chan struct{})}
	turn.observe([]byte(`{"jsonrpc":"2.0","id":"connector-2","error":{"code":-32600,"message":"busy"}}`))
	if out := turn.Outcome(); out.StopReason != "error" || out.Err != "" {
		t.Fatalf("an agent error: %+v", out)
	}
	// A second answer does not change a finished turn.
	turn.observe([]byte(`{"jsonrpc":"2.0","id":"connector-2","result":{"stopReason":"end_turn"}}`))
	if out := turn.Outcome(); out.StopReason != "error" {
		t.Fatalf("a finished turn is final: %+v", out)
	}
}

func TestSessionStatusPrefersAwaitingThenRunning(t *testing.T) {
	running := map[string]bool{"a": true, "b": true}
	awaiting := map[string]bool{"a": true}
	if got := sessionStatus("idle", "a", running, awaiting); got != "awaiting_approval" {
		t.Fatalf("awaiting wins: %q", got)
	}
	if got := sessionStatus("idle", "b", running, awaiting); got != "running" {
		t.Fatalf("running next: %q", got)
	}
	if got := sessionStatus("error", "c", running, awaiting); got != "error" {
		t.Fatalf("the stored status otherwise: %q", got)
	}
}
