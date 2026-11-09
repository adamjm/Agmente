package server

// The connector's bridge to the gateway (D-096). The connector tools read sessions through it, and
// send a prompt through the phone's own session/prompt path (handleMessage), as the source "claude"
// for one grant. Nothing here changes how the phone's prompts run.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/connector"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// connectorSource is the source a connector prompt is audited under (C7).
const connectorSource = "claude"

// maxConnectorReply bounds the agent text one connector turn keeps. The tools cut the reply to
// maxResultChars anyway; this only bounds memory.
const maxConnectorReply = 1 << 20

var connectorRequestSeq atomic.Int64

// connectorBridge implements connector.Gateway for one server.
type connectorBridge struct{ s *Server }

// Projects lists the registered projects, with the folder's basename and never the full path.
func (b *connectorBridge) Projects(ctx context.Context) ([]connector.ProjectInfo, error) {
	ps, err := b.s.store.Projects(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]connector.ProjectInfo, 0, len(ps))
	for _, p := range ps {
		out = append(out, connector.ProjectInfo{ID: p.ID, Name: p.Name, Folder: folderName(p.Path)})
	}
	return out, nil
}

// Sessions lists the recorded sessions with their status: a turn running or a permission waiting
// overrides the stored status, as the phone's index does.
func (b *connectorBridge) Sessions(ctx context.Context, projectID string) ([]connector.SessionInfo, error) {
	rows, err := b.s.store.SessionIndex(ctx, "", projectID)
	if err != nil {
		return nil, err
	}
	running, awaiting := b.s.liveStatus()
	out := make([]connector.SessionInfo, 0, len(rows))
	for _, r := range rows {
		out = append(out, connector.SessionInfo{
			ID: r.SessionID, ProjectID: r.ProjectID, Title: r.Title,
			Status: sessionStatus(r.Status, r.SessionID, running, awaiting), Usage: connectorUsage(r.Usage),
		})
	}
	return out, nil
}

// Facts reads what get_context summarises about one session. It starts no agent.
func (b *connectorBridge) Facts(ctx context.Context, sid string) (connector.SessionFacts, error) {
	s := b.s
	var f connector.SessionFacts
	pid, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return f, err
	}
	if pid == "" {
		return f, errors.New("unknown session")
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil {
		return f, err
	}
	if p == nil {
		return f, errors.New("unknown project")
	}
	rows, err := s.store.SessionIndex(ctx, "", pid)
	if err != nil {
		return f, err
	}
	var row *store.SessionRow
	for i := range rows {
		if rows[i].SessionID == sid {
			row = &rows[i]
			break
		}
	}
	if row == nil {
		return f, errors.New("unknown session")
	}
	running, awaiting := s.liveStatus()
	f.ProjectName, f.ProjectFolder = p.Name, folderName(p.Path)
	f.Title = row.Title
	f.Status = sessionStatus(row.Status, sid, running, awaiting)
	f.Usage = connectorUsage(row.Usage)
	f.PendingApprovals = s.connectorPendingApprovals(sid)
	if f.Status == "running" || f.Status == "awaiting_approval" {
		if f.RunningTools, err = b.runningTools(ctx, sid); err != nil {
			return f, err
		}
	}
	if f.StopReason, err = b.stopReason(ctx, sid); err != nil {
		return f, err
	}
	f.AlwaysAllow = s.sessionAlwaysAllow(pid, sid)
	return f, nil
}

