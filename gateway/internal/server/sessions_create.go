package server

// The gateway's own _acpcode/sessions/create and _acpcode/sessions/prompt.
//
//   _acpcode/sessions/create {cwd, mcpServers?, _meta?, prompt}: creates the session as session/new
//   does, then sends the first prompt as session/prompt, in one request. The result is the
//   session/new result plus {turnId, status: "accepted"}.
//   _acpcode/sessions/prompt {sessionId, prompt}: sends a prompt to a session the gateway has
//   recorded. The result is {turnId, status: "accepted"}.
//
// Both reply once the agent has the prompt (its turn is logged, then written), never at turn end.
// A prompt while a turn is pending gets -32010 from the busy guard in forward (supervisor.go).
// The prompt is a list of ACP text blocks.
//
// Each step goes through handleMessage, as a socket's own session/new and session/prompt do, on a
// gateway client that has no socket. So every guard, the MCP bookkeeping and the session record
// stay in one place. The client's context carries an accept hook, which forward calls with the turn
// id after the prompt is written.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"sync/atomic"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

const (
	rpcBusy           = -32010 // a turn is already pending in the session
	rpcPromptTooLarge = -32012 // the prompt is over maxCreatePromptBytes: nothing started
	rpcPromptNotSent  = -32015 // the session was created, but its prompt was not accepted
)

// maxCreatePromptBytes bounds the serialized prompt of both methods. It is well below
// limits.maxMessageBytes, so an oversize prompt is refused before anything starts.
const maxCreatePromptBytes = 64 << 10

var gatewayCallSeq atomic.Int64

// acceptedKey is the context key of the accept hook that a gateway call's client carries.
type acceptedKey struct{}

// acceptFunc receives the turn id of a prompt once the agent has it.
type acceptFunc func(turnID string)

// newTurnID returns a random 128-bit turn id, in hex. It is the gateway's id, not the agent's.
func newTurnID() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // crypto/rand does not fail on the supported platforms (elicitation.go)
	return hex.EncodeToString(b[:])
}

// notifyAccepted tells a caller that its prompt reached the agent. Only a gateway call sets the hook,
// so for a socket this does nothing.
func notifyAccepted(c *client, turnID string) {
	if c.ctx == nil {
		return
	}
	if fn, ok := c.ctx.Value(acceptedKey{}).(acceptFunc); ok && fn != nil {
		fn(turnID)
	}
}

// busyError is the refusal of a prompt while a turn is pending in the session.
func busyError(sid, turnID string) *rpcError {
	return &rpcError{
		Code:    rpcBusy,
		Message: "the session is busy: a turn is already running",
		Data:    map[string]string{"sessionId": sid, "turnId": turnID},
	}
}

// promptNotSent is the error for a session that exists while its first prompt did not reach the agent.
func promptNotSent(sid string) *rpcError {
	return &rpcError{
		Code:    rpcPromptNotSent,
		Message: "the session was created, but its prompt was not accepted",
		Data:    map[string]any{"sessionId": sid, "promptSent": false},
	}
}

// parsePrompt checks an ACP prompt: a non-empty array of text blocks with some text, no larger than
// maxCreatePromptBytes once serialized.
func parsePrompt(v *jsonv.Value) *rpcError {
	if v.IsNull() || v.Kind != jsonv.Array {
		return invalidParams("prompt must be an array of content blocks")
	}
	if len(v.Arr) == 0 {
		return invalidParams("prompt is empty")
	}
	var text strings.Builder
	for _, b := range v.Arr {
		if b.IsNull() || b.Kind != jsonv.Object {
			return invalidParams("prompt blocks must be objects")
		}
		if typ, _ := b.Get("type").StringValue(); typ != "text" {
			return invalidParams("prompt blocks must be text")
		}
		t, ok := b.Get("text").StringValue()
		if !ok {
			return invalidParams("a text block needs a text string")
		}
		text.WriteString(t)
	}
	if strings.TrimSpace(text.String()) == "" {
		return invalidParams("prompt is empty")
	}
	if len(v.Marshal()) > maxCreatePromptBytes {
		return &rpcError{Code: rpcPromptTooLarge, Message: "the prompt is too large", Data: map[string]any{"maxBytes": maxCreatePromptBytes}}
	}
	return nil
}

