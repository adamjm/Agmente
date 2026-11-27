package server

// `_acpcode/sessions/delete {sessionId}`: removes a session from the gateway, so it leaves the index
// on every device. It is the phone's way to delete a session whatever the agent supports.
//
//   - Refused with -32001 while a turn is running or an approval is open in the session: the phone
//     stops it first.
//   - When the agent has the session open, the gateway asks it for session/delete first, for a short
//     time. An agent that refuses, lacks the method or does not answer does not stop the removal: the
//     gateway's own record, events and read markers go either way.
//   - It never starts an agent.
//
// The result is {deleted: true, agent: true|false}; `agent` says whether the agent accepted its delete.

import (
	"context"
	"fmt"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// deleteAgentWait bounds the wait for the agent's answer to session/delete.
const deleteAgentWait = 5 * time.Second

// serveDelete answers one _acpcode/sessions/delete request from its own goroutine, because it can
// wait for the agent.
func (s *Server) serveDelete(who audit.Who, id, params *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	const method = "_acpcode/sessions/delete"
	defer s.recoverCall(who, method, id, reply)
	result, rerr := s.deleteSession(who, params)
	reply(id, result, rerr)
}

func (s *Server) deleteSession(who audit.Who, params *jsonv.Value) (any, *rpcError) {
	sid, ok := params.Get("sessionId").StringValue()
	if !ok || sid == "" {
		return nil, invalidParams("sessionId is required")
	}
	ctx := s.pushCtx
	pid, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	if pid == "" {
		return nil, &rpcError{Code: rpcInvalidParams, Message: "unknown session", Data: map[string]string{"reason": "unknown_session"}}
	}
	running, awaiting := s.liveStatus()
	if running[sid] || awaiting[sid] {
		return nil, &rpcError{Code: rpcRefused, Message: "the session has a turn running: stop it before deleting it"}
	}
	runner, err := s.store.SessionRunner(ctx, sid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	agentDeleted := false
	if a := s.existingAgentFor(pid, runner); a != nil {
		a.mu.Lock()
		open := a.state == agentRunning && a.live[sid] != nil
		a.mu.Unlock()
		if open {
			agentDeleted = s.deleteOnAgent(who, sid)
		}
	}
	// The agent's accepted delete removes the rows already (supervisor.go); this makes the removal
	// certain when it did not, and does nothing the second time.
	if err := s.store.DeleteSession(ctx, sid); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot delete the session"}
	}
	s.audit.Log("session_delete", with(who, audit.Fields{Project: pid, Reason: fmt.Sprintf("agent=%t", agentDeleted)}))
	return map[string]any{"deleted": true, "agent": agentDeleted}, nil
}

// deleteOnAgent sends session/delete through the normal agent path and reports whether the agent
// accepted it. A refusal, an error and a silence all give false.
func (s *Server) deleteOnAgent(who audit.Who, sid string) bool {
	gc := s.newGatewayCall(who)
	defer gc.finish()
	p := jsonv.Obj()
	p.Set("sessionId", jsonv.Str(sid))
	reqID := fmt.Sprintf("acpcode-delete-%d", gatewayCallSeq.Add(1))
	if rerr := gc.send("session/delete", reqID, p); rerr != nil {
		return false
	}
	ctx, cancel := context.WithTimeout(s.pushCtx, deleteAgentWait)
	defer cancel()
	for {
		select {
		case msg := <-gc.answers:
			if got, _ := msg.Get("id").StringValue(); got == reqID {
				return msg.Get("error").IsNull()
			}
		case <-ctx.Done():
			return false
		}
	}
}