// StartPrompt sends a prompt through the phone's session/prompt path. The request is a JSON-RPC
// message on a client that is not a socket: its answers and updates come to the turn, and the
// connector's own audit fields (source "claude", the grant id) ride on every line the turn writes.
func (b *connectorBridge) StartPrompt(ctx context.Context, grantID, sid, text string) (connector.PromptTurn, error) {
	s := b.s
	pid, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return nil, errors.New("cannot read sessions")
	}
	if pid == "" {
		return nil, errors.New("unknown session")
	}
	reqID := fmt.Sprintf("connector-%d", connectorRequestSeq.Add(1))
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      reqID,
		"method":  "session/prompt",
		"params": map[string]any{
			"sessionId": sid,
			"prompt":    []map[string]string{{"type": "text", "text": text}},
		},
	})
	if err != nil {
		return nil, err
	}
	t := &connectorTurn{s: s, pid: pid, sid: sid, reqID: reqID, done: make(chan struct{})}
	t.c = &client{
		who:     audit.Who{Source: connectorSource, Grant: grantID, Scope: config.ScopeConnector},
		ctx:     s.pushCtx,
		out:     make(chan []byte, clientQueueMessages),
		done:    make(chan struct{}),
		drained: make(chan struct{}, 1),
		limit:   2*s.cfg.Limits.MaxMessageBytes + 1<<20,
	}
	go t.collect()
	reply := func(_ *jsonv.Value, _ any, rerr *rpcError) {
		if rerr != nil {
			t.finish(connector.PromptOutcome{Err: rerr.Message}) // refused before it reached the agent
		}
	}
	go s.handleMessage(s.pushCtx, t.c, websocket.MessageText, body, reply)
	return t, nil
}

// connectorTurn is one connector prompt. Its client receives the turn's updates and the agent's
// answer; the collector reads them until the answer comes, then the client is detached and closed.
type connectorTurn struct {
	s     *Server
	c     *client
	pid   string
	sid   string
	reqID string
	done  chan struct{}
	once  sync.Once

	mu    sync.Mutex
	reply strings.Builder         // the agent's text for the turn; guarded by mu
	out   connector.PromptOutcome // set once, before done closes; guarded by mu
}

func (t *connectorTurn) Done() <-chan struct{} { return t.done }

func (t *connectorTurn) Outcome() connector.PromptOutcome {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.out
}

// collect reads what the turn's client is sent until the turn is finished.
func (t *connectorTurn) collect() {
	for {
		select {
		case b := <-t.c.out:
			t.c.queued.Add(-int64(len(b)))
			t.observe(b)
		case <-t.done:
			return
		}
	}
}

// observe reads one message. An agent update for the session adds to the reply; the answer to the
// prompt finishes the turn.
func (t *connectorTurn) observe(b []byte) {
	msg, err := jsonv.Parse(b)
	if err != nil {
		return
	}
	if method, ok := msg.Get("method").StringValue(); ok {
		if method == "session/update" {
			t.noteUpdate(msg.Get("params"))
		}
		return
	}
	if id, ok := msg.Get("id").StringValue(); !ok || id != t.reqID {
		return
	}
	if !msg.Get("error").IsNull() {
		t.finish(connector.PromptOutcome{StopReason: "error"})
		return
	}
	stop, _ := msg.Get("result").Get("stopReason").StringValue()
	t.finish(connector.PromptOutcome{StopReason: stop})
}

// noteUpdate keeps the agent's message text for the session (never its thoughts or tool output).
func (t *connectorTurn) noteUpdate(params *jsonv.Value) {
	if sid, _ := params.Get("sessionId").StringValue(); sid != t.sid {
		return
	}
	u := params.Get("update")
	if kind, _ := u.Get("sessionUpdate").StringValue(); kind != "agent_message_chunk" {
		return
	}
	if typ, _ := u.Get("content").Get("type").StringValue(); typ != "text" {
		return
	}
	text, _ := u.Get("content").Get("text").StringValue()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.reply.Len()+len(text) <= maxConnectorReply {
		t.reply.WriteString(text)
	}
}

// finish ends the turn once: it takes the reply, detaches the turn's client from the session, and
// closes the client so nothing more is queued to it.
func (t *connectorTurn) finish(out connector.PromptOutcome) {
	t.once.Do(func() {
		t.mu.Lock()
		out.Reply = t.reply.String()
		t.out = out
		t.mu.Unlock()
		t.s.mu.Lock()
		a := t.s.agents[t.pid]
		t.s.mu.Unlock()
		if a != nil {
			a.detach(t.c)
		}
		t.c.closing.Store(true)
		close(t.done)
	})
}

