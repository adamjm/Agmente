package server

// Elicitation relay (FR-44, PLAN 6C.2, D-026, D-031). An agent's elicitation/create asks for a form.
// The gateway sends it to the session's subscribers under a gateway id (agmente-elic-<hex>), as a
// `_agmente/event`. A phone answers with `_agmente/elicitation/answer`. The first answer goes to the
// agent under the agent's own id; a later one gets -32001. With no answer within
// limits.approvalTimeoutSeconds, the gateway sends {action: "decline"}, never accept and never
// content. The gateway never answers an elicitation on its own otherwise.
//
// The phone's answer is checked before it goes anywhere (parseElicitationAnswer). Content values are
// never logged: the audit has the action only (FR-9).

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
)

const elicitationPrefix = "agmente-elic-"

type elicitation struct {
	id       string
	agent    *projectAgent
	proc     *agentProcess
	agentID  *jsonv.Value
	session  string
	timer    *time.Timer
	closedBy string // "" while open; else who closed it: a device, "timeout" or "agent_exit"
}

// newElicitationID is random, so an id from before a restart cannot match a new elicitation.
// crypto/rand.Read does not fail on the platforms the gateway runs on, so its error is not read.
func newElicitationID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return elicitationPrefix + hex.EncodeToString(b[:])
}

// addElicitation holds an agent request and starts its timeout.
func (s *Server) addElicitation(a *projectAgent, proc *agentProcess, agentID *jsonv.Value, sessionID string) string {
	e := &elicitation{agent: a, proc: proc, agentID: agentID, session: sessionID}
	s.permMu.Lock()
	defer s.permMu.Unlock()
	e.id = newElicitationID()
	s.elics[e.id] = e
	e.timer = time.AfterFunc(s.approvalTimeout(), func() { s.timeoutElicitation(e.id) })
	return e.id
}

// takeElicitation closes an open elicitation and stops its timer. Exactly one caller gets it.
func (s *Server) takeElicitation(id, by string) *elicitation {
	s.permMu.Lock()
	defer s.permMu.Unlock()
	e := s.elics[id]
	if e == nil || e.closedBy != "" {
		return nil
	}
	e.closedBy = by
	e.timer.Stop()
	return e
}

// resolveElicitation sends the agent its answer and records the close for subscribers. The content
// is sent only with accept; it is never logged.
func (s *Server) resolveElicitation(e *elicitation, action string, content *jsonv.Value, by string) {
	result := jsonv.Obj()
	result.Set("action", jsonv.Str(action))
	if content != nil {
		result.Set("content", content)
	}
	reply := jsonv.Obj()
	reply.Set("jsonrpc", jsonv.Str("2.0"))
	reply.Set("id", e.agentID)
	reply.Set("result", result)
	_, _ = e.agent.write(e.proc, append(reply.Marshal(), '\n'))
	s.audit.Log("elicitation_answered", e.agent.fields(audit.Fields{Reason: action}))
	if e.session == "" {
		return
	}
	fields := map[string]*jsonv.Value{"elicitationId": jsonv.Str(e.id), "answeredBy": jsonv.Str(by), "action": jsonv.Str(action)}
	s.emit(e.agent.id, e.session, "elicitation_answered",
		gatewayNotification("_agmente/elicitation_answered", e.session, fields, "elicitationId", "answeredBy", "action"), nil)
}

func (s *Server) timeoutElicitation(id string) {
	e := s.takeElicitation(id, "timeout")
	if e == nil {
		return // answered first
	}
	s.resolveElicitation(e, "decline", nil, "timeout")
}

// dropElicitations closes the open elicitations of an agent process that exited. Nothing is sent:
// the agent is gone. A late answer then gets -32001 "the agent exited".
func (s *Server) dropElicitations(proc *agentProcess) {
	var dropped []*elicitation
	s.permMu.Lock()
	for _, e := range s.elics {
		if e.proc == proc && e.closedBy == "" {
			e.closedBy = "agent_exit"
			e.timer.Stop()
			dropped = append(dropped, e)
		}
	}
	s.permMu.Unlock()
	for _, e := range dropped {
		fields := map[string]*jsonv.Value{"elicitationId": jsonv.Str(e.id), "answeredBy": jsonv.Str("agent_exit"), "action": orNull(nil)}
		if e.session != "" {
			s.emit(e.agent.id, e.session, "elicitation_answered",
				gatewayNotification("_agmente/elicitation_answered", e.session, fields, "elicitationId", "answeredBy", "action"), nil)
		}
	}
}

