package server

// Per-project auto-approve (D-124, amends D-009 for the projects that opt in).
//
// A project with auto_approve on has its session/request_permission answered by the gateway with
// an allow option, at once, with no phone involved. It is off by default and it is the owner's
// switch for one project (`_acpcode/projects/setAutoApprove`, full scope only). Nothing else here
// changes the approval queue: a project with the switch off, a request with no allow option, or any
// read error all fall through to the phones exactly as before.

import (
	"context"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// autoApprovedBy is the answeredBy value the store and the phones see for an automatic answer.
const autoApprovedBy = "auto"

// allowOutcome is the mirror of rejectOutcome: the first allow_once option, else the first
// allow_always option. It returns nil when the request offers neither, so the caller asks the phone.
// allow_once is preferred so one switch never grants a standing permission inside the agent.
func allowOutcome(options *jsonv.Value) *jsonv.Value {
	if options == nil || options.Kind != jsonv.Array {
		return nil
	}
	for _, want := range []string{"allow_once", "allow_always"} {
		for _, o := range options.Arr {
			kind, _ := o.Get("kind").StringValue()
			id, ok := o.Get("optionId").StringValue()
			if kind == want && ok && id != "" {
				return selected(id)
			}
		}
	}
	return nil
}

// autoApproves reports whether the project's switch is on. Any error means no: the request goes to
// the phones.
func (s *Server) autoApproves(ctx context.Context, projectID string) bool {
	p, err := s.store.ProjectByID(ctx, projectID)
	return err == nil && p != nil && p.AutoApprove
}

// tryAutoApprove answers the permission request itself when the project's switch is on and the
// request offers an allow option. It reports whether it did. The approval is recorded and closed
// like any other (answered_by "auto"), and subscribers get approval_answered, so the phone shows
// what happened. No push is sent: nobody has to act.
func (s *Server) tryAutoApprove(a *projectAgent, proc *agentProcess, agentID *jsonv.Value, sessionID string, params *jsonv.Value) bool {
	if !s.autoApproves(context.Background(), a.id) {
		return false
	}
	outcome := allowOutcome(params.Get("options"))
	if outcome == nil {
		return false
	}
	p := s.openPermission(a, proc, agentID, sessionID, params)
	if p = s.takePermission(p.id, autoApprovedBy); p == nil {
		return true // closed by an exit or a cancel in the meantime; nothing is left to answer
	}
	s.audit.Log("approval_auto", a.fields(audit.Fields{Reason: autoApprovedBy}))
	s.resolve(p, outcomeResponse(p.id, outcome), autoApprovedBy)
	return true
}

// setAutoApprove answers `_acpcode/projects/setAutoApprove {projectId, enabled}`.
func (s *Server) setAutoApprove(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	id, ok := params.Get("projectId").StringValue()
	if !ok || id == "" {
		return nil, invalidParams("projectId is required")
	}
	v := params.Get("enabled")
	if v == nil || v.Kind != jsonv.Bool {
		return nil, invalidParams("enabled must be true or false")
	}
	p, err := s.store.SetAutoApprove(ctx, id, v.B)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot save the project"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	reason := "auto_approve_off"
	if v.B {
		reason = "auto_approve_on"
	}
	s.audit.Log("project_updated", with(who, audit.Fields{Project: id, Reason: reason}))
	return map[string]any{"project": toProjectJSON(*p)}, nil
}