// runningTools returns the titles of the tool calls of the session's current turn that have no
// terminal update yet, oldest first (C3). The turn starts at its last turn_started event.
func (b *connectorBridge) runningTools(ctx context.Context, sid string) ([]string, error) {
	st := b.s.store
	var from int64
	if ev, ok, err := st.LatestEvent(ctx, sid, "turn_started"); err != nil {
		return nil, err
	} else if ok {
		from = ev.Seq
	}
	head, err := st.HeadSeq(ctx, sid)
	if err != nil {
		return nil, err
	}
	titles := map[string]string{}
	var order []string
	err = st.EventsAfter(ctx, sid, from, head, func(e store.Event) error {
		if e.Kind != "update" {
			return nil
		}
		msg, err := jsonv.Parse([]byte(e.Message))
		if err != nil {
			return nil
		}
		u := msg.Get("params").Get("update")
		id, ok := u.Get("toolCallId").StringValue()
		if !ok || id == "" {
			return nil
		}
		switch kind, _ := u.Get("sessionUpdate").StringValue(); kind {
		case "tool_call":
			if _, running := titles[id]; !running {
				order = append(order, id)
			}
			titles[id], _ = u.Get("title").StringValue()
		case "tool_call_update":
			if status, _ := u.Get("status").StringValue(); status == "completed" || status == "failed" {
				delete(titles, id)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	out := []string{}
	seen := map[string]bool{}
	for _, id := range order {
		if t, running := titles[id]; running && !seen[id] {
			seen[id] = true
			out = append(out, t)
		}
	}
	return out, nil
}

// stopReason is the last turn's stop reason from its turn_ended event, or "" when there is none.
func (b *connectorBridge) stopReason(ctx context.Context, sid string) (string, error) {
	ev, ok, err := b.s.store.LatestEvent(ctx, sid, "turn_ended")
	if err != nil || !ok {
		return "", err
	}
	msg, err := jsonv.Parse([]byte(ev.Message))
	if err != nil {
		return "", nil
	}
	params := msg.Get("params")
	if r, ok := params.Get("stopReason").StringValue(); ok && r != "" {
		return r, nil
	}
	if !params.Get("error").IsNull() {
		return "error", nil
	}
	return "", nil
}

// sessionAlwaysAllow reports whether the session's MCP list has an alwaysAllow entry (D-089). It is
// nil when the gateway holds no list for the session (none sent since the gateway started).
func (s *Server) sessionAlwaysAllow(pid, sid string) *bool {
	s.mu.Lock()
	a := s.agents[pid]
	s.mu.Unlock()
	if a == nil {
		return nil
	}
	a.mu.Lock()
	list := a.mcp[sid]
	a.mu.Unlock()
	if list == nil {
		return nil
	}
	found := false
	for _, entry := range list.Arr {
		if aa := entry.Get("alwaysAllow"); aa != nil && aa.Kind == jsonv.Array && len(aa.Arr) > 0 {
			found = true
			break
		}
	}
	return &found
}

// connectorPendingApprovals counts the permission requests waiting for a phone's answer in one session.
func (s *Server) connectorPendingApprovals(sid string) int {
	s.permMu.Lock()
	defer s.permMu.Unlock()
	n := 0
	for _, p := range s.perms {
		if p.session == sid {
			n++
		}
	}
	return n
}

// sessionStatus is the status the phone's index shows: awaiting_approval or running override the
// stored status while the gateway holds them.
func sessionStatus(stored, sid string, running, awaiting map[string]bool) string {
	switch {
	case awaiting[sid]:
		return "awaiting_approval"
	case running[sid]:
		return "running"
	}
	return stored
}

func connectorUsage(u *store.Usage) *connector.Usage {
	if u == nil {
		return nil
	}
	return &connector.Usage{Used: u.Used, Size: u.Size, CostAmount: u.CostAmount, CostCurrency: u.CostCurrency, UpdatedAt: u.Updated}
}

// folderName is the last element of a project's path: the folder's name, not the path.
func folderName(path string) string {
	if path == "" {
		return ""
	}
	return filepath.Base(path)
}
