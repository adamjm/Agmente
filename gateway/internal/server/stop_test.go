package server

import (
	"testing"
	"time"
)

// D-106: the stall flag, the idle rule that skips a stalled turn, the outcome of a stop, and the
// reap decision. The wire suite (test/stop.test.mjs) checks the same behaviour through the process.

func TestTurnStalledRule(t *testing.T) {
	now := time.Now()
	const threshold = 10 * time.Second
	cases := []struct {
		name     string
		last     time.Time
		approval bool
		want     bool
	}{
		{"recent event is not stalled", now.Add(-5 * time.Second), false, false},
		{"no event for longer than the threshold is stalled", now.Add(-11 * time.Second), false, true},
		{"exactly at the threshold is not yet stalled", now.Add(-10 * time.Second), false, false},
		{"an open approval is never a stall", now.Add(-time.Hour), true, false},
		{"no event seen yet is not a stall", time.Time{}, false, false},
	}
	for _, c := range cases {
		if got := turnStalled(c.last, now, threshold, c.approval); got != c.want {
			t.Errorf("%s: turnStalled = %v, want %v", c.name, got, c.want)
		}
	}
	if turnStalled(now.Add(-time.Hour), now, 0, false) {
		t.Error("a zero threshold must not flag anything")
	}
}

func TestIdleRuleSkipsStalledTurns(t *testing.T) {
	now := time.Now()
	stall := 10 * time.Second
	hung := &pendingRequest{turn: "s-hung"}
	fresh := &pendingRequest{turn: "s-busy"}
	other := &pendingRequest{method: "session/new"} // not a turn: keeps the old rule
	eventAt := map[string]time.Time{"s-hung": now.Add(-time.Hour), "s-busy": now.Add(-time.Second)}
	approvals := map[string]bool{}
	stalled := func(sid string) bool { return turnStalled(eventAt[sid], now, stall, approvals[sid]) }

	if keepsAgentAwake(hung, stalled) {
		t.Error("a stalled turn must not keep the project awake (D-106)")
	}
	if !keepsAgentAwake(fresh, stalled) {
		t.Error("a turn with recent events must keep the project awake")
	}
	if !keepsAgentAwake(other, stalled) {
		t.Error("a non-turn request keeps the project awake, as before")
	}

	// The old rule was: any pending request keeps the project awake. A hung agent then never idles.
	oldRule := func(pending ...*pendingRequest) bool { return len(pending) > 0 }
	if !oldRule(hung) {
		t.Fatal("setup: the old rule counts a hung turn as busy")
	}
	// The new rule: a hung turn alone does not keep it awake, so an idle stop can happen.
	awake := false
	for _, p := range []*pendingRequest{hung} {
		if keepsAgentAwake(p, stalled) {
			awake = true
		}
	}
	if awake {
		t.Error("with only a stalled turn pending, the project must be idle")
	}
	// An open approval for the session keeps it awake even when the turn is old.
	approvals["s-hung"] = true
	if !keepsAgentAwake(hung, func(sid string) bool { return turnStalled(eventAt[sid], now, stall, approvals[sid]) }) {
		t.Error("an open approval must keep the project awake")
	}
}

func TestTurnStopOutcome(t *testing.T) {
	cases := []struct {
		hadTurn, ended bool
		reason, want   string
	}{
		{false, false, "", "not_running"},
		{true, false, "", "still_running"},
		{true, true, "cancelled", "cancelled"},
		{true, true, "end_turn", "not_running"},
		{true, true, "", "not_running"}, // the agent exited mid-turn
	}
	for _, c := range cases {
		if got := turnStopOutcome(c.hadTurn, c.ended, c.reason); got != c.want {
			t.Errorf("turnStopOutcome(%v, %v, %q) = %q, want %q", c.hadTurn, c.ended, c.reason, got, c.want)
		}
	}
	if got := agentStopOutcome(true); got != "stopped" {
		t.Errorf("agentStopOutcome(true) = %q", got)
	}
	if got := agentStopOutcome(false); got != "not_running" {
		t.Errorf("agentStopOutcome(false) = %q", got)
	}
}

func TestShouldReapRule(t *testing.T) {
	cases := []struct {
		reapDone, tracked, want bool
	}{
		{false, false, true}, // first start, nothing of this process runs: reap
		{true, false, false}, // already dealt with since the last exit
		{false, true, false}, // a process of this gateway runs the agent: never touch it
		{true, true, false},
	}
	for _, c := range cases {
		if got := shouldReap(c.reapDone, c.tracked); got != c.want {
			t.Errorf("shouldReap(reapDone=%v, tracked=%v) = %v, want %v", c.reapDone, c.tracked, got, c.want)
		}
	}
	if !containsName([]string{"acpcode-abc", "other"}, "acpcode-abc") {
		t.Error("containsName must find an exact name")
	}
	if containsName([]string{"acpcode-abcd"}, "acpcode-abc") {
		t.Error("containsName must not match a longer name")
	}
}

func TestBusyElsewhereData(t *testing.T) {
	rerr := busyElsewhere(map[string]string{"s2": "running", "s1": "awaiting_approval"})
	if rerr.Code != rpcStopConflict {
		t.Fatalf("code = %d, want %d", rerr.Code, rpcStopConflict)
	}
	data, ok := rerr.Data.(map[string]any)
	if !ok || data["reason"] != "busy_elsewhere" {
		t.Fatalf("data = %#v", rerr.Data)
	}
	list := data["otherSessions"].([]map[string]string)
	if len(list) != 2 || list[0]["sessionId"] != "s1" || list[1]["status"] != "running" {
		t.Errorf("otherSessions = %#v (want sorted by sessionId)", list)
	}
}
