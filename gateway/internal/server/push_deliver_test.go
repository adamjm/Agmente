package server

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/config"
	"agmente/gateway/internal/push"
	"agmente/gateway/internal/store"
)

// PLAN 3.11: the agent path only enqueues. A full queue drops the push and audits it, and nothing
// blocks. A session with no id is skipped, and without SetPush nothing is queued at all.
func TestPushNotifyNeverBlocksAndAuditsOverflow(t *testing.T) {
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var out bytes.Buffer
	cfg := &config.Config{Roots: []string{dir}, StateDir: dir, Runner: config.Runner{Kind: "host"}}
	s := New(cfg, audit.New(&out), db)
	defer s.Shutdown()

	// Without SetPush: no queue, no audit line.
	s.pushNotify(push.TurnEnded, "proj", "sess")
	if out.Len() != 0 {
		t.Fatalf("push is off, but the audit has %q", out.String())
	}

	// A queue of one with no worker: the second push is dropped and audited.
	s.push = &pushDelivery{queue: make(chan pushJob, 1)}
	s.pushNotify(push.TurnEnded, "proj", "sess")
	s.pushNotify(push.ApprovalNeeded, "proj", "sess")
	if len(s.push.queue) != 1 {
		t.Fatalf("queue holds %d jobs, want 1", len(s.push.queue))
	}
	line := out.String()
	if !strings.Contains(line, `"event":"push_dropped"`) || !strings.Contains(line, `"project":"proj"`) || !strings.Contains(line, `"reason":"approval_needed"`) {
		t.Errorf("want a push_dropped line for the approval, got %q", line)
	}
	if strings.Contains(line, "sess") {
		t.Errorf("the audit line holds the session id: %q", line)
	}

	// A session with no id has no payload: nothing is queued or audited.
	before := out.Len()
	s.pushNotify(push.SessionFailed, "proj", "")
	if out.Len() != before || len(s.push.queue) != 1 {
		t.Error("an event with no session id must be skipped")
	}
}
