package server

// Tests of the per-session runner routing (D-125): an agent per (project, runner), the route by the
// session's runner, the wire fields, and the limits and state that count every agent.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// fakeAgentScript is a stand-in ACP agent in sh. It answers initialize, and answers session/new with
// a session id of its runner ($R) and a counter. It keeps every line it reads in $LOG.
const fakeAgentScript = `n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$LOG"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
  case "$line" in
    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"agentCapabilities":{}}}\n' "$id" ;;
    *'"method":"session/new"'*) n=$((n+1)); printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"%s-%s"}}\n' "$id" "$R" "$n" ;;
  esac
done
`

// fakeRunner starts the sh agent above for whatever runner id the project copy carries, and records
// the project copies it was asked to start.
type fakeRunner struct {
	runner // nil: the git paths are not used here
	log    string

	mu      sync.Mutex
	started []store.Project
}

func (f *fakeRunner) start(p store.Project, home string) (*agentProcess, error) {
	f.mu.Lock()
	f.started = append(f.started, p)
	f.mu.Unlock()
	cmd := exec.Command("/bin/sh", "-c", fakeAgentScript)
	cmd.Env = append(os.Environ(), "R="+p.Runner, "LOG="+f.log)
	return startProcess(cmd, nil)
}

// exec and oneOff fail softly, so the turn-start snapshot is audited as failed and the test goes on.
func (f *fakeRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	return gitResult{}, errors.New("no git in this test")
}

func (f *fakeRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	return gitResult{}, errors.New("no git in this test")
}

func (f *fakeRunner) startedRunners() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := []string{}
	for _, p := range f.started {
		out = append(out, p.Runner)
	}
	return out
}

type agentsRig struct {
	t       *testing.T
	s       *Server
	db      *store.Store
	fake    *fakeRunner
	project string // realpath of the project folder
}

// newAgentsRig is a gateway with two runners, bob (the default) and claude, one project p1 on bob, and
// the fake runner.
func newAgentsRig(t *testing.T, maxAgents int) *agentsRig {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "root")
	project := filepath.Join(root, "project")
	if err := os.MkdirAll(project, 0o755); err != nil {
		t.Fatal(err)
	}
	raw := fmt.Sprintf(`{
		"listen": {"host": "127.0.0.1", "port": 0},
		"tokens": [{"id": "phone", "identity": "owner", "sha256": %q}],
		"runners": {"bob": {"command": ["/bin/false"]}, "claude": {"command": ["/bin/false"]}},
		"defaultRunner": "bob",
		"projects": {"roots": [%q]},
		"stateDir": %q,
		"limits": {"maxAgentsTotal": %d, "maxAgentsPerIdentity": %d},
		"runner": {"kind": "host", "allowHost": true}
	}`, fmt.Sprintf("%064d", 1), root, filepath.Join(dir, "state"), maxAgents, maxAgents)
	v, err := jsonv.Parse([]byte(raw))
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
	if err := db.CreateProject(context.Background(), store.Project{ID: "p1", Name: "p", Path: project, Created: "2026-11-27T00:00:00.000Z", Runner: "bob"}); err != nil {
		t.Fatal(err)
	}
	s := New(cfg, audit.New(&syncBuffer{}), db)
	fake := &fakeRunner{log: filepath.Join(dir, "agent.log")}
	s.runner = fake
	t.Cleanup(s.Shutdown)
	return &agentsRig{t: t, s: s, db: db, fake: fake, project: project}
}

var testWho = audit.Who{Identity: "owner", Device: "phone", Scope: config.ScopeFull}

// create runs _acpcode/sessions/create with the given runner ("" sends none) and returns the result.
func (r *agentsRig) create(runner string) (map[string]any, *rpcError) {
	r.t.Helper()
	params := map[string]any{"cwd": r.project, "prompt": []map[string]string{{"type": "text", "text": "hi"}}}
	if runner != "" {
		params["runner"] = runner
	}
	return r.createWith(params)
}

