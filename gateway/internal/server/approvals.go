package server

// The approval queue (FR-22, NFR-10, PLAN 3.9, D-009, D-031).
//
// Every session/request_permission from an agent becomes an approval with a gateway id
// (acpcode-perm-<n>). The phones answer it, with `_acpcode/approvals/answer` or with a plain
// JSON-RPC response to that id. The first answer goes to the agent; later ones are told it was
// answered elsewhere. With no answer within limits.approvalTimeoutSeconds, the gateway sends a
// reject option, or `cancelled` when the request offers none. No path here sends an allow option
// on its own (D-009): the only answers the gateway writes itself are rejectOutcome and cancelled.

import (
	"context"
	"sort"
	"strconv"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/push"
	"acpcode/gateway/internal/store"
)

const rpcAnsweredElsewhere = -32001

type permission struct {
	id       string
	agent    *projectAgent
	proc     *agentProcess
	agentID  *jsonv.Value
	session  string
	toolCall *jsonv.Value
	options  *jsonv.Value
	since    string
	timer    *time.Timer
}

// initApprovals runs at startup: approvals from before the restart can no longer be answered,
// because their agent has gone, and new ids continue after the highest one used.
func (s *Server) initApprovals() {
	ctx := context.Background()
	if n, err := s.store.CloseOpenApprovals(ctx, "gateway_restart"); err != nil {
		s.audit.Log("store_error", audit.Fields{Reason: "close_approvals"})
	} else if n > 0 {
		s.audit.Log("approvals_closed", audit.Fields{Reason: "gateway_restart"})
	}
	if n, err := s.store.MaxApprovalSeq(ctx); err == nil {
		s.permSeq = n
	}
}

func (s *Server) approvalTimeout() time.Duration {
	return time.Duration(s.cfg.Limits.ApprovalTimeoutSeconds) * time.Second
}

// addPermission opens an approval for an agent request and starts its timeout.
func (s *Server) addPermission(a *projectAgent, proc *agentProcess, agentID *jsonv.Value, sessionID string, params *jsonv.Value) string {
	p := &permission{
		agent: a, proc: proc, agentID: agentID, session: sessionID,
		toolCall: params.Get("toolCall"), options: params.Get("options"),
		since: time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
	}
	s.permMu.Lock()
	s.permSeq++
	p.id = "acpcode-perm-" + strconv.FormatInt(s.permSeq, 10)
	s.perms[p.id] = p
	p.timer = time.AfterFunc(s.approvalTimeout(), func() { s.timeoutPermission(p.id) })
	s.permMu.Unlock()

	err := s.store.InsertApproval(context.Background(), store.Approval{
		ID: p.id, SessionID: sessionID, AgentRequestID: string(agentID.Marshal()),
		ToolCall: string(orNull(p.toolCall).Marshal()), Options: string(orNull(p.options).Marshal()), Since: p.since,
	})
	if err != nil {
		s.audit.Log("store_error", a.fields(audit.Fields{Reason: "insert_approval"}))
	}
	s.pushNotify(push.ApprovalNeeded, a.id, sessionID)
	return p.id
}

func orNull(v *jsonv.Value) *jsonv.Value {
	if v == nil {
		return &jsonv.Value{Kind: jsonv.Null}
	}
	return v
}

// takePermission removes an open approval and stops its timer. Exactly one caller gets it: this is
// where the first answer wins. Until finish has recorded it, closing says who took it, so a losing
// answer is told why at once.
func (s *Server) takePermission(id, by string) *permission {
	s.permMu.Lock()
	defer s.permMu.Unlock()
	p := s.perms[id]
	if p == nil {
		return nil
	}
	delete(s.perms, id)
	s.closing[id] = by
	p.timer.Stop()
	return p
}

// resolve sends the agent its answer, then records who answered and logs `approval_answered` for
// the session, so subscribers can close the request. reply is the whole JSON-RPC response with the
// gateway id; it is rewritten to the agent's id.
func (s *Server) resolve(p *permission, reply *jsonv.Value, by string) {
	reply.Obj["id"] = p.agentID
	_, _ = p.agent.write(p.proc, append(reply.Marshal(), '\n'))
	outcome := reply.Get("result").Get("outcome")
	s.finish(p, by, outcome)
}

