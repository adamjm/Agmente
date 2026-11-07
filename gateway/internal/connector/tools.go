package connector

// The connector's five tools (C7, D-096): list_projects, list_sessions, get_context, send_prompt and
// get_turn. Each one checks the grant's scope before it reads or sends anything, and send_prompt
// runs the limits of C6 before a prompt reaches the agent.

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
)

const (
	gatewayTimeout    = 30 * time.Second // a store read the tools make
	maxListedSessions = 200              // list_sessions answers at most this many rows
	maxSummaryChars   = 1000             // get_context: the summary is at most about this many characters (C7)
	maxSummaryTools   = 5                // running tool titles in a summary (C7)
	turnKeepFor       = time.Hour        // a finished turn stays readable with get_turn for this long
)

// Gateway is what the tools read and do on the gateway. The server implements it (server
// connector_tools.go); the unit tests use a fake.
type Gateway interface {
	// Projects returns every registered project.
	Projects(ctx context.Context) ([]ProjectInfo, error)
	// Sessions returns the recorded sessions of one project, or of all of them when projectID is "".
	Sessions(ctx context.Context, projectID string) ([]SessionInfo, error)
	// Facts returns what get_context summarises about one session. It fails for an unknown session.
	Facts(ctx context.Context, sessionID string) (SessionFacts, error)
	// StartPrompt sends one prompt into a session as source claude, for the grant. It returns the turn
	// as soon as the prompt is accepted for sending. A non-nil error means the prompt was not sent.
	StartPrompt(ctx context.Context, grantID, sessionID, text string) (PromptTurn, error)
}

// ProjectInfo is a project as the tools show it: its folder is the basename, never the full path.
type ProjectInfo struct {
	ID, Name, Folder string
}

// SessionInfo is one session row. Usage is nil when Bob has reported none (C1).
type SessionInfo struct {
	ID, ProjectID string
	Title         *string
	Status        string
	Usage         *Usage
}

// Usage is a session's last reported usage (C1).
type Usage struct {
	Used, Size   int64
	CostAmount   *float64
	CostCurrency *string
	UpdatedAt    string
}

// SessionFacts is what get_context reads about a session.
type SessionFacts struct {
	ProjectName, ProjectFolder string
	Title                      *string
	Status                     string
	Usage                      *Usage
	RunningTools               []string // titles of tool calls with no terminal update, oldest first
	PendingApprovals           int
	StopReason                 string // the last turn's stop reason; "" when there is none
	AlwaysAllow                *bool  // nil when the gateway does not hold the session's MCP list
}

// PromptTurn is one turn a connector prompt started. Done closes when the agent has answered the
// prompt, or when the turn could not run; Outcome then reports how it ended.
type PromptTurn interface {
	Done() <-chan struct{}
	Outcome() PromptOutcome
}

// PromptOutcome is how a turn ended. Err is set only when the gateway could not run the turn (the
// agent exited, the session is unknown). An agent error is StopReason "error" with the reply so far.
type PromptOutcome struct {
	StopReason string
	Reply      string
	Err        string
}

// turnRegistry holds the turns send_prompt started, so get_turn can read them. A turn is readable
// only by the grant that started it.
type turnRegistry struct {
	mu    sync.Mutex
	now   func() time.Time
	turns map[string]*turnRecord // by turn id; guarded by mu
}

type turnRecord struct {
	id, grantID, sessionID string
	turn                   PromptTurn
	release                func()    // frees the session's turn slot; safe to call twice
	finished               time.Time // zero while the turn runs; guarded by turnRegistry.mu
}

func newTurnRegistry() *turnRegistry {
	return &turnRegistry{now: time.Now, turns: map[string]*turnRecord{}}
}

// add records a turn under a new random id and drops the finished turns that are past their keep.
func (r *turnRegistry) add(grantID, sessionID string, turn PromptTurn) *turnRecord {
	rec := &turnRecord{id: randomString(12), grantID: grantID, sessionID: sessionID, turn: turn}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	for id, old := range r.turns {
		if !old.finished.IsZero() && now.Sub(old.finished) > turnKeepFor {
			delete(r.turns, id)
		}
	}
	r.turns[rec.id] = rec
	return rec
}

func (r *turnRegistry) markFinished(id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if rec := r.turns[id]; rec != nil {
		rec.finished = r.now()
	}
}

// lookup returns the turn when the grant started it. Another grant's turn and an unknown id get the
// same answer, nil, so a grant cannot probe for other turns.
func (r *turnRegistry) lookup(grantID, id string) *turnRecord {
	r.mu.Lock()
	defer r.mu.Unlock()
	if rec := r.turns[id]; rec != nil && rec.grantID == grantID {
		return rec
	}
	return nil
}

func (c *Connector) gateway() (Gateway, error) {
	if c.opts.Gateway == nil {
		return nil, errors.New("the connector tools are not wired to the gateway")
	}
	return c.opts.Gateway, nil
}

func gatewayContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), gatewayTimeout)
}

// listProjects answers the projects the grant reaches.
func (c *Connector) listProjects(g *Grant) (any, error) {
	gw, err := c.gateway()
	if err != nil {
		return nil, err
	}
	ctx, cancel := gatewayContext()
	defer cancel()
	projects, err := gw.Projects(ctx)
	if err != nil {
		return nil, errors.New("cannot read projects")
	}
	out := []map[string]any{}
	for _, p := range projects {
		if g.Scope.Allows(p.ID, "") {
			out = append(out, map[string]any{"projectId": p.ID, "name": clip(p.Name, 80), "folder": clip(p.Folder, 80)})
		}
	}
	return map[string]any{"projects": out}, nil
}

// listSessions answers the sessions the grant reaches, optionally in one project.
func (c *Connector) listSessions(g *Grant, args map[string]json.RawMessage) (any, error) {
	pid, err := stringArg(args, "projectId", false)
	if err != nil {
		return nil, err
	}
	if pid != "" && !g.Scope.Allows(pid, "") {
		return nil, errOutsideScope("projectId")
	}
	gw, err := c.gateway()
	if err != nil {
		return nil, err
	}
	ctx, cancel := gatewayContext()
	defer cancel()
	rows, err := gw.Sessions(ctx, pid)
	if err != nil {
		return nil, errors.New("cannot read sessions")
	}
	out := []map[string]any{}
	truncated := false
	for _, r := range rows {
		if !g.Scope.Allows(r.ProjectID, r.ID) {
			continue
		}
		if len(out) == maxListedSessions {
			truncated = true
			break
		}
		out = append(out, sessionEntry(r))
	}
	res := map[string]any{"sessions": out}
	if truncated {
		res["truncated"] = true
	}
	return res, nil
}

func sessionEntry(r SessionInfo) map[string]any {
	e := map[string]any{"sessionId": r.ID, "projectId": r.ProjectID, "status": r.Status}
	if r.Title != nil {
		e["title"] = clip(*r.Title, 120)
	}
	if r.Usage != nil {
		e["usage"] = usageObject(r.Usage)
	}
	return e
}

// usageObject is the C1 usage object: used, size, the cost when Bob sent one, and the update time.
func usageObject(u *Usage) map[string]any {
	o := map[string]any{"used": u.Used, "size": u.Size, "updatedAt": u.UpdatedAt}
	if u.CostAmount != nil {
		o["costAmount"] = *u.CostAmount
	}
	if u.CostCurrency != nil {
		o["costCurrency"] = *u.CostCurrency
	}
	return o
}

// getContext answers the lean summary of one session in the grant's scope.
func (c *Connector) getContext(g *Grant, args map[string]json.RawMessage) (any, error) {
	sid, err := stringArg(args, "sessionId", true)
	if err != nil {
		return nil, err
	}
	if _, err := c.sessionInScope(g, sid); err != nil {
		return nil, err
	}
	return c.contextFor(sid)
}

// contextFor reads a session's facts and makes the summary of C7.
func (c *Connector) contextFor(sid string) (map[string]any, error) {
	gw, err := c.gateway()
	if err != nil {
		return nil, err
	}
	ctx, cancel := gatewayContext()
	defer cancel()
	facts, err := gw.Facts(ctx, sid)
	if err != nil {
		return nil, errors.New("cannot read the session")
	}
	return summarize(sid, facts), nil
}

// summarize builds the C7 summary: names and titles, status, usage, running tool titles (at most
// five), pending approvals, the last stop reason and alwaysAllow. No prompt or output text. The
// result is held to maxSummaryChars: the oldest tool titles go first, then the names are shortened.
func summarize(sid string, f SessionFacts) map[string]any {
	tools := f.RunningTools
	if len(tools) > maxSummaryTools {
		tools = tools[len(tools)-maxSummaryTools:] // the most recent five
	}
	for width := 120; ; width /= 2 {
		for n := len(tools); n >= 0; n-- {
			out := summaryWith(sid, f, tools[len(tools)-n:], width)
			if jsonSize(out) <= maxSummaryChars {
				return out
			}
		}
		if width == 0 {
			// Not reached in practice: the fixed fields are far below the cap. The guarantee holds anyway.
			return map[string]any{"sessionId": sid, "status": f.Status, "runningTools": []string{}}
		}
	}
}

func summaryWith(sid string, f SessionFacts, tools []string, width int) map[string]any {
	titles := make([]string, 0, len(tools))
	for _, t := range tools {
		titles = append(titles, clip(t, width))
	}
	out := map[string]any{
		"sessionId":        sid,
		"project":          map[string]any{"name": clip(f.ProjectName, width), "folder": clip(f.ProjectFolder, width)},
		"status":           f.Status,
		"usage":            usageSummary(f.Usage),
		"runningTools":     titles,
		"pendingApprovals": f.PendingApprovals,
	}
	if f.Title != nil {
		out["title"] = clip(*f.Title, width)
	}
	if f.StopReason != "" {
		out["stopReason"] = f.StopReason
	}
	if f.AlwaysAllow != nil {
		out["alwaysAllow"] = *f.AlwaysAllow
	}
	return out
}

