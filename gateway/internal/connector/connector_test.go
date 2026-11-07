package connector

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agmente/gateway/internal/config"
)

func TestScopeAllows(t *testing.T) {
	all := Scope{AllProjects: true}
	if !all.Allows("p1", "") || !all.Allows("p2", "s9") {
		t.Fatal("all-projects scope must allow any project and session")
	}
	list := Scope{Projects: []string{"p1"}}
	if !list.Allows("p1", "") || !list.Allows("p1", "any-session") {
		t.Fatal("a project list without sessions allows every session in the listed project")
	}
	if list.Allows("p2", "") {
		t.Fatal("a project outside the list must be refused")
	}
	narrow := Scope{Projects: []string{"p1"}, HasSessions: true, Sessions: []string{"s1"}}
	if !narrow.Allows("p1", "s1") {
		t.Fatal("a listed session must be allowed")
	}
	if narrow.Allows("p1", "s2") {
		t.Fatal("an unlisted session must be refused")
	}
	if !narrow.Allows("p1", "") {
		t.Fatal("a project-level check with no session still passes the project")
	}
}

func TestScopeJSONRoundTrip(t *testing.T) {
	cases := []struct {
		in   string
		want Scope
	}{
		{`{"projects":"all"}`, Scope{AllProjects: true}},
		{`{"projects":["a","b"]}`, Scope{Projects: []string{"a", "b"}}},
		{`{"projects":["a"],"sessions":[]}`, Scope{Projects: []string{"a"}, HasSessions: true, Sessions: []string{}}},
		{`{"projects":["a"],"sessions":["s"]}`, Scope{Projects: []string{"a"}, HasSessions: true, Sessions: []string{"s"}}},
	}
	for _, c := range cases {
		var got Scope
		if err := json.Unmarshal([]byte(c.in), &got); err != nil {
			t.Fatalf("%s: %v", c.in, err)
		}
		out, err := json.Marshal(got)
		if err != nil {
			t.Fatal(err)
		}
		var back Scope
		if err := json.Unmarshal(out, &back); err != nil {
			t.Fatalf("%s: round trip %s: %v", c.in, out, err)
		}
		if back.AllProjects != c.want.AllProjects || back.HasSessions != c.want.HasSessions || strings.Join(back.Projects, ",") != strings.Join(c.want.Projects, ",") || len(back.Sessions) != len(c.want.Sessions) {
			t.Fatalf("%s: got %+v after round trip %s", c.in, back, out)
		}
	}
	var bad Scope
	if err := json.Unmarshal([]byte(`{"projects":"some"}`), &bad); err == nil {
		t.Fatal(`projects must be "all" or a list`)
	}
}

func TestPromptsPerHourSlides(t *testing.T) {
	l := newLimits(config.ConnectorLimits{MaxConcurrentTurns: 1, PromptsPerHour: 2, MaxPromptBytes: 100})
	now := time.Date(2026, 11, 7, 10, 0, 0, 0, time.UTC)
	l.now = func() time.Time { return now }
	if err := l.admitPrompt("g", 5); err != nil {
		t.Fatal(err)
	}
	if err := l.admitPrompt("g", 5); err != nil {
		t.Fatal(err)
	}
	if err := l.admitPrompt("g", 5); err == nil {
		t.Fatal("third prompt in the hour must be refused")
	}
	if err := l.admitPrompt("other", 5); err != nil {
		t.Fatal("the limit is per grant")
	}
	now = now.Add(time.Hour + time.Second)
	if err := l.admitPrompt("g", 5); err != nil {
		t.Fatalf("the window must slide: %v", err)
	}
	if err := l.admitPrompt("g", 101); err == nil {
		t.Fatal("a prompt over maxPromptBytes must be refused")
	}
}

func TestTurnSlots(t *testing.T) {
	l := newLimits(config.ConnectorLimits{MaxConcurrentTurns: 2, PromptsPerHour: 20, MaxPromptBytes: 100})
	done1, err := l.startTurn("s1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := l.startTurn("s1"); err == nil {
		t.Fatal("one running turn per session")
	}
	done2, err := l.startTurn("s2")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := l.startTurn("s3"); err == nil {
		t.Fatal("maxConcurrentTurns overall")
	}
	done1()
	done1() // safe to call twice
	if _, err := l.startTurn("s3"); err != nil {
		t.Fatalf("a released slot is free again: %v", err)
	}
	done2()
}

func TestGrantStoreFileIsAtomicAndPrivate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "connector-grants.json")
	s := newGrantStore(path)
	g := &Grant{ID: "g1", Label: "x", Scope: Scope{AllProjects: true}, ClientID: "c", Resource: "r"}
	if err := s.add(g); err != nil {
		t.Fatal(err)
	}
	if err := s.setToken("g1", hashToken("secret-token")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o, want 0600", info.Mode().Perm())
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "secret-token") {
		t.Fatal("the file must hold the hash, never the token")
	}
	if _, err := os.Stat(path + ".tmp"); err == nil {
		t.Fatal("no temp file may be left behind")
	}

	reloaded := newGrantStore(path)
	if err := reloaded.load(); err != nil {
		t.Fatal(err)
	}
	if reloaded.byToken("secret-token") == nil {
		t.Fatal("the token must match after a reload")
	}
	if reloaded.byToken("wrong-token") != nil {
		t.Fatal("a wrong token must not match")
	}
	if _, err := reloaded.remove("g1"); err != nil {
		t.Fatal(err)
	}
	if reloaded.byToken("secret-token") != nil {
		t.Fatal("a revoked grant's token must stop matching")
	}
}
