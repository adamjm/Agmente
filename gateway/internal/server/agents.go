package server

// One agent per (project, runner) (D-125). A project's own runner (store.Project.Runner) has its
// agent under the project id, so every lookup by project id still finds the default agent. Any other
// runner has its agent under id + "@" + runner. A session runs on the agent of its runner: a
// session/new names it in _meta["acpcode/runner"], an existing session has the one recorded for it,
// and none means the project's own. The agent's id (a.id) stays the project id for audit, state and
// the store; a.key is its key in Server.agents.

import (
	"context"
	"sort"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// runnerMetaKey is the _meta key of a session/new that names the session's runner. The gateway reads
// it and removes it, so the agent never sees it (as mcpEnabledKey is, mcp_servers.go).
const runnerMetaKey = "acpcode/runner"

// errRunnerUnknown is the refusal for a runner id the config does not list.
func errRunnerUnknown() *rpcError {
	return invalidParams("runner must be the id of one of the gateway's runners")
}

// ownRunner is the runner the project's own agent runs: the project's runner, or the config's
// default when it has none. "" when the project is unknown.
func (s *Server) ownRunner(projectID string) string {
	if s.store == nil {
		return ""
	}
	p, err := s.store.ProjectByID(context.Background(), projectID)
	if err != nil || p == nil {
		return ""
	}
	if p.Runner != "" {
		return p.Runner
	}
	if s.cfg != nil {
		return s.cfg.DefaultRunner
	}
	return ""
}

// agentKey is the key of the agent of (project, runner): the project id for "" and for the project's
// own runner, id@runner otherwise.
func (s *Server) agentKey(projectID, runner string) string {
	if runner == "" || runner == s.ownRunner(projectID) {
		return projectID
	}
	return projectID + "@" + runner
}

// agentFor returns the agent of (project, runner), making it when there is none. runner "" or the
// project's own runner is the project's own agent.
func (s *Server) agentFor(projectID, runner string) *projectAgent {
	key := s.agentKey(projectID, runner) // reads the store: before s.mu is taken
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.agents[key]
	if a == nil {
		a = newProjectAgent(s, projectID)
		a.key = key
		if key != projectID {
			a.runner = runner // the project's own agent takes its runner at start
		}
		s.agents[key] = a
	}
	return a
}

// agent returns the project's own agent.
func (s *Server) agent(projectID string) *projectAgent { return s.agentFor(projectID, "") }

// agentsOf returns the agents made so far for a project, the project's own first, then by key.
// It makes none.
func (s *Server) agentsOf(projectID string) []*projectAgent {
	s.mu.Lock()
	out := make([]*projectAgent, 0, 2)
	for _, a := range s.agents {
		if a.id == projectID {
			out = append(out, a)
		}
	}
	s.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		iOwn, jOwn := out[i].key == out[i].id, out[j].key == out[j].id
		if iOwn != jOwn {
			return iOwn
		}
		return out[i].key < out[j].key
	})
	return out
}

// existingAgentFor returns the agent of (project, runner) if one was ever made in this process,
// without making one.
func (s *Server) existingAgentFor(projectID, runner string) *projectAgent {
	key := s.agentKey(projectID, runner)
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.agents[key]
}

// requestRunner reads the optional runner of a session/new from params._meta["acpcode/runner"].
// Absent, null or "" is no choice (""). Anything but a string, or an id the config does not list,
// is refused with -32602.
func (s *Server) requestRunner(params *jsonv.Value) (string, *rpcError) {
	meta := params.Get("_meta")
	if meta == nil || meta.Kind != jsonv.Object {
		return "", nil
	}
	return s.runnerValue(meta.Obj[runnerMetaKey])
}

// runnerValue checks a runner id sent by the phone: absent, null or "" is no choice.
func (s *Server) runnerValue(v *jsonv.Value) (string, *rpcError) {
	if v.IsNull() {
		return "", nil
	}
	id, ok := v.StringValue()
	if !ok {
		return "", errRunnerUnknown()
	}
	if id == "" {
		return "", nil
	}
	if _, found := s.cfg.Agent(id); !found {
		return "", errRunnerUnknown()
	}
	return id, nil
}

// agentForRequest picks the agent for a request already routed to a project. A session/new takes
// the runner of its _meta; a request for a recorded session takes the session's runner; the rest
// take the project's own.
func (s *Server) agentForRequest(ctx context.Context, projectID, method string, params *jsonv.Value, sid string) (*projectAgent, *rpcError) {
	runner := ""
	switch {
	case method == "session/new":
		r, rerr := s.requestRunner(params)
		if rerr != nil {
			return nil, rerr
		}
		runner = r
	case sid != "":
		r, err := s.store.SessionRunner(ctx, sid)
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
		}
		runner = r
	}
	return s.agentFor(projectID, runner), nil
}

// dropRunnerKey removes the gateway's _meta key from a request, so the agent never sees it. An
// _meta left empty goes too, as dropEnabledIDs does.
func dropRunnerKey(params *jsonv.Value) {
	meta := params.Get("_meta")
	if meta == nil || meta.Kind != jsonv.Object {
		return
	}
	if _, ok := meta.Obj[runnerMetaKey]; !ok {
		return
	}
	delete(meta.Obj, runnerMetaKey)
	keys := make([]string, 0, len(meta.Keys))
	for _, k := range meta.Keys {
		if k != runnerMetaKey {
			keys = append(keys, k)
		}
	}
	meta.Keys = keys
	if len(keys) == 0 {
		delete(params.Obj, "_meta")
		pk := make([]string, 0, len(params.Keys))
		for _, k := range params.Keys {
			if k != "_meta" {
				pk = append(pk, k)
			}
		}
		params.Keys = pk
	}
}

// recordRunner records the runner of a new session when this agent is not the project's own (D-125).
// It is called once the agent has accepted the session and the session is recorded.
func (a *projectAgent) recordRunner(sid string) {
	if a.key == a.id {
		return
	}
	a.mu.Lock()
	runner := a.runner
	a.mu.Unlock()
	if runner == "" {
		return
	}
	if err := a.s.store.SetSessionRunner(context.Background(), sid, runner); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_runner"}))
	}
}

// sessionRunnerOf is the runner the sessions index shows: the session's recorded runner, else its
// project's runner ("" when neither is known).
func sessionRunnerOf(recorded, project string) string {
	if recorded != "" {
		return recorded
	}
	return project
}

// agentSubscribed is subscribedSessions for one agent: the subscribed sessions of the project that
// run on this agent. With one agent for the project it is every subscribed session.
func (s *Server) agentSubscribed(a *projectAgent) (map[string]bool, bool) {
	subs, any := s.subscribedSessions(a.id)
	if !any || len(s.agentsOf(a.id)) < 2 {
		return subs, any
	}
	out, kept := map[string]bool{}, false
	for sid := range subs {
		runner, err := s.store.SessionRunner(context.Background(), sid)
		if err != nil || s.agentKey(a.id, runner) == a.key {
			out[sid], kept = true, true
		}
	}
	return out, kept
}
