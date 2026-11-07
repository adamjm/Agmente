package store

import (
	"context"
	"testing"
)

// LatestEvent returns the newest event of one kind in one session (D-096).
func TestLatestEventIsTheNewestOfItsKindInItsSession(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "p1", Name: "p", Path: "/p", Created: "2026-11-07T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	for _, sid := range []string{"s1", "s2"} {
		if err := s.RecordSession(ctx, sid, "p1"); err != nil {
			t.Fatal(err)
		}
	}
	mustAppend := func(sid, kind, msg string) int64 {
		t.Helper()
		seq, err := s.AppendEvent(ctx, sid, kind, []byte(msg))
		if err != nil {
			t.Fatal(err)
		}
		return seq
	}
	mustAppend("s1", "turn_ended", `{"stopReason":"first"}`)
	mustAppend("s2", "turn_ended", `{"stopReason":"other session"}`)
	last := mustAppend("s1", "turn_ended", `{"stopReason":"second"}`)
	mustAppend("s1", "update", `{"noise":true}`)

	ev, ok, err := s.LatestEvent(ctx, "s1", "turn_ended")
	if err != nil || !ok {
		t.Fatalf("latest turn_ended: ok=%v err=%v", ok, err)
	}
	if ev.Seq != last || ev.Message != `{"stopReason":"second"}` {
		t.Fatalf("latest turn_ended = seq %d %q, want seq %d", ev.Seq, ev.Message, last)
	}
	if _, ok, _ := s.LatestEvent(ctx, "s1", "turn_started"); ok {
		t.Fatal("a kind the session never logged has no latest event")
	}
	if _, ok, _ := s.LatestEvent(ctx, "no-such", "turn_ended"); ok {
		t.Fatal("an unknown session has no latest event")
	}
}