// agentError turns an error object the agent sent into the caller's error, keeping code, message and data.
func agentError(e *jsonv.Value) *rpcError {
	code := rpcInternal
	if n, ok := e.Get("code").Int(); ok {
		code = int(n)
	}
	msg, _ := e.Get("message").StringValue()
	rerr := &rpcError{Code: code, Message: msg}
	if d := e.Get("data"); !d.IsNull() {
		rerr.Data = d
	}
	return rerr
}

// gatewayCall is a client the gateway makes to itself for one phone request. Its updates reach the
// event log through the normal path; the call keeps only the answers to its own requests.
type gatewayCall struct {
	s        *Server
	c        *client
	answers  chan *jsonv.Value // answers from the client's queue
	done     chan struct{}
	accepted string // the turn id of the last prompt the agent accepted; set on the calling goroutine
}

func (s *Server) newGatewayCall(who audit.Who) *gatewayCall {
	gc := &gatewayCall{s: s, answers: make(chan *jsonv.Value, 4), done: make(chan struct{})}
	ctx := context.WithValue(s.pushCtx, acceptedKey{}, acceptFunc(func(turnID string) { gc.accepted = turnID }))
	gc.c = &client{
		who:     who,
		ctx:     ctx,
		out:     make(chan []byte, clientQueueMessages),
		done:    make(chan struct{}),
		drained: make(chan struct{}, 1),
		limit:   2*s.cfg.Limits.MaxMessageBytes + 1<<20,
	}
	go gc.pump()
	return gc
}

// pump drains the client's queue until the call finishes, so the queue never fills and closes the
// client as a slow phone.
func (gc *gatewayCall) pump() {
	for {
		select {
		case b := <-gc.c.out:
			gc.c.queued.Add(-int64(len(b)))
			gc.observe(b)
		case <-gc.done:
			return
		}
	}
}

// observe keeps the answers to requests. Updates and notifications are dropped: the event log has them.
func (gc *gatewayCall) observe(b []byte) {
	msg, err := jsonv.Parse(b)
	if err != nil {
		return
	}
	if _, isNotification := msg.Get("method").StringValue(); isNotification {
		return
	}
	select {
	case gc.answers <- msg:
	default:
	}
}

// send hands one request to the gateway's own handler. It returns the refusal, or nil when the request
// went on to the agent path, whose answer then arrives through the queue. handleMessage answers a
// refusal before it returns, so the refusal is known when send returns.
func (gc *gatewayCall) send(method, id string, params *jsonv.Value) *rpcError {
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("id", jsonv.Str(id))
	msg.Set("method", jsonv.Str(method))
	msg.Set("params", params)
	var refusal *rpcError
	reply := func(_ *jsonv.Value, _ any, rerr *rpcError) { refusal = rerr }
	gc.s.handleMessage(gc.c.ctx, gc.c, websocket.MessageText, msg.Marshal(), reply)
	return refusal
}

// await waits for the answer to the request with this id.
func (gc *gatewayCall) await(id string) (*jsonv.Value, *rpcError) {
	for {
		select {
		case msg := <-gc.answers:
			if got, _ := msg.Get("id").StringValue(); got == id {
				return msg, nil
			}
		case <-gc.c.ctx.Done():
			return nil, &rpcError{Code: rpcAgentUnavailable, Message: "cancelled"}
		}
	}
}

// prompt sends a session/prompt through the call. It returns the turn id once the agent has the prompt.
// Otherwise it returns "" with the refusal (busy, agent unavailable, and the like), or with no refusal
// when the prompt was not written.
func (gc *gatewayCall) prompt(id string, sid string, prompt *jsonv.Value) (string, *rpcError) {
	params := jsonv.Obj()
	params.Set("sessionId", jsonv.Str(sid))
	params.Set("prompt", prompt)
	gc.accepted = ""
	if rerr := gc.send("session/prompt", id, params); rerr != nil {
		return "", rerr
	}
	return gc.accepted, nil
}

// finish ends the call: nothing more is queued to its client, and it leaves every session it joined.
// The turn itself goes on; its answer is logged by the agent path and dropped here.
func (gc *gatewayCall) finish() {
	gc.c.closing.Store(true)
	close(gc.done)
	gc.s.mu.Lock()
	agents := make([]*projectAgent, 0, len(gc.s.agents))
	for _, a := range gc.s.agents {
		agents = append(agents, a)
	}
	gc.s.mu.Unlock()
	for _, a := range agents {
		a.detach(gc.c)
	}
}

