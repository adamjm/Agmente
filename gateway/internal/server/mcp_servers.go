package server

// The gateway's own MCP server list (D-107). The Mac admin keeps it (internal/mcpservers and the
// `mcp-server` command). A phone lists it, and picks which of its servers a session enables by id.
// The gateway resolves the ids on the host and sends the full entries to the agent, inside the
// session request's mcpServers, next to the phone's own entries (D-084 as revised by D-107). The
// set a session takes is stored per session and read at each load, so a restart keeps it, and a
// change takes effect at the session's next load.

import (
	"context"
	"fmt"
	"strconv"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/mcpservers"
)

// mcpEnabledKey is the _meta key of a session/new: the ids of the gateway's MCP servers the session
// enables. It follows the gateway's own _meta keys (`acpcode/gateway`, and `bob/mode` for Bob).
const mcpEnabledKey = "acpcode/mcpEnabled"

// rpcRefused is -32001: the request is valid but the state of the gateway refuses it. Its data
// carries a reason from a fixed set (D-031, D-106).
const rpcRefused = -32001

// serveMCPServers answers the _acpcode/mcp/servers/* methods. handled is false for any other method.
func (s *Server) serveMCPServers(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (any, *rpcError, bool) {
	switch method {
	case "_acpcode/mcp/servers/list":
		list, err := s.library().List()
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot read the MCP server list"}, true
		}
		return map[string]any{"servers": list}, nil, true
	case "_acpcode/mcp/servers/put", "_acpcode/mcp/servers/delete":
		// The list is the Mac admin's: it is changed with `acpcode-gateway mcp-server` on the host,
		// never through a socket (D-107). Every socket client is refused, the phone included.
		s.audit.Log("mcp_refused", with(who, audit.Fields{Method: method, Reason: "admin_only"}))
		return nil, &rpcError{Code: rpcRefused, Message: "the MCP server list is changed on the gateway host", Data: map[string]any{"reason": "admin_only"}}, true
	case "_acpcode/mcp/servers/setEnabled":
		result, rerr := s.setSessionMCP(ctx, who, params)
		return result, rerr, true
	}
	return nil, nil, false
}

// library is the gateway's MCP server list. It is read from the files each time it is used.
func (s *Server) library() *mcpservers.Library { return mcpservers.Open(s.cfg.StateDir) }

// setSessionMCP answers _acpcode/mcp/servers/setEnabled {sessionId, ids}. It replaces the session's
// set. It is refused while a turn or an approval is open in the session (D-107). On success the
// session is closed in the agent, so its next prompt loads it with the new set.
func (s *Server) setSessionMCP(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	sid, ok := params.Get("sessionId").StringValue()
	if !ok || sid == "" {
		return nil, invalidParams("sessionId is required")
	}
	ids, ok := mcpIDsValue(params.Get("ids"))
	if !ok {
		return nil, invalidParams("ids must be a list of MCP server ids")
	}
	pid, err := s.store.SessionProject(ctx, sid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	if pid == "" {
		return nil, &rpcError{Code: rpcInvalidParams, Message: "unknown session", Data: map[string]any{"reason": "unknown_session"}}
	}
	_, missing, err := s.library().Resolve(ids)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the MCP server list"}
	}
	if len(missing) > 0 {
		return nil, invalidParams("the gateway has no MCP server with id %s", missing[0])
	}
	a := s.agent(pid)
	approvals, _ := s.openApprovals(a)
	closed, rerr := a.setSessionMCP(sid, ids, approvals)
	if rerr != nil {
		if rerr.Code == rpcRefused {
			s.audit.Log("mcp_refused", with(who, audit.Fields{Method: "_acpcode/mcp/servers/setEnabled", Project: pid, Reason: "turn_open"}))
		}
		return nil, rerr
	}
	s.audit.Log("mcp_session_set", with(who, audit.Fields{Project: pid, Reason: fmt.Sprintf("count=%d closed=%t", len(ids), closed)}))
	return map[string]any{"sessionId": sid, "enabled": ids, "closed": closed}, nil
}

// setSessionMCP stores the set and closes the session in the agent, when it is open there. It must
// not run while a turn or an approval is open for the session. The close is written after the lock
// is released, as the idle close is (D-032).
func (a *projectAgent) setSessionMCP(sid string, ids []string, approvals map[string]bool) (bool, *rpcError) {
	a.mu.Lock()
	busy := approvals[sid] || a.reloads[sid] != nil
	for _, p := range a.pending {
		if p.turn == sid {
			busy = true
		}
	}
	if busy {
		a.mu.Unlock()
		return false, &rpcError{Code: rpcRefused, Message: "a turn is open in this session: wait for it to end", Data: map[string]any{"reason": "turn_open"}}
	}
	if err := a.s.store.SetSessionMCP(context.Background(), sid, ids); err != nil {
		a.mu.Unlock()
		return false, &rpcError{Code: rpcInternal, Message: "cannot save the session's MCP servers"}
	}
	proc, line := a.closeLiveLocked(sid)
	a.mu.Unlock()
	if proc == nil {
		return false, nil
	}
	a.s.audit.Log("session_mcp_close", a.fields(audit.Fields{Reason: sid}))
	_, _ = a.write(proc, line)
	return true, nil
}

