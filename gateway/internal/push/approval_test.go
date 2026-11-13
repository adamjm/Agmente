package push

import (
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"
)

// D-111: an approval payload carries a short summary of the tool call. Its verb table and cut are
// shared with the app (ApprovalNotificationText), so the same cases appear in both test suites.
func TestSummaryVerbsFollowTheKind(t *testing.T) {
	cases := []struct{ title, kind, want string }{
		{"npm test", "execute", "Run: npm test"},
		{"src/app.ts", "edit", "Edit: src/app.ts"},
		{"old.txt", "delete", "Delete: old.txt"},
		{"README.md", "read", "Read: README.md"},
		{"https://example.test", "fetch", "Fetch: https://example.test"},
		{"a.txt to b.txt", "move", "Move: a.txt to b.txt"},
		{"Plan the work", "think", "Plan the work"},
		{"Something", "", "Something"},
		{"EXEC", "EXECUTE", "EXEC"},
		{"", "execute", ""},
		{"   ", "edit", ""},
	}
	for _, c := range cases {
		if got := Summary(c.title, c.kind); got != c.want {
			t.Errorf("Summary(%q, %q) = %q, want %q", c.title, c.kind, got, c.want)
		}
	}
}

func TestSummaryDoesNotRepeatAVerbTheTitleHas(t *testing.T) {
	if got := Summary("Run echo", "execute"); got != "Run echo" {
		t.Errorf("got %q", got)
	}
	if got := Summary("read", "read"); got != "read" {
		t.Errorf("got %q", got)
	}
}

func TestApprovalBodyHoldsTheSummaryAndTheCategory(t *testing.T) {
	out, err := BuildApproval("Website", "sess-1", "Run: npm test")
	if err != nil {
		t.Fatal(err)
	}
	want := `{"aps":{"alert":{"title":"Website","body":"Approval needed: Run: npm test"},"sound":"default","category":"APPROVAL","thread-id":"sess-1"},"sessionId":"sess-1","event":"approval_needed"}`
	if string(out) != want {
		t.Fatalf("got  %s\nwant %s", out, want)
	}
}

func TestApprovalWithNoSummaryKeepsTheOldBody(t *testing.T) {
	for _, s := range []string{"", "   ", "\n\t"} {
		out, err := BuildApproval("Website", "sess-1", s)
		if err != nil {
			t.Fatal(err)
		}
		var got struct {
			Aps struct {
				Alert struct{ Body string } `json:"alert"`
			} `json:"aps"`
		}
		if err := json.Unmarshal(out, &got); err != nil {
			t.Fatal(err)
		}
		if got.Aps.Alert.Body != "Approval needed" {
			t.Errorf("summary %q: body %q", s, got.Aps.Alert.Body)
		}
	}
}

func TestApprovalSummaryLosesControlsAndNewlinesAndCollapsesSpaces(t *testing.T) {
	out, err := BuildApproval("p", "s1", "Run:\nnpm\x00 test\t‮   x")
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Aps struct {
			Alert struct{ Body string } `json:"alert"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	if want := "Approval needed: Run: npm test x"; got.Aps.Alert.Body != want {
		t.Fatalf("body %q, want %q", got.Aps.Alert.Body, want)
	}
}

func TestApprovalSummaryIsCutToEightyCharactersOnACharacterBoundary(t *testing.T) {
	out, err := BuildApproval("p", "s1", strings.Repeat("日", 200))
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Aps struct {
			Alert struct{ Body string } `json:"alert"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	summary := strings.TrimPrefix(got.Aps.Alert.Body, "Approval needed: ")
	if !utf8.ValidString(summary) {
		t.Fatalf("summary is not valid UTF-8")
	}
	if n := utf8.RuneCountInString(summary); n != 80 {
		t.Fatalf("summary has %d characters, want 80", n)
	}
	if !strings.HasSuffix(summary, "…") || strings.Trim(strings.TrimSuffix(summary, "…"), "日") != "" {
		t.Fatalf("summary %q", summary)
	}
}

func TestApprovalWorstCaseFitsIn512Bytes(t *testing.T) {
	names := []string{strings.Repeat("🚀", 400), strings.Repeat("a", 5000), "Proj"}
	summaries := []string{strings.Repeat("🚀", 200), strings.Repeat("日", 200), strings.Repeat("x", 5000)}
	sessions := []string{"sess-0123456789abcdef-0123456789abcdef", strings.Repeat("s", 150)}
	for _, name := range names {
		for _, sum := range summaries {
			for _, sid := range sessions {
				out, err := BuildApproval(name, sid, sum)
				if err != nil {
					t.Fatalf("%.10q %.10q %d: %v", name, sum, len(sid), err)
				}
				if len(out) > ApprovalMaxBytes {
					t.Fatalf("%d bytes", len(out))
				}
				if !utf8.Valid(out) || !json.Valid(out) {
					t.Fatalf("not valid JSON or UTF-8")
				}
			}
		}
	}
}

func TestApprovalShortensTheSummaryBeforeTheName(t *testing.T) {
	sid := strings.Repeat("s", 60)
	out, err := BuildApproval("Proj", sid, strings.Repeat("🚀", 200))
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Aps struct {
			Alert struct{ Title, Body string } `json:"alert"`
		} `json:"aps"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatal(err)
	}
	if got.Aps.Alert.Title != "Proj" {
		t.Errorf("the name was shortened: %q", got.Aps.Alert.Title)
	}
	if !strings.HasSuffix(got.Aps.Alert.Body, "…") {
		t.Errorf("the summary was not shortened: %q", got.Aps.Alert.Body)
	}
}

func TestApprovalSessionIdThatCannotFitIsRefused(t *testing.T) {
	if _, err := BuildApproval("p", strings.Repeat("s", 300), "Run: x"); err != ErrTooLong {
		t.Fatalf("an oversized session id: %v", err)
	}
	if _, err := BuildApproval("p", "", "Run: x"); err == nil {
		t.Fatal("an empty session id was accepted")
	}
}
