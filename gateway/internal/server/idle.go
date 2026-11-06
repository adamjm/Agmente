package server

// Idle close and idle stop (FR-24, FR-45, NFR-10, PLAN 3.12, D-016, D-020, D-032).
//
// A running agent checks itself every quarter of the idle time (between 50 ms and 30 s). A session
// is busy while a turn runs in it, an approval for it is open, a socket subscribes to it, or a
// load for it is under way; a busy session counts as active at every check. When the whole project
// has been inactive for the idle time and nothing is pending, the agent is stopped: the state
// becomes "stopping" under the same lock that forward takes, so no request can reach it after the
// decision, and a request that comes meanwhile waits for the exit, then starts a new agent
// (ensure). Otherwise, if the agent offers session/close, each live session that has been
// inactive for the idle time is closed; the next request for it opens it again (autoLoad).

import (
	"strconv"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
)

// autoLoad lists the session methods for which the gateway opens a session that is not live.
var autoLoad = map[string]bool{
	"session/prompt": true, "session/set_mode": true, "session/set_model": true, "session/set_config_option": true,
}

// touchLocked records activity for the project and, when sid is given, for that live session. It
// must be called with a.mu held.
func (a *projectAgent) touchLocked(sid string) {
	now := time.Now()
	a.lastActive = now
	if sid != "" && a.live[sid] != nil {
		a.sessionActive[sid] = now
	}
}

// touchSessions counts a subscriber leaving the given sessions as activity, so the idle time runs
// from the moment it left and not from the last periodic check that saw it (D-078).
func (a *projectAgent) touchSessions(sids []string) {
	if len(sids) == 0 {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, sid := range sids {
		if a.live[sid] != nil {
			a.touchLocked(sid)
		}
	}
}

func (s *Server) idleTime() time.Duration {
	return time.Duration(s.cfg.Limits.IdleSeconds) * time.Second
}

func (a *projectAgent) idleLoop(proc *agentProcess) {
	idle := a.s.idleTime()
	every := min(max(idle/4, 50*time.Millisecond), 30*time.Second)
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-proc.exited:
			return
		case <-t.C:
			if a.idleCheck(proc, idle) {
				return
			}
		}
	}
}

// openApprovals returns the sessions of this agent with an open approval, and whether any is open.
func (s *Server) openApprovals(a *projectAgent) (map[string]bool, bool) {
	s.permMu.Lock()
	defer s.permMu.Unlock()
	out, any := map[string]bool{}, false
	for _, p := range s.perms {
		if p.agent == a {
			any = true
			out[p.session] = true
		}
	}
	return out, any
}

// subscribedSessions returns the sessions of a project that a socket subscribes to, and whether
// there is any.
func (s *Server) subscribedSessions(projectID string) (map[string]bool, bool) {
	s.evMu.Lock()
	defer s.evMu.Unlock()
	out, any := map[string]bool{}, false
	for sid, set := range s.subs {
		for _, sub := range set {
			if sub.project == projectID {
				out[sid], any = true, true
			}
		}
	}
	return out, any
}

// idleCheck stops the agent or closes idle sessions. It reports true when it stopped the agent.
func (a *projectAgent) idleCheck(proc *agentProcess, idle time.Duration) bool {
	approvals, anyApproval := a.s.openApprovals(a)
	subs, anySub := a.s.subscribedSessions(a.id)
	now := time.Now()

	a.mu.Lock()
	if a.proc != proc || a.state != agentRunning {
		a.mu.Unlock()
		return true
	}
	busy := map[string]bool{}
	for sid := range approvals {
		busy[sid] = true
	}
	for sid := range subs {
		busy[sid] = true
	}
	for sid := range a.reloads {
		busy[sid] = true
	}
	for _, p := range a.pending {
		if p.turn != "" {
			busy[p.turn] = true
		}
	}
	for sid := range busy {
		if a.live[sid] != nil {
			a.sessionActive[sid] = now
		}
	}
	if len(a.pending) > 0 || anyApproval || anySub || len(a.reloads) > 0 {
		a.lastActive = now
	}
	if now.Sub(a.lastActive) >= idle {
		a.setState(agentStopping) // forward and ensure now wait for the exit
		a.mu.Unlock()
		a.s.audit.Log("agent_idle_stop", a.fields(audit.Fields{Pid: proc.pid()}))
		proc.terminate(killGrace)
		return true
	}
	if !a.canClose {
		a.mu.Unlock()
		return false
	}
	var lines [][]byte
	var closed []string
	for sid := range a.live {
		last, ok := a.sessionActive[sid]
		if !ok {
			a.sessionActive[sid] = now
			continue
		}
		if busy[sid] || now.Sub(last) < idle {
			continue
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
		lines = append(lines, append(msg.Marshal(), '\n'))
		closed = append(closed, sid)
	}
	a.mu.Unlock()
	for i, line := range lines {
		a.s.audit.Log("session_idle_close", a.fields(audit.Fields{Reason: closed[i]}))
		_, _ = a.write(proc, line)
	}
	return false
}
