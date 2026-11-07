package connector

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/config"
)

// fakeGateway stands in for the server. Each StartPrompt is a turn the test finishes by hand, or at
// once when auto is set.
type fakeGateway struct {
	mu       sync.Mutex
	projects []ProjectInfo
	sessions []SessionInfo
	facts    map[string]SessionFacts
	owner    map[string]string // session id -> project id
	auto     *PromptOutcome    // when set, each turn ends at once with this outcome
	started  []string          // session ids of the StartPrompt calls
	turns    []*fakeTurn
}

type fakeTurn struct {
	done chan struct{}
	once sync.Once
	out  PromptOutcome
}

func (t *fakeTurn) Done() <-chan struct{}  { return t.done }
func (t *fakeTurn) Outcome() PromptOutcome { return t.out }

func (t *fakeTurn) finish(out PromptOutcome) {
	t.once.Do(func() {
		t.out = out
		close(t.done)
	})
}

func (f *fakeGateway) Projects(context.Context) ([]ProjectInfo, error) { return f.projects, nil }

func (f *fakeGateway) Sessions(_ context.Context, projectID string) ([]SessionInfo, error) {
	out := []SessionInfo{}
	for _, s := range f.sessions {
		if projectID == "" || s.ProjectID == projectID {
			out = append(out, s)
		}
	}
	return out, nil
}

func (f *fakeGateway) Facts(_ context.Context, sid string) (SessionFacts, error) {
	facts, ok := f.facts[sid]
	if !ok {
		return SessionFacts{}, errFakeUnknown
	}
	return facts, nil
}

func (f *fakeGateway) StartPrompt(_ context.Context, _ string, sid, _ string) (PromptTurn, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started = append(f.started, sid)
	t := &fakeTurn{done: make(chan struct{})}
	if f.auto != nil {
		t.finish(*f.auto)
	}
	f.turns = append(f.turns, t)
	return t, nil
}

func (f *fakeGateway) startedCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.started)
}

func (f *fakeGateway) turn(i int) *fakeTurn {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.turns[i]
}

var errFakeUnknown = errorString("unknown session")

type errorString string

func (e errorString) Error() string { return string(e) }

// testConnector builds a connector over the fake gateway. Its audit lines go to the returned buffer.
func testConnector(t *testing.T, gw *fakeGateway, limits config.ConnectorLimits) (*Connector, *bytes.Buffer) {
	t.Helper()
	buf := &bytes.Buffer{}
	c := New(Options{
		Config:   config.Connector{PublicOrigin: "https://connector.test.example", Limits: limits},
		StateDir: t.TempDir(),
		Version:  "test",
		Audit:    audit.New(buf),
		Projects: func(context.Context) ([]string, error) {
			ids := []string{}
			for _, p := range gw.projects {
				ids = append(ids, p.ID)
			}
			return ids, nil
		},
		SessionProject: func(_ context.Context, sid string) (string, error) { return gw.owner[sid], nil },
		Gateway:        gw,
	})
	c.limits.now = time.Now
	return c, buf
}

func defaultLimits() config.ConnectorLimits {
	return config.ConnectorLimits{MaxConcurrentTurns: 1, PromptsPerHour: 20, MaxPromptBytes: 8192, MaxResultChars: 20000, SendPromptWaitSeconds: 1}
}

// baseFake is two projects with three sessions: s1 and s2 in p1, s3 in p2.
func baseFake() *fakeGateway {
	title := func(s string) *string { return &s }
	return &fakeGateway{
		projects: []ProjectInfo{{ID: "p1", Name: "Alpha", Folder: "alpha"}, {ID: "p2", Name: "Beta", Folder: "beta"}},
		sessions: []SessionInfo{
			{ID: "s1", ProjectID: "p1", Title: title("first"), Status: "idle"},
			{ID: "s2", ProjectID: "p1", Title: title("second"), Status: "idle", Usage: &Usage{Used: 50000, Size: 200000, UpdatedAt: "2026-11-07T10:00:00.000Z"}},
			{ID: "s3", ProjectID: "p2", Title: title("third"), Status: "running"},
		},
		facts: map[string]SessionFacts{
			"s1": {ProjectName: "Alpha", ProjectFolder: "alpha", Title: title("first"), Status: "idle", StopReason: "end_turn"},
			"s2": {ProjectName: "Alpha", ProjectFolder: "alpha", Title: title("second"), Status: "idle", Usage: &Usage{Used: 50000, Size: 200000}},
			"s3": {ProjectName: "Beta", ProjectFolder: "beta", Title: title("third"), Status: "running"},
		},
		owner: map[string]string{"s1": "p1", "s2": "p1", "s3": "p2"},
	}
}