// recoverCall answers a panic in a create or prompt call with -32603, as the git and stop calls do.
func (s *Server) recoverCall(who audit.Who, method string, id *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	if r := recover(); r != nil {
		s.audit.Log("panic", with(who, audit.Fields{Method: method, Reason: fmt.Sprintf("%T", r)}))
		reply(id, nil, &rpcError{Code: rpcInternal, Message: "internal error"})
	}
}

// serveCreate answers _acpcode/sessions/create. It runs in its own goroutine, because the agent may take
// a while to start.
func (s *Server) serveCreate(who audit.Who, id, params *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	const method = "_acpcode/sessions/create"
	defer s.recoverCall(who, method, id, reply)
	cwd, ok := params.Get("cwd").StringValue()
	if !ok || cwd == "" {
		reply(id, nil, invalidParams("cwd is required"))
		return
	}
	if rerr := parsePrompt(params.Get("prompt")); rerr != nil {
		reply(id, nil, rerr)
		return
	}
	project, err := s.projectForCwd(s.pushCtx, cwd)
	if err != nil {
		reply(id, nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"})
		return
	}
	if project == nil {
		reply(id, nil, invalidParams("cwd is not inside a registered project"))
		return
	}

	gc := s.newGatewayCall(who)
	defer gc.finish()

	newParams := jsonv.Obj()
	newParams.Set("cwd", jsonv.Str(cwd))
	for _, k := range []string{"mcpServers", "_meta"} {
		if v := params.Get(k); !v.IsNull() {
			newParams.Set(k, v)
		}
	}
	seq := gatewayCallSeq.Add(1)
	newID := fmt.Sprintf("acpcode-new-%d", seq)
	if rerr := gc.send("session/new", newID, newParams); rerr != nil {
		reply(id, nil, rerr) // refused before a session existed: nothing to undo
		return
	}
	ans, rerr := gc.await(newID)
	if rerr != nil {
		reply(id, nil, rerr)
		return
	}
	if e := ans.Get("error"); !e.IsNull() {
		reply(id, nil, agentError(e))
		return
	}
	result := ans.Get("result")
	if result.IsNull() || result.Kind != jsonv.Object {
		reply(id, nil, &rpcError{Code: rpcInternal, Message: "the agent gave no session"})
		return
	}
	sid, ok := result.Get("sessionId").StringValue()
	if !ok || sid == "" {
		reply(id, nil, &rpcError{Code: rpcInternal, Message: "the agent gave no session"})
		return
	}

	turnID, _ := gc.prompt(fmt.Sprintf("acpcode-prompt-%d", gatewayCallSeq.Add(1)), sid, params.Get("prompt"))
	if turnID == "" {
		reply(id, nil, promptNotSent(sid)) // refused or not written: the session exists, the prompt does not
		return
	}
	out := copyResult(result, "")
	out.Set("turnId", jsonv.Str(turnID))
	out.Set("status", jsonv.Str("accepted"))
	reply(id, out, nil)
}

// servePrompt answers _acpcode/sessions/prompt.
func (s *Server) servePrompt(who audit.Who, id, params *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	const method = "_acpcode/sessions/prompt"
	defer s.recoverCall(who, method, id, reply)
	sid, ok := params.Get("sessionId").StringValue()
	if !ok || sid == "" {
		reply(id, nil, invalidParams("sessionId is required"))
		return
	}
	if rerr := parsePrompt(params.Get("prompt")); rerr != nil {
		reply(id, nil, rerr)
		return
	}
	pid, err := s.store.SessionProject(s.pushCtx, sid)
	if err != nil {
		reply(id, nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"})
		return
	}
	if pid == "" {
		reply(id, nil, &rpcError{Code: rpcInvalidParams, Message: "unknown session", Data: map[string]string{"reason": "unknown_session"}})
		return
	}

	gc := s.newGatewayCall(who)
	defer gc.finish()
	turnID, rerr := gc.prompt(fmt.Sprintf("acpcode-prompt-%d", gatewayCallSeq.Add(1)), sid, params.Get("prompt"))
	if rerr != nil {
		reply(id, nil, rerr) // busy (-32010), or the agent path's refusal
		return
	}
	if turnID == "" {
		// Not refused, but not written either: nothing reached the agent, so a retry is safe.
		reply(id, nil, &rpcError{Code: rpcAgentUnavailable, Message: "agent unavailable: the prompt was not sent"})
		return
	}
	out := jsonv.Obj()
	out.Set("turnId", jsonv.Str(turnID))
	out.Set("status", jsonv.Str("accepted"))
	reply(id, out, nil)
}
