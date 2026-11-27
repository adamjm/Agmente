package server

// The project agent state the phone sees (C2, D-092): `_acpcode/project/state {projectId, agent,
// since}`. It is a gateway notification, never an agent message and never in the event log.
//
// A project can have several agents, one per runner (agents.go, D-125). The state the phone sees is
// the aggregate of them, by this precedence: "running" if any agent is running; else "starting" if
// any is starting; else "stopping" if any is stopping; else "stopped". A project that is running on
// one runner and stopping on another is running.
//
// It is change-only: a transition to the state already sent is not sent again. At most one is sent
// per project every projectStateGap (so at most two a second). When transitions come faster, the
// newest state is sent when the gap ends, so the phone always ends on the true state. Only sockets
// that listed the project (_acpcode/sessions/index, or _acpcode/projects/list) get it. A listing also
// sends its socket one snapshot of each listed project's current state (sendSnapshot, G2, D-104). The
// snapshot is not rate limited, not audited and does not change the change-only state above.

import (
	"context"
	"sync"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// projectStateGap is the least time between two state notifications for one project.
const projectStateGap = 500 * time.Millisecond

const projectStateTime = "2006-01-02T15:04:05.000Z"

// stateName is the agent field of the notification.
func stateName(st agentState) string {
	switch st {
	case agentStarting:
		return "starting"
	case agentRunning:
		return "running"
	case agentStopping:
		return "stopping"
	default:
		return "stopped"
	}
}

// aggregateState is the state of a project from the states of its agents (see the file comment).
func aggregateState(states map[string]string) string {
	rank := map[string]int{"running": 3, "starting": 2, "stopping": 1}
	best := "stopped"
	for _, st := range states {
		if rank[st] > rank[best] {
			best = st
		}
	}
	return best
}

// projState is the notification state of one project: the state of each of its agents, the
// aggregate, the sockets that listed the project, and the change-only and rate-limit bookkeeping.
type projState struct {
	s  *Server
	id string

	mu     sync.Mutex
	agents map[string]string    // agent key -> its state name
	want   string               // the newest aggregate state; "" until the first transition
	since  time.Time            // when want began
	subs   map[*client]struct{} // sockets that listed this project
	sent   string               // the state last sent; "" until the first transition
	sentAt time.Time            // when sent was sent
	timer  *time.Timer          // a flush due when the gap ends, or nil
}

// stateOf returns the notification state of a project, making it on first use.
func (s *Server) stateOf(projectID string) *projState {
	s.pstMu.Lock()
	defer s.pstMu.Unlock()
	if s.pstates == nil {
		s.pstates = map[string]*projState{}
	}
	ps := s.pstates[projectID]
	if ps == nil {
		ps = &projState{s: s, id: projectID, agents: map[string]string{}, subs: map[*client]struct{}{}}
		s.pstates[projectID] = ps
	}
	return ps
}

// watchProjectStates subscribes the socket with connection number conn to the agent state of one
// project, or of every project when projectID is "" (sessions/index with no project). The socket
// is found by its connection; a call with no socket (a unit test) subscribes nobody.
func (s *Server) watchProjectStates(ctx context.Context, conn int, projectID string) {
	c := s.clientByConn(conn)
	if c == nil {
		return
	}
	if projectID != "" {
		ps := s.stateOf(projectID)
		ps.watch(c)
		ps.sendSnapshot(c)
		return
	}
	projects, err := s.store.Projects(ctx)
	if err != nil {
		return
	}
	for _, p := range projects {
		ps := s.stateOf(p.ID)
		ps.watch(c)
		ps.sendSnapshot(c)
	}
}

// clientByConn returns the open socket with this connection number, or nil.
func (s *Server) clientByConn(conn int) *client {
	s.mu.Lock()
	defer s.mu.Unlock()
	for c := range s.clients {
		if c.who.Conn == conn {
			return c
		}
	}
	return nil
}

// watch adds a socket to the sockets told this project's agent state. A socket that has closed is
// dropped on the way.
func (ps *projState) watch(c *client) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	for k := range ps.subs {
		if closedClient(k) {
			delete(ps.subs, k)
		}
	}
	ps.subs[c] = struct{}{}
}

func closedClient(c *client) bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// noteState records an agent's transition to st (setState, with a.mu held). It takes only the
// project state's lock, never a.mu.
func (a *projectAgent) noteState(st agentState) {
	a.s.stateOf(a.id).note(a.key, stateName(st))
}

// note records the state of one agent and sends the project's notification now or when the gap
// ends, when the aggregate changed.
func (ps *projState) note(key, name string) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	ps.agents[key] = name
	agg := aggregateState(ps.agents)
	if agg == ps.want {
		return
	}
	ps.want = agg
	ps.since = time.Now()
	if ps.timer != nil {
		return // a flush is already due, and it sends the newest state
	}
	if wait := projectStateGap - time.Since(ps.sentAt); wait > 0 {
		ps.timer = time.AfterFunc(wait, ps.flush)
		return
	}
	ps.flushLocked()
}

// flush runs when the gap ends: it sends the newest state if it differs from the last one sent.
func (ps *projState) flush() {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	ps.timer = nil
	ps.flushLocked()
}

// flushLocked sends the newest state to the subscribed sockets when it is not the one already
// sent. It must be called with ps.mu held.
func (ps *projState) flushLocked() {
	if ps.want == ps.sent {
		return
	}
	// sent starts as "", so the first transition is always sent, whenever the socket listed the
	// project. No state is assumed as the baseline.
	ps.sent = ps.want
	ps.sentAt = time.Now()
	out := ps.message(ps.sent, ps.since)
	for c := range ps.subs {
		if closedClient(c) {
			delete(ps.subs, c)
			continue
		}
		c.send(out)
	}
	ps.s.audit.Log("project_state", audit.Fields{Project: ps.id, Reason: ps.sent})
}

// sendSnapshot sends one socket the project's current agent state (G2, D-104): the state every listing
// call starts from, so a project already running when the phone reconnects is not shown as stopped. A
// project no agent has run for is "stopped". The snapshot is read under ps.mu, the lock the change-only
// flush takes, so it is never older than a broadcast sent before it. It does not touch sent or
// sentAt (the change-only rule and the 2-a-second limit are unchanged), and it is not audited.
func (ps *projState) sendSnapshot(c *client) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	if closedClient(c) {
		return
	}
	agent := ps.want
	if agent == "" {
		agent = stateName(agentStopped) // no transition yet: no agent has run for this project
	}
	since := ps.since
	if since.IsZero() {
		since = time.Now()
	}
	c.send(ps.message(agent, since))
}

// message is the `_acpcode/project/state` notification (C2) for one agent state. It must be called
// with ps.mu held.
func (ps *projState) message(agent string, since time.Time) []byte {
	params := jsonv.Obj()
	params.Set("projectId", jsonv.Str(ps.id))
	params.Set("agent", jsonv.Str(agent))
	params.Set("since", jsonv.Str(since.UTC().Format(projectStateTime)))
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("method", jsonv.Str("_acpcode/project/state"))
	msg.Set("params", params)
	return msg.Marshal()
}