// call runs one tool through the connector's own dispatch and returns the text and the isError flag.
func call(t *testing.T, c *Connector, g *Grant, name string, args map[string]any) (string, bool) {
	t.Helper()
	params, err := json.Marshal(map[string]any{"name": name, "arguments": args})
	if err != nil {
		t.Fatal(err)
	}
	res, rerr := c.callTool(g, params)
	if rerr != nil {
		t.Fatalf("%s: protocol error %s", name, rerr.Message)
	}
	m := res.(map[string]any)
	content := m["content"].([]map[string]any)
	return content[0]["text"].(string), m["isError"].(bool)
}

func parse(t *testing.T, text string) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(text), &out); err != nil {
		t.Fatalf("not JSON: %v: %s", err, text)
	}
	return out
}

// Scope: each tool refuses a session outside the grant, and a turn another grant started.

func TestToolsRefuseSessionsOutsideTheScope(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{Projects: []string{"p1"}, HasSessions: true, Sessions: []string{"s1"}}}

	if text, isErr := call(t, c, g, "get_context", map[string]any{"sessionId": "s2"}); !isErr || !strings.Contains(text, "not in this grant's scope") {
		t.Fatalf("get_context of an unlisted session: %v %q", isErr, text)
	}
	if text, isErr := call(t, c, g, "get_context", map[string]any{"sessionId": "s3"}); !isErr || !strings.Contains(text, "not in this grant's scope") {
		t.Fatalf("get_context of another project's session: %v %q", isErr, text)
	}
	if text, isErr := call(t, c, g, "list_sessions", map[string]any{"projectId": "p2"}); !isErr || !strings.Contains(text, "projectId is not in this grant's scope") {
		t.Fatalf("list_sessions of another project: %v %q", isErr, text)
	}
	if _, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s2", "text": "hi"}); !isErr {
		t.Fatal("send_prompt to an unlisted session must be refused")
	}
	if gw.startedCount() != 0 {
		t.Fatalf("a refused send_prompt reached the gateway %d times", gw.startedCount())
	}
	// The refusals for an unknown and an out-of-scope session are the same, so a grant cannot probe.
	unknown, _ := call(t, c, g, "get_context", map[string]any{"sessionId": "no-such"})
	outside, _ := call(t, c, g, "get_context", map[string]any{"sessionId": "s3"})
	if unknown != outside {
		t.Fatalf("unknown and outside sessions answer differently: %q vs %q", unknown, outside)
	}
}

func TestListSessionsAndProjectsHonourTheScope(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())

	narrow := &Grant{ID: "g1", Scope: Scope{Projects: []string{"p1"}, HasSessions: true, Sessions: []string{"s1"}}}
	text, isErr := call(t, c, narrow, "list_sessions", map[string]any{})
	if isErr {
		t.Fatal(text)
	}
	sessions := parse(t, text)["sessions"].([]any)
	if len(sessions) != 1 || sessions[0].(map[string]any)["sessionId"] != "s1" {
		t.Fatalf("a session list grant sees only its session: %s", text)
	}

	projects := parse(t, mustCall(t, c, narrow, "list_projects"))["projects"].([]any)
	if len(projects) != 1 || projects[0].(map[string]any)["projectId"] != "p1" {
		t.Fatalf("list_projects shows only the granted project: %v", projects)
	}
	for _, p := range projects {
		if _, has := p.(map[string]any)["path"]; has {
			t.Fatal("list_projects must not carry a full path")
		}
	}

	all := &Grant{ID: "g2", Scope: Scope{AllProjects: true}}
	allSessions := parse(t, mustCall(t, c, all, "list_sessions", map[string]any{"projectId": "p2"}))["sessions"].([]any)
	if len(allSessions) != 1 || allSessions[0].(map[string]any)["status"] != "running" {
		t.Fatalf("list_sessions in one project: %v", allSessions)
	}
}

// mustCall runs a tool that must succeed, and returns its text.
func mustCall(t *testing.T, c *Connector, g *Grant, name string, args ...map[string]any) string {
	t.Helper()
	a := map[string]any{}
	if len(args) > 0 {
		a = args[0]
	}
	text, isErr := call(t, c, g, name, a)
	if isErr {
		t.Fatalf("%s: %s", name, text)
	}
	return text
}