func (r *agentsRig) createWith(params map[string]any) (map[string]any, *rpcError) {
	r.t.Helper()
	body, _ := json.Marshal(params)
	v, err := jsonv.Parse(body)
	if err != nil {
		r.t.Fatal(err)
	}
	var gotErr *rpcError
	var gotResult any
	r.s.serveCreate(testWho, jsonv.Str("1"), v, func(_ *jsonv.Value, result any, rerr *rpcError) { gotResult, gotErr = result, rerr })
	if gotErr != nil {
		return nil, gotErr
	}
	out, _ := json.Marshal(gotResult)
	var m map[string]any
	if err := json.Unmarshal(out, &m); err != nil {
		r.t.Fatal(err)
	}
	return m, nil
}

func (r *agentsRig) route(method, params string) (*projectAgent, *rpcError) {
	r.t.Helper()
	msg := parseJSON(r.t, fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"method":%q,"params":%s}`, method, params))
	return r.s.route(context.Background(), &client{}, msg, method)
}

func (r *agentsRig) state(a *projectAgent) agentState {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.state
}

// session/new picks the agent by _meta["acpcode/runner"]: none, "" and the project's own runner are
// the project's agent (key = project id); another runner is p1@runner; an unknown id is refused.
func TestRouteSessionNewByRunner(t *testing.T) {
	r := newAgentsRig(t, 16)
	cwd := fmt.Sprintf("%q", r.project)
	for _, tc := range []struct{ name, meta, key, runner string }{
		{"none", ``, "p1", ""},
		{"empty", `,"_meta":{"acpcode/runner":""}`, "p1", ""},
		{"null", `,"_meta":{"acpcode/runner":null}`, "p1", ""},
		{"own runner", `,"_meta":{"acpcode/runner":"bob"}`, "p1", ""},
		{"other runner", `,"_meta":{"acpcode/runner":"claude"}`, "p1@claude", "claude"},
	} {
		a, rerr := r.route("session/new", `{"cwd":`+cwd+tc.meta+`}`)
		if rerr != nil {
			t.Fatalf("%s: %+v", tc.name, rerr)
		}
		if a.key != tc.key || a.id != "p1" || a.runner != tc.runner {
			t.Errorf("%s: agent key %q id %q runner %q; want key %q runner %q", tc.name, a.key, a.id, a.runner, tc.key, tc.runner)
		}
	}
	for _, bad := range []string{`"nope"`, `7`, `{"a":1}`} {
		_, rerr := r.route("session/new", `{"cwd":`+cwd+`,"_meta":{"acpcode/runner":`+bad+`}}`)
		if rerr == nil || rerr.Code != rpcInvalidParams || rerr.Message != "runner must be the id of one of the gateway's runners" {
			t.Errorf("runner %s: %+v, want -32602 runner must be the id of one of the gateway's runners", bad, rerr)
		}
	}
	if got := r.s.agentsOf("p1"); len(got) != 2 || got[0].key != "p1" || got[1].key != "p1@claude" {
		t.Fatalf("agentsOf = %v, want the own agent first, then p1@claude", got)
	}
}

// A request for an existing session goes to the agent of the session's recorded runner; a session
// with none recorded goes to the project's own agent.
func TestRouteExistingSessionByRecordedRunner(t *testing.T) {
	r := newAgentsRig(t, 16)
	ctx := context.Background()
	for _, sid := range []string{"s-plain", "s-claude", "s-own"} {
		if err := r.db.RecordSession(ctx, sid, "p1"); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.db.SetSessionRunner(ctx, "s-claude", "claude"); err != nil {
		t.Fatal(err)
	}
	if err := r.db.SetSessionRunner(ctx, "s-own", "bob"); err != nil { // equal to the project's runner: its own agent
		t.Fatal(err)
	}
	for sid, key := range map[string]string{"s-plain": "p1", "s-claude": "p1@claude", "s-own": "p1"} {
		a, rerr := r.route("session/prompt", `{"sessionId":"`+sid+`","prompt":[]}`)
		if rerr != nil || a.key != key {
			t.Errorf("session %s routed to %v (%+v), want key %q", sid, a, rerr, key)
		}
	}
	// A _meta runner on a request for an existing session does not move it.
	a, rerr := r.route("session/load", `{"sessionId":"s-plain","cwd":`+fmt.Sprintf("%q", r.project)+`,"_meta":{"acpcode/runner":"claude"}}`)
	if rerr != nil || a.key != "p1" {
		t.Errorf("a recorded session keeps its agent: %v %+v", a, rerr)
	}
}

// The gateway's _meta key is read and removed, and an _meta it empties goes too; other keys stay.
func TestDropRunnerKey(t *testing.T) {
	p := parseJSON(t, `{"cwd":"/x","_meta":{"acpcode/runner":"claude","bob/mode":"plan"}}`)
	dropRunnerKey(p)
	if got := string(p.Marshal()); got != `{"cwd":"/x","_meta":{"bob/mode":"plan"}}` {
		t.Fatalf("params = %s", got)
	}
	only := parseJSON(t, `{"cwd":"/x","_meta":{"acpcode/runner":"claude"}}`)
	dropRunnerKey(only)
	if got := string(only.Marshal()); got != `{"cwd":"/x"}` {
		t.Fatalf("params = %s", got)
	}
}

// Two agents of one project run at once under the host runner, each started with the project copy
// carrying its own runner; a session of each is recorded as the contract says, the stop of one
// session reaches only its own agent, and the agent never sees the gateway's _meta key.
func TestTwoAgentsOfOneProjectRunAtOnce(t *testing.T) {
	r := newAgentsRig(t, 16)
	own, rerr := r.create("")
	if rerr != nil {
		t.Fatalf("create on the own runner: %+v", rerr)
	}
	other, rerr := r.create("claude")
	if rerr != nil {
		t.Fatalf("create on claude: %+v", rerr)
	}
	if own["sessionId"] != "bob-1" || other["sessionId"] != "claude-1" {
		t.Fatalf("sessions = %v, %v; want bob-1 and claude-1 (each agent got its runner)", own["sessionId"], other["sessionId"])
	}
	ctx := context.Background()
	if got, _ := r.db.SessionRunner(ctx, "bob-1"); got != "" {
		t.Errorf("a session on the project's runner records none, got %q", got)
	}
	if got, _ := r.db.SessionRunner(ctx, "claude-1"); got != "claude" {
		t.Errorf("a session on claude records claude, got %q", got)
	}
	if got := r.fake.startedRunners(); len(got) != 2 || !(got[0] == "bob" && got[1] == "claude" || got[0] == "claude" && got[1] == "bob") {
		t.Fatalf("started with runners %v, want one start each for bob and claude", got)
	}
	a1, a2 := r.s.agentFor("p1", ""), r.s.agentFor("p1", "claude")
	if a1 == a2 || r.state(a1) != agentRunning || r.state(a2) != agentRunning {
		t.Fatalf("both agents must run at once: %v %v", r.state(a1), r.state(a2))
	}
	if r.s.agentSlots != 2 {
		t.Fatalf("agentSlots = %d, want 2", r.s.agentSlots)
	}
	if got, _ := r.route("session/prompt", `{"sessionId":"claude-1","prompt":[]}`); got != a2 {
		t.Fatalf("claude-1 must route to the claude agent")
	}
	if log, _ := os.ReadFile(r.fake.log); strings.Contains(string(log), "acpcode/runner") {
		t.Fatalf("the gateway's _meta key reached an agent:\n%s", log)
	}

	// The agent state of the project is the aggregate of its agents.
	ps := r.s.stateOf("p1")
	ps.mu.Lock()
	want := ps.want
	ps.mu.Unlock()
	if want != "running" {
		t.Fatalf("project state = %q, want running", want)
	}

	// Stop of the claude session, agent scope: only the claude agent stops.
	res, rerr := r.s.stopSession(ctx, testWho, parseJSON(t, `{"sessionId":"claude-1","scope":"agent"}`))
	if rerr != nil {
		t.Fatalf("stop: %+v", rerr)
	}
	if m, _ := res.(map[string]any); m["outcome"] != "stopped" {
		t.Fatalf("stop result = %v", res)
	}
	if r.state(a2) != agentStopped || r.state(a1) != agentRunning {
		t.Fatalf("after the stop claude is %v and own is %v; want stopped and running", r.state(a2), r.state(a1))
	}
	ps.mu.Lock()
	want = ps.want
	ps.mu.Unlock()
	if want != "running" {
		t.Fatalf("project state with one agent left = %q, want running", want)
	}
	// A turn-scope stop of the other session reaches the own agent, whose prompt the fake never ends.
	res, rerr = r.s.stopSession(ctx, testWho, parseJSON(t, `{"sessionId":"bob-1","scope":"turn"}`))
	if m, _ := res.(map[string]any); rerr != nil || m["outcome"] != "still_running" {
		t.Fatalf("turn stop = %v %+v", res, rerr)
	}
}

// maxAgentsTotal counts every agent of every project and runner.
func TestMaxAgentsTotalCountsEveryRunnersAgent(t *testing.T) {
	r := newAgentsRig(t, 1)
	if _, rerr := r.create(""); rerr != nil {
		t.Fatalf("first agent: %+v", rerr)
	}
	_, rerr := r.create("claude")
	if rerr == nil || !strings.Contains(rerr.Message, "capacity") {
		t.Fatalf("second runner's agent: %+v, want the capacity refusal", rerr)
	}
	if r.s.agentSlots != 1 {
		t.Fatalf("agentSlots = %d, want 1", r.s.agentSlots)
	}
}

// _acpcode/sessions/create refuses a runner the config does not list, before anything starts.
func TestCreateRefusesAnUnknownRunner(t *testing.T) {
	r := newAgentsRig(t, 16)
	for _, bad := range []any{"nope", 7, true} {
		_, rerr := r.createWith(map[string]any{"cwd": r.project, "runner": bad, "prompt": []map[string]string{{"type": "text", "text": "hi"}}})
		if rerr == nil || rerr.Code != rpcInvalidParams || rerr.Message != "runner must be the id of one of the gateway's runners" {
			t.Errorf("runner %v: %+v, want -32602", bad, rerr)
		}
	}
	if got := r.fake.startedRunners(); len(got) != 0 {
		t.Fatalf("nothing may start for a refused runner, started %v", got)
	}
	// The phone's own _meta keys go on to the agent, and the runner is added beside them.
	if _, rerr := r.createWith(map[string]any{"cwd": r.project, "runner": "claude", "_meta": map[string]any{"bob/mode": "plan"},
		"prompt": []map[string]string{{"type": "text", "text": "hi"}}}); rerr != nil {
		t.Fatalf("create with _meta: %+v", rerr)
	}
	log, _ := os.ReadFile(r.fake.log)
	if !strings.Contains(string(log), `"_meta":{"bob/mode":"plan"}`) || strings.Contains(string(log), "acpcode/runner") {
		t.Fatalf("the agent's session/new must keep the phone's _meta and not the runner key:\n%s", log)
	}
}

// The state of a project is the aggregate of its agents: running beats starting beats stopping beats stopped.
func TestAggregateStatePrecedence(t *testing.T) {
	cases := []struct {
		in   map[string]string
		want string
	}{
		{map[string]string{}, "stopped"},
		{map[string]string{"a": "stopped", "b": "stopped"}, "stopped"},
		{map[string]string{"a": "stopping", "b": "stopped"}, "stopping"},
		{map[string]string{"a": "stopping", "b": "starting"}, "starting"},
		{map[string]string{"a": "starting", "b": "running", "c": "stopping"}, "running"},
	}
	for _, tc := range cases {
		if got := aggregateState(tc.in); got != tc.want {
			t.Errorf("aggregateState(%v) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// sessions/index rows carry runner: the recorded one, else the session's project's runner.
func TestSessionsIndexCarriesRunner(t *testing.T) {
	r := newAgentsRig(t, 16)
	ctx := context.Background()
	for _, sid := range []string{"s1", "s2"} {
		if err := r.db.RecordSession(ctx, sid, "p1"); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.db.SetSessionRunner(ctx, "s2", "claude"); err != nil {
		t.Fatal(err)
	}
	for _, params := range []string{`{}`, `{"projectId":"p1"}`} {
		res, rerr := r.s.sessionIndex(ctx, testWho, parseJSON(t, params))
		if rerr != nil {
			t.Fatal(rerr)
		}
		body, _ := json.Marshal(res)
		var out struct {
			Sessions []struct {
				SessionID string `json:"sessionId"`
				Runner    string `json:"runner"`
			} `json:"sessions"`
		}
		if err := json.Unmarshal(body, &out); err != nil {
			t.Fatal(err)
		}
		got := map[string]string{}
		for _, s := range out.Sessions {
			got[s.SessionID] = s.Runner
		}
		if len(got) != 2 || got["s1"] != "bob" || got["s2"] != "claude" {
			t.Errorf("index %s runners = %v, want s1 bob (project's) and s2 claude (recorded)", params, got)
		}
	}
}

// projects/list carries parentId and branch for a worktree project, and leaves them out for others.
func TestProjectsListCarriesParentAndBranch(t *testing.T) {
	r := newAgentsRig(t, 16)
	ctx := context.Background()
	child := store.Project{ID: "c1", Name: "p (claude)", Path: r.project + "-claude-abcd1234", Created: "2026-11-27T00:00:01.000Z",
		Runner: "claude", ParentID: "p1", Branch: "acpcode/claude/abcd1234"}
	if err := r.db.CreateProject(ctx, child); err != nil {
		t.Fatal(err)
	}
	res, rerr := r.s.handleExtension(ctx, testWho, "_acpcode/projects/list", parseJSON(t, `{}`))
	if rerr != nil {
		t.Fatal(rerr)
	}
	body, _ := json.Marshal(res)
	var out struct {
		Projects []map[string]any `json:"projects"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	byID := map[string]map[string]any{}
	for _, p := range out.Projects {
		byID[p["id"].(string)] = p
	}
	if c := byID["c1"]; c["parentId"] != "p1" || c["branch"] != "acpcode/claude/abcd1234" || c["runner"] != "claude" {
		t.Errorf("worktree project = %v", c)
	}
	if p := byID["p1"]; p == nil {
		t.Fatal("p1 not listed")
	} else if _, has := p["parentId"]; has {
		t.Errorf("an ordinary project must not carry parentId: %v", p)
	} else if _, has := p["branch"]; has {
		t.Errorf("an ordinary project must not carry branch: %v", p)
	}
	if !strings.Contains(string(toProjectJSONBytes(t, child)), `"parentId":"p1"`) {
		t.Error("projectJSON must carry parentId")
	}
}

func toProjectJSONBytes(t *testing.T, p store.Project) []byte {
	t.Helper()
	b, err := json.Marshal(toProjectJSON(p))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Shutdown stops every agent of every runner and waits for it.
func TestShutdownStopsEveryRunnersAgent(t *testing.T) {
	r := newAgentsRig(t, 16)
	if _, rerr := r.create(""); rerr != nil {
		t.Fatal(rerr)
	}
	if _, rerr := r.create("claude"); rerr != nil {
		t.Fatal(rerr)
	}
	a1, a2 := r.s.agentFor("p1", ""), r.s.agentFor("p1", "claude")
	a1.mu.Lock()
	p1 := a1.proc
	a1.mu.Unlock()
	a2.mu.Lock()
	p2 := a2.proc
	a2.mu.Unlock()
	done := make(chan struct{})
	go func() { r.s.Shutdown(); close(done) }()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("Shutdown did not return")
	}
	if !p1.hasExited() || !p2.hasExited() {
		t.Fatalf("both agent processes must have exited: %v %v", p1.hasExited(), p2.hasExited())
	}
}
