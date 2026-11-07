package server

// The session index and read markers (FR-21, FR-25, PLAN 3.8, D-030).

import (
	"context"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

type sessionJSON struct {
	SessionID    string     `json:"sessionId"`
	ProjectID    string     `json:"projectId"`
	Title        *string    `json:"title"`
	Status       string     `json:"status"`
	LastActivity string     `json:"lastActivity"`
	HeadSeq      int64      `json:"headSeq"`
	Unread       int64      `json:"unread"`
	Usage        *usageJSON `json:"usage,omitempty"` // C1: left out until the agent reports usage
}

// usageJSON is a session's last reported usage (C1, D-092). Remaining context is size - used; the
// percent is used / size. The cost fields are left out when the agent sent none.
type usageJSON struct {
	Used         int64    `json:"used"`
	Size         int64    `json:"size"`
	CostAmount   *float64 `json:"costAmount,omitempty"`
	CostCurrency *string  `json:"costCurrency,omitempty"`
	UpdatedAt    string   `json:"updatedAt"`
}

func toUsageJSON(u *store.Usage) *usageJSON {
	if u == nil {
		return nil
	}
	return &usageJSON{Used: u.Used, Size: u.Size, CostAmount: u.CostAmount, CostCurrency: u.CostCurrency, UpdatedAt: u.Updated}
}

// liveStatus returns the sessions with a turn running and the sessions with an open permission
// request, from the gateway's own state. Neither survives a gateway restart, so neither is stored.
func (s *Server) liveStatus() (running, awaiting map[string]bool) {
	running, awaiting = map[string]bool{}, map[string]bool{}
	s.mu.Lock()
	agents := make([]*projectAgent, 0, len(s.agents))
	for _, a := range s.agents {
		agents = append(agents, a)
	}
	s.mu.Unlock()
	for _, a := range agents {
		a.mu.Lock()
		for _, p := range a.pending {
			if p.turn != "" {
				running[p.turn] = true
			}
		}
		a.mu.Unlock()
	}
	s.permMu.Lock()
	for _, p := range s.perms {
		if p.session != "" {
			awaiting[p.session] = true
		}
	}
	s.permMu.Unlock()
	return running, awaiting
}

// sessionIndex answers `_agmente/sessions/index {projectId?}`. It starts no agent.
func (s *Server) sessionIndex(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	projectID := ""
	if v := params.Get("projectId"); !v.IsNull() {
		id, ok := v.StringValue()
		if !ok || id == "" {
			return nil, invalidParams("projectId must be a project id")
		}
		p, err := s.store.ProjectByID(ctx, id)
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
		}
		if p == nil {
			return nil, invalidParams("unknown project")
		}
		projectID = id
	}
	rows, err := s.store.SessionIndex(ctx, who.Identity, projectID)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	s.watchProjectStates(ctx, who.Conn, projectID) // C2: this socket is told the agent state of the projects it lists
	running, awaiting := s.liveStatus()
	out := make([]sessionJSON, 0, len(rows))
	for _, r := range rows {
		status := r.Status
		switch {
		case awaiting[r.SessionID]:
			status = "awaiting_approval"
		case running[r.SessionID]:
			status = "running"
		}
		out = append(out, sessionJSON{
			SessionID: r.SessionID, ProjectID: r.ProjectID, Title: r.Title, Status: status,
			LastActivity: r.LastActivity, HeadSeq: r.HeadSeq, Unread: r.Unread, Usage: toUsageJSON(r.Usage),
		})
	}
	return map[string]any{"sessions": out}, nil
}

// markRead answers `_agmente/sessions/read {sessionId, seq}`: every device of the identity has now
// seen the session up to seq (FR-25). The marker never moves back and stops at the head.
func (s *Server) markRead(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	sid, _ := params.Get("sessionId").StringValue()
	if sid == "" {
		return nil, invalidParams("sessionId is required")
	}
	v := params.Get("seq")
	seq, ok := v.Int()
	if v.IsNull() || v.Kind != jsonv.Number || !ok || seq < 0 {
		return nil, invalidParams("seq must be a non-negative integer")
	}
	pid, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	if pid == "" {
		return nil, invalidParams("unknown session")
	}
	marker, err := s.store.MarkRead(ctx, who.Identity, sid, seq)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot write the read marker"}
	}
	return map[string]any{"lastSeenSeq": marker}, nil
}