func TestGetTurnIsReadableOnlyByTheGrantThatStartedIt(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())
	owner := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	other := &Grant{ID: "g2", Scope: Scope{AllProjects: true}}

	text, isErr := call(t, c, owner, "send_prompt", map[string]any{"sessionId": "s1", "text": "hello"})
	if isErr || !strings.Contains(text, `"status":"running"`) {
		t.Fatalf("a turn that outlives the wait answers running: %v %s", isErr, text)
	}
	turnID := parse(t, text)["turnId"].(string)
	if _, isErr := call(t, c, other, "get_turn", map[string]any{"turnId": turnID}); !isErr {
		t.Fatal("another grant must not read the turn")
	}
	gw.turn(0).finish(PromptOutcome{StopReason: "end_turn", Reply: "done"})
	done := parse(t, mustCall(t, c, owner, "get_turn", map[string]any{"turnId": turnID}))
	if done["status"] != "done" || done["stopReason"] != "end_turn" || done["reply"] != "done" {
		t.Fatalf("get_turn after the turn ends: %v", done)
	}
}

// Prompt limits (C6).

func TestPromptOverMaxBytesIsRefusedBeforeTheAgent(t *testing.T) {
	gw := baseFake()
	limits := defaultLimits()
	limits.MaxPromptBytes = 8
	c, _ := testConnector(t, gw, limits)
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}

	text, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "123456789"})
	if !isErr || !strings.Contains(text, "larger than 8 bytes") {
		t.Fatalf("an oversize prompt: %v %q", isErr, text)
	}
	if gw.startedCount() != 0 {
		t.Fatal("an oversize prompt must not reach the agent")
	}
	gw.auto = &PromptOutcome{StopReason: "end_turn", Reply: "ok"}
	if _, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "12345678"}); isErr {
		t.Fatal("a prompt of exactly maxPromptBytes is allowed")
	}
}

func TestPromptsPerHourCountsPerGrantAndSlides(t *testing.T) {
	gw := baseFake()
	gw.auto = &PromptOutcome{StopReason: "end_turn", Reply: "ok"}
	limits := defaultLimits()
	limits.PromptsPerHour = 2
	c, _ := testConnector(t, gw, limits)
	now := time.Date(2026, 11, 7, 10, 0, 0, 0, time.UTC)
	c.limits.now = func() time.Time { return now }
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	other := &Grant{ID: "g2", Scope: Scope{AllProjects: true}}

	for i := 0; i < 2; i++ {
		if _, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"}); isErr {
			t.Fatalf("prompt %d within the limit was refused", i+1)
		}
	}
	text, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"})
	if !isErr || !strings.Contains(text, "prompt limit reached: 2 prompts per hour") {
		t.Fatalf("the third prompt in the hour: %v %q", isErr, text)
	}
	if _, isErr := call(t, c, other, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"}); isErr {
		t.Fatal("the hourly limit is per grant")
	}
	now = now.Add(time.Hour + time.Second)
	if _, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"}); isErr {
		t.Fatal("the window slides: an hour later the grant may send again")
	}
}