// closeLiveLocked prepares the agent's session/close for a live session and forgets it here, as the
// idle close does. It returns nil when the session is not live. It must be called with a.mu held.
func (a *projectAgent) closeLiveLocked(sid string) (*agentProcess, []byte) {
	proc := a.proc
	if proc == nil || a.state != agentRunning || !a.canClose || a.live[sid] == nil {
		return nil, nil
	}
	delete(a.live, sid)
	delete(a.sessionActive, sid)
	a.nextID++
	n := a.nextID
	a.pending[n] = &pendingRequest{method: "session/close", sid: sid}
	params := jsonv.Obj()
	params.Set("sessionId", jsonv.Str(sid))
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("id", &jsonv.Value{Kind: jsonv.Number, Num: strconv.FormatInt(n, 10)})
	msg.Set("method", jsonv.Str("session/close"))
	msg.Set("params", params)
	return proc, append(msg.Marshal(), '\n')
}

// checkEnabledIDs refuses a session/new whose _meta names an id the gateway does not have, or a
// value that is not a list of ids (D-107). It runs before routing, so no agent sees the request.
func (s *Server) checkEnabledIDs(who audit.Who, params *jsonv.Value) *rpcError {
	v, given := enabledIDsValue(params)
	if !given {
		return nil
	}
	ids, ok := mcpIDsValue(v)
	if !ok {
		s.audit.Log("mcp_refused", with(who, audit.Fields{Method: "session/new", Reason: "mcp_enabled"}))
		return invalidParams("_meta %s must be a list of MCP server ids", mcpEnabledKey)
	}
	_, missing, err := s.library().Resolve(ids)
	if err != nil {
		return &rpcError{Code: rpcInternal, Message: "cannot read the MCP server list"}
	}
	if len(missing) > 0 {
		s.audit.Log("mcp_refused", with(who, audit.Fields{Method: "session/new", Reason: "unknown_id"}))
		return invalidParams("the gateway has no MCP server with id %s", missing[0])
	}
	return nil
}