// usageSummary is "not reported by Bob", or used/size with the percent used and what is left. Left
// and percent are shown only when size is above 0 (C1).
func usageSummary(u *Usage) any {
	if u == nil {
		return "not reported by Bob"
	}
	o := map[string]any{"used": u.Used, "size": u.Size}
	if u.Size > 0 {
		o["percent"] = (u.Used*200 + u.Size) / (2 * u.Size) // used / size as a percent, rounded to the nearest
		left := u.Size - u.Used
		if left < 0 {
			left = 0
		}
		o["left"] = left
	}
	return o
}

func jsonSize(v any) int {
	b, err := json.Marshal(v)
	if err != nil {
		return maxSummaryChars + 1
	}
	return len(b)
}

// sendPrompt sends one prompt into a session in the grant's scope, as source claude, and waits for
// the turn to end (up to sendPromptWaitSeconds). The limits run first: the prompt size, then the
// hour's count for the grant, then one running turn for the session and maxConcurrentTurns.
func (c *Connector) sendPrompt(g *Grant, args map[string]json.RawMessage) (any, error) {
	sid, err := stringArg(args, "sessionId", true)
	if err != nil {
		return nil, err
	}
	text, err := stringArg(args, "text", true)
	if err != nil {
		return nil, err
	}
	pid, err := c.sessionInScope(g, sid)
	if err != nil {
		return nil, err
	}
	if err := c.limits.admitPrompt(g.ID, len(text)); err != nil {
		return nil, err
	}
	release, err := c.limits.startTurn(sid)
	if err != nil {
		return nil, err
	}
	gw, err := c.gateway()
	if err != nil {
		release()
		return nil, err
	}
	turn, err := gw.StartPrompt(context.Background(), g.ID, sid, text)
	if err != nil {
		release()
		return nil, err
	}
	// The audit names the source and the grant, never the text (C7).
	c.audit.Log("connector_prompt", audit.Fields{Source: "claude", Grant: g.ID, Project: pid})
	rec := c.turns.add(g.ID, sid, turn)
	rec.release = release
	go func() {
		<-turn.Done()
		release()
		c.turns.markFinished(rec.id)
	}()
	return c.waitTurn(rec)
}

// getTurn answers the state of a turn the grant started, waiting up to sendPromptWaitSeconds while
// it still runs.
func (c *Connector) getTurn(g *Grant, args map[string]json.RawMessage) (any, error) {
	id, err := stringArg(args, "turnId", true)
	if err != nil {
		return nil, err
	}
	rec := c.turns.lookup(g.ID, id)
	if rec == nil {
		return nil, errors.New("turnId is not a turn of this grant")
	}
	return c.waitTurn(rec)
}

// waitTurn waits for a turn up to sendPromptWaitSeconds. It answers the done shape when the turn has
// ended, or the running shape with the turn id when it has not.
func (c *Connector) waitTurn(rec *turnRecord) (any, error) {
	timer := time.NewTimer(time.Duration(c.cfg.Limits.SendPromptWaitSeconds) * time.Second)
	defer timer.Stop()
	select {
	case <-rec.turn.Done():
		rec.release() // the slot is free before the caller can send the next prompt
		return c.doneShape(rec)
	case <-timer.C:
		return map[string]any{"status": "running", "turnId": rec.id}, nil
	}
}

// doneShape is { status: "done", stopReason, reply, truncated?, context } (C7).
func (c *Connector) doneShape(rec *turnRecord) (any, error) {
	out := rec.turn.Outcome()
	if out.Err != "" {
		return nil, errors.New("the turn did not run: " + out.Err)
	}
	reply, truncated := capReply(out.Reply, c.cfg.Limits.MaxResultChars)
	res := map[string]any{"status": "done", "stopReason": out.StopReason, "reply": reply}
	if truncated {
		res["truncated"] = true
	}
	if ctx, err := c.contextFor(rec.sessionID); err == nil {
		res["context"] = ctx
	}
	return res, nil
}

// capReply cuts a reply to max characters (runes), so a multi-byte character is never split.
func capReply(text string, max int64) (string, bool) {
	if int64(utf8.RuneCountInString(text)) <= max {
		return text, false
	}
	cut := 0
	for i := range text {
		if int64(cut) == max {
			return text[:i], true
		}
		cut++
	}
	return text, false
}

// clip shortens a string to n characters, ending in "..." when it is cut.
func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	if n <= 3 {
		return string([]rune(s)[:max(n, 0)])
	}
	return string([]rune(s)[:n-3]) + "..."
}