func TestOneRunningTurnPerSessionAndMaxConcurrentOverall(t *testing.T) {
	gw := baseFake()
	limits := defaultLimits()
	limits.MaxConcurrentTurns = 1
	c, _ := testConnector(t, gw, limits)
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}

	first, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "one"})
	if isErr || !strings.Contains(first, `"running"`) {
		t.Fatalf("the first turn runs: %v %s", isErr, first)
	}
	if text, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "two"}); !isErr || !strings.Contains(text, "already has a turn running") {
		t.Fatalf("a second turn in one session: %v %q", isErr, text)
	}
	if text, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s2", "text": "three"}); !isErr || !strings.Contains(text, "maxConcurrentTurns is 1") {
		t.Fatalf("a second session over maxConcurrentTurns: %v %q", isErr, text)
	}
	gw.turn(0).finish(PromptOutcome{StopReason: "end_turn", Reply: "ok"})
	deadline := time.Now().Add(5 * time.Second)
	for {
		text, isErr := call(t, c, g, "send_prompt", map[string]any{"sessionId": "s2", "text": "four"})
		if !isErr {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the slot was never released after the turn ended: %s", text)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The reply and the summary.

func TestReplyIsCappedAtMaxResultCharsWithoutSplittingACharacter(t *testing.T) {
	gw := baseFake()
	gw.auto = &PromptOutcome{StopReason: "end_turn", Reply: "ééééé"} // five characters, ten bytes
	limits := defaultLimits()
	limits.MaxResultChars = 3
	c, _ := testConnector(t, gw, limits)
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}

	res := parse(t, mustCall(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"}))
	if res["reply"] != "ééé" || res["truncated"] != true {
		t.Fatalf("a reply over maxResultChars is cut with truncated true: %v", res)
	}
	if res["stopReason"] != "end_turn" || res["status"] != "done" {
		t.Fatalf("done shape: %v", res)
	}
	if _, has := res["context"]; !has {
		t.Fatal("a done answer carries the context summary")
	}

	gw.auto = &PromptOutcome{StopReason: "end_turn", Reply: "ab"}
	short := parse(t, mustCall(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hi"}))
	if short["reply"] != "ab" || short["truncated"] != nil {
		t.Fatalf("a reply within the cap is not marked: %v", short)
	}
}

func TestSummaryStaysWithinTheCap(t *testing.T) {
	gw := baseFake()
	long := strings.Repeat("a very long running tool title ", 20)
	tools := []string{}
	for i := 0; i < 8; i++ {
		tools = append(tools, long)
	}
	name := strings.Repeat("N", 500)
	gw.facts["s1"] = SessionFacts{
		ProjectName: name, ProjectFolder: name, Title: &name, Status: "running",
		Usage: &Usage{Used: 190000, Size: 200000}, RunningTools: tools, PendingApprovals: 3, StopReason: "end_turn",
	}
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}

	text := mustCall(t, c, g, "get_context", map[string]any{"sessionId": "s1"})
	if len(text) > maxSummaryChars {
		t.Fatalf("summary is %d characters, cap %d", len(text), maxSummaryChars)
	}
	s := parse(t, text)
	if n := len(s["runningTools"].([]any)); n > maxSummaryTools {
		t.Fatalf("%d running tools in the summary, cap %d", n, maxSummaryTools)
	}
	if s["pendingApprovals"] != float64(3) {
		t.Fatalf("pending approvals: %v", s["pendingApprovals"])
	}
}

func TestSummaryKeepsTheMostRecentToolsAndTheUsageFields(t *testing.T) {
	gw := baseFake()
	gw.facts["s1"] = SessionFacts{
		ProjectName: "Alpha", ProjectFolder: "alpha", Status: "running",
		Usage: &Usage{Used: 50000, Size: 200000}, RunningTools: []string{"tool 1", "tool 2", "tool 3", "tool 4", "tool 5", "tool 6", "tool 7"},
	}
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	s := parse(t, mustCall(t, c, g, "get_context", map[string]any{"sessionId": "s1"}))

	tools := s["runningTools"].([]any)
	if len(tools) != 5 || tools[0] != "tool 3" || tools[4] != "tool 7" {
		t.Fatalf("the five most recent tools: %v", tools)
	}
	usage := s["usage"].(map[string]any)
	if usage["used"] != float64(50000) || usage["size"] != float64(200000) || usage["percent"] != float64(25) || usage["left"] != float64(150000) {
		t.Fatalf("usage: %v", usage)
	}
	if _, has := s["project"].(map[string]any)["path"]; has {
		t.Fatal("the summary never carries a full path")
	}
	if _, has := s["alwaysAllow"]; has {
		t.Fatal("alwaysAllow is left out when the gateway does not know it")
	}
}

func TestSummaryNamesMissingUsageAndOmitsLeftWithoutASize(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	s := parse(t, mustCall(t, c, g, "get_context", map[string]any{"sessionId": "s1"}))
	if s["usage"] != "not reported by Bob" {
		t.Fatalf("no usage: %v", s["usage"])
	}
	gw.facts["s1"] = SessionFacts{ProjectName: "Alpha", Status: "idle", Usage: &Usage{Used: 12, Size: 0}}
	s = parse(t, mustCall(t, c, g, "get_context", map[string]any{"sessionId": "s1"}))
	usage := s["usage"].(map[string]any)
	if _, has := usage["left"]; has {
		t.Fatalf("left is shown only when size is above 0: %v", usage)
	}
	if _, has := usage["percent"]; has {
		t.Fatalf("percent is shown only when size is above 0: %v", usage)
	}
}

// The audit: source and grant on the line, never the text.

func TestPromptTextNeverReachesTheAudit(t *testing.T) {
	gw := baseFake()
	gw.auto = &PromptOutcome{StopReason: "end_turn", Reply: "reply"}
	c, buf := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	const secret = "SECRET-PROMPT-TEXT-D2"

	mustCall(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": secret})
	out := buf.String()
	if strings.Contains(out, secret) {
		t.Fatalf("prompt text in the audit: %s", out)
	}
	if !strings.Contains(out, `"event":"connector_prompt"`) || !strings.Contains(out, `"source":"claude"`) || !strings.Contains(out, `"grant":"g1"`) {
		t.Fatalf("the prompt line names the source and the grant: %s", out)
	}
}

// Context refusals and the summary never read beyond the grant.

func TestGetContextOfAnUnknownSessionIsAPlainError(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}
	if text, isErr := call(t, c, g, "get_context", map[string]any{"sessionId": "nope"}); !isErr || text == "" {
		t.Fatalf("an unknown session: %v %q", isErr, text)
	}
}