// mcpIDsValue reads a list of gateway MCP server ids: at most MaxEntries, each 32 lowercase hex
// digits. A repeat is dropped; the order is kept.
func mcpIDsValue(v *jsonv.Value) ([]string, bool) {
	if v == nil || v.Kind != jsonv.Array || len(v.Arr) > mcpservers.MaxEntries {
		return nil, false
	}
	seen := map[string]bool{}
	ids := make([]string, 0, len(v.Arr))
	for _, it := range v.Arr {
		if it == nil {
			return nil, false
		}
		id, ok := it.StringValue()
		if !ok || !mcpservers.ValidID(id) {
			return nil, false
		}
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids, true
}

// enabledIDsValue returns the _meta list of a request, and whether one was sent (null is not sent).
func enabledIDsValue(params *jsonv.Value) (*jsonv.Value, bool) {
	meta := params.Get("_meta")
	if meta == nil || meta.Kind != jsonv.Object {
		return nil, false
	}
	v, ok := meta.Obj[mcpEnabledKey]
	if !ok || v == nil || v.Kind == jsonv.Null {
		return nil, false
	}
	return v, true
}

// dropEnabledIDs removes the gateway's _meta key from a request, so the agent never sees it.
func dropEnabledIDs(params *jsonv.Value) {
	meta := params.Get("_meta")
	if meta == nil || meta.Kind != jsonv.Object {
		return
	}
	if _, ok := meta.Obj[mcpEnabledKey]; !ok {
		return
	}
	delete(meta.Obj, mcpEnabledKey)
	keys := meta.Keys[:0]
	for _, k := range meta.Keys {
		if k != mcpEnabledKey {
			keys = append(keys, k)
		}
	}
	meta.Keys = keys
	if len(keys) == 0 { // nothing else was in _meta: the agent gets no empty _meta either
		delete(params.Obj, "_meta")
		pk := params.Keys[:0]
		for _, k := range params.Keys {
			if k != "_meta" {
				pk = append(pk, k)
			}
		}
		params.Keys = pk
	}
}

// agentEntry is one server ready for the agent: its name, for the duplicate check, and its JSON.
type agentEntry struct {
	name  string
	value *jsonv.Value
}

// mcpForRequest rewrites the mcpServers of a session request, which is the list the agent receives,
// and returns the ids the session takes (D-107). A session/new takes the ids in its _meta, or the
// defaults when none are sent; the caller records them once the agent accepts the session. A load
// or resume takes the set stored for the session (sid). The phone's own entries stay first. It must
// be called with a.mu held, and before the request is written to the agent.
func (s *Server) mcpForRequest(a *projectAgent, method, sid string, params *jsonv.Value) (ids []string, record bool) {
	if params == nil || params.Kind != jsonv.Object {
		return nil, false
	}
	if method != "session/new" {
		params.Set("mcpServers", s.loadMCPLocked(a, sid, mcpKept(params)))
		return nil, false
	}
	given, ok := enabledIDsValue(params)
	var want []string
	if ok {
		want, _ = mcpIDsValue(given)
	} else {
		want = s.defaultMCPIDs(a)
	}
	dropEnabledIDs(params)
	entries, kept := s.agentMCPEntries(a, want)
	params.Set("mcpServers", s.mergeMCP(a, mcpKept(params), entries))
	return kept, true
}

// loadMCPLocked is the list a session's load carries: the phone's own entries, then the enabled
// gateway servers stored for the session. It must be called with a.mu held.
func (s *Server) loadMCPLocked(a *projectAgent, sid string, own *jsonv.Value) *jsonv.Value {
	ids, err := s.store.SessionMCP(context.Background(), sid)
	if err != nil {
		s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_mcp"}))
		ids = nil
	}
	entries, _ := s.agentMCPEntries(a, ids)
	return s.mergeMCP(a, own, entries)
}

// defaultMCPIDs is the set a new session takes when the phone sends none.
func (s *Server) defaultMCPIDs(a *projectAgent) []string {
	ids, err := s.library().DefaultIDs()
	if err != nil {
		s.audit.Log("store_error", a.fields(audit.Fields{Reason: "mcp_list"}))
		return nil
	}
	return ids
}

// agentMCPEntries resolves ids to the entries the agent receives. An id the list no longer holds is
// dropped and audited with the id only; it never fails the session (D-107). It returns the ids that
// were sent.
func (s *Server) agentMCPEntries(a *projectAgent, ids []string) ([]agentEntry, []string) {
	found, missing, err := s.library().Resolve(ids)
	if err != nil {
		s.audit.Log("store_error", a.fields(audit.Fields{Reason: "mcp_list"}))
		return nil, nil
	}
	for _, id := range missing {
		s.audit.Log("mcp_missing", a.fields(audit.Fields{Reason: "id=" + id}))
	}
	out := make([]agentEntry, 0, len(found))
	kept := make([]string, 0, len(found))
	for _, f := range found {
		out = append(out, agentEntry{name: f.Entry.Name, value: agentServerJSON(f)})
		kept = append(kept, f.Entry.ID)
	}
	return out, kept
}

// mergeMCP appends the gateway's entries to the phone's. A gateway entry whose name the phone
// already uses is dropped and audited, so the agent never gets two servers with one name.
func (s *Server) mergeMCP(a *projectAgent, own *jsonv.Value, entries []agentEntry) *jsonv.Value {
	out := &jsonv.Value{Kind: jsonv.Array}
	names := map[string]bool{}
	if own != nil {
		for _, e := range own.Arr {
			if n, ok := e.Get("name").StringValue(); ok {
				names[n] = true
			}
			out.Arr = append(out.Arr, e)
		}
	}
	for _, en := range entries {
		if names[en.name] {
			s.audit.Log("mcp_missing", a.fields(audit.Fields{Reason: "name_in_use"}))
			continue
		}
		names[en.name] = true
		out.Arr = append(out.Arr, en.value)
	}
	return out
}

// agentServerJSON is one gateway server as an ACP mcpServers entry (stdio or http). The secret
// values are copied in here, and nowhere else.
func agentServerJSON(f mcpservers.Full) *jsonv.Value {
	o := jsonv.Obj()
	o.Set("name", jsonv.Str(f.Entry.Name))
	if f.Entry.Transport == "http" {
		o.Set("type", jsonv.Str("http"))
		o.Set("url", jsonv.Str(f.Entry.URL))
		o.Set("headers", pairsJSON(f.Secrets.Headers))
		return o
	}
	o.Set("command", jsonv.Str(f.Entry.Command))
	args := make([]*jsonv.Value, 0, len(f.Secrets.Args))
	for _, a := range f.Secrets.Args {
		args = append(args, jsonv.Str(a))
	}
	o.Set("args", &jsonv.Value{Kind: jsonv.Array, Arr: args})
	o.Set("env", pairsJSON(f.Secrets.Env))
	return o
}

// pairsJSON is an array of {name, value} objects, as ACP sends headers and environment variables.
func pairsJSON(ps []mcpservers.Pair) *jsonv.Value {
	items := make([]*jsonv.Value, 0, len(ps))
	for _, p := range ps {
		o := jsonv.Obj()
		o.Set("name", jsonv.Str(p.Name))
		o.Set("value", jsonv.Str(p.Value))
		items = append(items, o)
	}
	return &jsonv.Value{Kind: jsonv.Array, Arr: items}
}

// recordSessionMCP stores the set a session took when the agent accepted it (D-107).
func (s *Server) recordSessionMCP(sid string, ids []string) {
	if err := s.store.SetSessionMCP(context.Background(), sid, ids); err != nil {
		s.audit.Log("store_error", audit.Fields{Reason: "session_mcp"})
	}
}