// finish records a closed approval. outcome is nil when the agent got no answer (it exited).
func (s *Server) finish(p *permission, by string, outcome *jsonv.Value) {
	if err := s.store.AnswerApproval(context.Background(), p.id, by, string(orNull(outcome).Marshal())); err != nil {
		s.audit.Log("store_error", p.agent.fields(audit.Fields{Reason: "answer_approval"}))
	} else {
		s.permMu.Lock()
		delete(s.closing, p.id)
		s.permMu.Unlock()
	}
	s.audit.Log("approval_answered", p.agent.fields(audit.Fields{Reason: by}))
	if p.session == "" {
		return
	}
	fields := map[string]*jsonv.Value{"approvalId": jsonv.Str(p.id), "answeredBy": jsonv.Str(by), "outcome": orNull(outcome)}
	s.emit(p.agent.id, p.session, "approval_answered",
		gatewayNotification("_acpcode/approval_answered", p.session, fields, "approvalId", "answeredBy", "outcome"), nil)
}

func outcomeResponse(id string, outcome *jsonv.Value) *jsonv.Value {
	result := jsonv.Obj()
	result.Set("outcome", outcome)
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("id", jsonv.Str(id))
	msg.Set("result", result)
	return msg
}

func selected(optionID string) *jsonv.Value {
	o := jsonv.Obj()
	o.Set("outcome", jsonv.Str("selected"))
	o.Set("optionId", jsonv.Str(optionID))
	return o
}

func cancelled() *jsonv.Value {
	o := jsonv.Obj()
	o.Set("outcome", jsonv.Str("cancelled"))
	return o
}

// rejectOutcome is the gateway's own answer: the first reject_once option, else the first
// reject_always option, else cancelled. It never returns an allow option (D-009).
func rejectOutcome(options *jsonv.Value) *jsonv.Value {
	for _, want := range []string{"reject_once", "reject_always"} {
		if options == nil || options.Kind != jsonv.Array {
			break
		}
		for _, o := range options.Arr {
			kind, _ := o.Get("kind").StringValue()
			id, ok := o.Get("optionId").StringValue()
			if kind == want && ok && id != "" {
				return selected(id)
			}
		}
	}
	return cancelled()
}

func (s *Server) timeoutPermission(id string) {
	p := s.takePermission(id, "timeout")
	if p == nil {
		return // answered first
	}
	s.resolve(p, outcomeResponse(id, rejectOutcome(p.options)), "timeout")
}

// cancelPermissions answers a session's open approvals with cancelled after the phone sent
// session/cancel, as ACP asks of the client.
func (s *Server) cancelPermissions(a *projectAgent, sessionID string) {
	s.permMu.Lock()
	var ids []string
	for id, p := range s.perms {
		if p.agent == a && p.session == sessionID {
			ids = append(ids, id)
		}
	}
	s.permMu.Unlock()
	for _, id := range ids {
		if p := s.takePermission(id, "cancel"); p != nil {
			s.resolve(p, outcomeResponse(id, cancelled()), "cancel")
		}
	}
}

// dropPermissions closes the approvals of an agent process that exited.
func (s *Server) dropPermissions(proc *agentProcess) {
	s.permMu.Lock()
	var dropped []*permission
	for id, p := range s.perms {
		if p.proc == proc {
			delete(s.perms, id)
			s.closing[id] = "agent_exit"
			p.timer.Stop()
			dropped = append(dropped, p)
		}
	}
	s.permMu.Unlock()
	for _, p := range dropped {
		s.finish(p, "agent_exit", nil)
	}
}

// closedReason says why an approval can no longer be answered: "answered elsewhere" when a phone
// answered it, or what else closed it.
func (s *Server) closedReason(ctx context.Context, id string) (string, bool) {
	s.permMu.Lock()
	by, ok := s.closing[id]
	s.permMu.Unlock()
	if !ok {
		a, err := s.store.ApprovalByID(ctx, id)
		if err != nil || a == nil || a.AnsweredBy == "" {
			return "", false
		}
		by = a.AnsweredBy
	}
	switch by {
	case "timeout":
		return "timed out", true
	case "cancel":
		return "cancelled", true
	case "agent_exit", "gateway_restart":
		return "the agent exited", true
	}
	return "answered elsewhere", true
}

