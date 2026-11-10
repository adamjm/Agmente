package push

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"
)

// Build covers turn_ended and session_failed. Approvals are built by BuildApproval (approval_test.go).
var events = []Event{TurnEnded, SessionFailed}

// T-24: each event type, with hostile and very long project names, stays within 256 bytes, is
// valid JSON, and holds only the project name, the session id and the event type.
func TestPayloadsFitAndHoldOnlyNameSessionAndType(t *testing.T) {
	names := []string{
		"my project",
		strings.Repeat("a", 5000),
		strings.Repeat("日本語のプロジェクト", 200),
		strings.Repeat("🚀", 400),
		"line1\nline2\r\n<script>alert(1)</script> & \"quotes\" \\ back",
		"‮evil‬ name\x00\x07",
		"ééé" + strings.Repeat("é", 300),
		"",
		"   ",
	}
	session := "sess-0123456789abcdef-0123456789abcdef"
	for _, ev := range events {
		for _, name := range names {
			out, err := Build(ev, name, session)
			if err != nil {
				t.Fatalf("%s %.20q: %v", ev, name, err)
			}
			if len(out) > MaxBytes {
				t.Fatalf("%s %.20q: %d bytes", ev, name, len(out))
			}
			if !utf8.Valid(out) {
				t.Fatalf("%s %.20q: invalid UTF-8", ev, name)
			}
			var got struct {
				Aps struct {
					Alert    map[string]string `json:"alert"`
					Sound    string            `json:"sound"`
					ThreadID string            `json:"thread-id"`
				} `json:"aps"`
				SessionID string `json:"sessionId"`
				Event     string `json:"event"`
			}
			dec := json.NewDecoder(strings.NewReader(string(out)))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&got); err != nil {
				t.Fatalf("%s %.20q: %v", ev, name, err)
			}
			if got.SessionID != session || got.Event != string(ev) || got.Aps.ThreadID != session {
				t.Fatalf("fields: %+v", got)
			}
			if len(got.Aps.Alert) != 2 || got.Aps.Alert["body"] != bodies[ev] {
				t.Fatalf("alert: %v", got.Aps.Alert)
			}
			title := got.Aps.Alert["title"]
			if title == "" || strings.ContainsAny(title, "\n\r\x00\x07‮‬") {
				t.Fatalf("title %q", title)
			}
		}
	}
}

func TestAShortNameIsKeptWhole(t *testing.T) {
	out, err := Build(TurnEnded, "Website", "s1")
	if err != nil {
		t.Fatal(err)
	}
	want := `{"aps":{"alert":{"title":"Website","body":"Turn finished"},"sound":"default","thread-id":"s1"},"sessionId":"s1","event":"turn_ended"}`
	if string(out) != want {
		t.Fatalf("got  %s\nwant %s", out, want)
	}
}

func TestALongNameIsCutOnACharacterBoundaryWithAnEllipsis(t *testing.T) {
	out, err := Build(TurnEnded, strings.Repeat("日", 300), "s1")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Aps struct{ Alert struct{ Title string } }
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	title := got.Aps.Alert.Title
	if !strings.HasSuffix(title, "…") || len(title) < 100 || strings.Trim(strings.TrimSuffix(title, "…"), "日") != "" {
		t.Fatalf("title %q (%d bytes)", title, len(title))
	}
	if len(out) > MaxBytes || len(out) < MaxBytes-4 {
		t.Fatalf("%d bytes: the name should use all the room", len(out))
	}
}

func TestBadInputIsRefused(t *testing.T) {
	if _, err := Build("prompt_text", "p", "s"); err == nil {
		t.Fatal("unknown event accepted")
	}
	if _, err := Build(ApprovalNeeded, "p", "s"); err == nil {
		t.Fatal("an approval went through Build, which has no summary and no category")
	}
	for _, id := range []string{"", "bad\xff"} {
		if _, err := Build(TurnEnded, "p", id); err == nil {
			t.Fatalf("session id %q accepted", id)
		}
	}
	if _, err := Build(TurnEnded, "p", strings.Repeat("s", 300)); err != ErrTooLong {
		t.Fatalf("an oversized session id: %v", err)
	}
}