func elicitationClosedReason(by string) string {
	switch by {
	case "timeout":
		return "timed out"
	case "agent_exit":
		return "the agent exited"
	}
	return "answered elsewhere"
}

// elicitationRequest handles an agent's elicitation/create. Only form mode is offered (the
// capability says so in initialize), so any other mode is refused to the agent with -32602.
func (a *projectAgent) elicitationRequest(proc *agentProcess, msg *jsonv.Value, id *jsonv.Value) {
	params := msg.Get("params")
	sid, _ := params.Get("sessionId").StringValue()
	mode, _ := params.Get("mode").StringValue()
	schema := params.Get("requestedSchema")
	var refusal *rpcError
	switch {
	case sid == "":
		refusal = invalidParams("sessionId is required")
	case mode != "form":
		refusal = invalidParams("only form mode is supported")
	case schema == nil || schema.Kind != jsonv.Object:
		refusal = invalidParams("requestedSchema must be an object")
	}
	if refusal != nil {
		_, _ = a.write(proc, append(rpcErrorResponse(id, refusal), '\n'))
		return
	}
	gwID := a.s.addElicitation(a, proc, id, sid)
	msg.Obj["id"] = jsonv.Str(gwID)
	a.s.emit(a.id, sid, "elicitation_request", msg.Marshal(), nil)
}

// parseElicitationAnswer checks `_agmente/elicitation/answer {action, content?}`. The action must be
// accept, decline or cancel. content, when present, must be an object whose values are strings,
// numbers, booleans or arrays of strings. Content is returned only for accept.
func parseElicitationAnswer(params *jsonv.Value) (string, *jsonv.Value, *rpcError) {
	action, _ := params.Get("action").StringValue()
	switch action {
	case "accept", "decline", "cancel":
	default:
		return "", nil, invalidParams("action must be accept, decline or cancel")
	}
	content := params.Get("content")
	if content == nil {
		return action, nil, nil
	}
	if content.Kind != jsonv.Object {
		return "", nil, invalidParams("content must be an object")
	}
	for _, k := range content.Keys {
		if !validElicitationValue(content.Obj[k]) {
			return "", nil, invalidParams("content values must be strings, numbers, booleans or arrays of strings")
		}
	}
	if action != "accept" {
		return action, nil, nil
	}
	return action, content, nil
}

func validElicitationValue(v *jsonv.Value) bool {
	if v == nil {
		return false
	}
	switch v.Kind {
	case jsonv.String, jsonv.Number, jsonv.Bool:
		return true
	case jsonv.Array:
		for _, x := range v.Arr {
			if x == nil || x.Kind != jsonv.String {
				return false
			}
		}
		return true
	}
	return false
}

// answerElicitation handles `_agmente/elicitation/answer`.
func (s *Server) answerElicitation(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	id, _ := params.Get("elicitationId").StringValue()
	if id == "" {
		return nil, invalidParams("elicitationId is required")
	}
	action, content, rerr := parseElicitationAnswer(params)
	if rerr != nil {
		return nil, rerr
	}
	e := s.takeElicitation(id, answeredBy(who))
	if e == nil {
		s.permMu.Lock()
		known := s.elics[id]
		by := ""
		if known != nil {
			by = known.closedBy
		}
		s.permMu.Unlock()
		if known == nil {
			return nil, invalidParams("unknown elicitation")
		}
		return nil, &rpcError{Code: rpcAnsweredElsewhere, Message: elicitationClosedReason(by)}
	}
	s.audit.Log("rpc", with(who, audit.Fields{Dir: "in", Method: "_agmente/elicitation/answer", Project: e.agent.id}))
	s.resolveElicitation(e, action, content, answeredBy(who))
	return map[string]any{}, nil
}