func answeredBy(who audit.Who) string { return who.Identity + "/" + who.Device }

// answerPermission handles a plain JSON-RPC response from a phone (the current app). The first
// answer for an open approval goes to the agent as the phone sent it. A later one is dropped, and
// the phone gets `_acpcode/notice` saying why.
func (s *Server) answerPermission(c *client, msg, id *jsonv.Value) {
	key, _ := id.StringValue()
	p := s.takePermission(key, answeredBy(c.who))
	if p == nil {
		s.audit.Log("response_dropped", with(c.who, audit.Fields{}))
		if reason, ok := s.closedReason(c.ctx, key); ok {
			params := jsonv.Obj()
			params.Set("approvalId", jsonv.Str(key))
			params.Set("message", jsonv.Str(reason))
			note := jsonv.Obj()
			note.Set("jsonrpc", jsonv.Str("2.0"))
			note.Set("method", jsonv.Str("_acpcode/notice"))
			note.Set("params", params)
			c.send(note.Marshal())
		}
		return
	}
	s.audit.Log("rpc", with(c.who, audit.Fields{Dir: "in", Method: "response", Project: p.agent.id}))
	s.resolve(p, msg, answeredBy(c.who))
}

// answerApproval handles `_acpcode/approvals/answer {approvalId, optionId | cancelled: true}`.
func (s *Server) answerApproval(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	id, _ := params.Get("approvalId").StringValue()
	if id == "" {
		return nil, invalidParams("approvalId is required")
	}
	optionID, hasOption := params.Get("optionId").StringValue()
	c := params.Get("cancelled")
	isCancel := c != nil && c.Kind == jsonv.Bool && c.B
	if hasOption == isCancel || (hasOption && optionID == "") {
		return nil, invalidParams("give exactly one of optionId and cancelled: true")
	}
	s.permMu.Lock()
	open := s.perms[id]
	s.permMu.Unlock()
	if open == nil {
		if reason, ok := s.closedReason(ctx, id); ok {
			return nil, &rpcError{Code: rpcAnsweredElsewhere, Message: reason}
		}
		return nil, invalidParams("unknown approval")
	}
	outcome := cancelled()
	if hasOption {
		found := false
		if open.options != nil && open.options.Kind == jsonv.Array {
			for _, o := range open.options.Arr {
				if v, _ := o.Get("optionId").StringValue(); v == optionID {
					found = true
				}
			}
		}
		if !found {
			return nil, invalidParams("optionId is not one of the request's options")
		}
		outcome = selected(optionID)
	}
	p := s.takePermission(id, answeredBy(who))
	if p == nil { // another answer won between the check and here
		reason, _ := s.closedReason(ctx, id)
		return nil, &rpcError{Code: rpcAnsweredElsewhere, Message: reason}
	}
	s.audit.Log("rpc", with(who, audit.Fields{Dir: "in", Method: "_acpcode/approvals/answer", Project: p.agent.id}))
	s.resolve(p, outcomeResponse(id, outcome), answeredBy(who))
	return map[string]any{}, nil
}

type approvalJSON struct {
	ApprovalID string       `json:"approvalId"`
	SessionID  string       `json:"sessionId"`
	ProjectID  string       `json:"projectId"`
	ToolCall   *jsonv.Value `json:"toolCall"`
	Options    *jsonv.Value `json:"options"`
	Since      string       `json:"since"`
}

// pendingApprovals answers `_acpcode/approvals/pending`: the open approvals, oldest first.
func (s *Server) pendingApprovals() (any, *rpcError) {
	s.permMu.Lock()
	out := make([]approvalJSON, 0, len(s.perms))
	for _, p := range s.perms {
		out = append(out, approvalJSON{ApprovalID: p.id, SessionID: p.session, ProjectID: p.agent.id,
			ToolCall: orNull(p.toolCall), Options: orNull(p.options), Since: p.since})
	}
	s.permMu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].Since != out[j].Since {
			return out[i].Since < out[j].Since
		}
		return len(out[i].ApprovalID) < len(out[j].ApprovalID) || (len(out[i].ApprovalID) == len(out[j].ApprovalID) && out[i].ApprovalID < out[j].ApprovalID)
	})
	return map[string]any{"approvals": out}, nil
}
