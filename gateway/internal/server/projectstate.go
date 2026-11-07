package server

// The project agent state the phone sees (C2, D-092): `_agmente/project/state {projectId, agent,
// since}`. It is a gateway notification, never an agent message and never in the event log.
//
// It is change-only: a transition to the state already sent is not sent again. At most one is sent
// per project every projectStateGap (so at most two a second). When transitions come faster, the
// newest state is sent when the gap ends, so the phone always ends on the true state. Only sockets
// that listed the project (_agmente/sessions/index, or _agmente/projects/list) get it. A listing also
// sends its socket one snapshot of each listed project's current state (sendSnapshot, G2, D-104). The
// snapshot is not rate limited, not audited and does not change the change-only state above.

import (
	"context"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
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

// watchProjectStates subscribes the socket with connection number conn to the agent state of one
// project, or of every project when projectID is "" (sessions/index with no project). The socket
// is found by its connection; a call with no socket (a unit test) subscribes nobody.
func (s *Server) watchProjectStates(ctx context.Context, conn int, projectID string) {
	c := s.clientByConn(conn)
	if c == nil {
		return
	}
	if projectID != "" {
		a := s.agent(projectID)
		a.watchState(c)
		a.sendSnapshot(c)
		return
	}
	projects, err := s.store.Projects(ctx)
	if err != nil {
		return
	}
	for _, p := range projects {
		a := s.agent(p.ID)
		a.watchState(c)
		a.sendSnapshot(c)
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

// watchState adds a socket to the sockets told this project's agent state. A socket that has
// closed is dropped on the way.
func (a *projectAgent) watchState(c *client) {
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	for k := range a.stateSubs {
		if closedClient(k) {
			delete(a.stateSubs, k)
		}
	}
	a.stateSubs[c] = struct{}{}
}

func closedClient(c *client) bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

// noteState records a transition to st and sends the notification now or when the gap ends. It
// must be called with a.mu held (setState), so it takes only stateMu, never a.mu.
func (a *projectAgent) noteState(st agentState) {
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	a.stateWant = stateName(st)
	a.stateSince = time.Now()
	if a.stateTimer != nil {
		return // a flush is already due, and it sends the newest state
	}
	if wait := projectStateGap - time.Since(a.stateSentAt); wait > 0 {
		a.stateTimer = time.AfterFunc(wait, a.flushState)
		return
	}
	a.flushStateLocked()
}

// flushState runs when the gap ends: it sends the newest state if it differs from the last one sent.
func (a *projectAgent) flushState() {
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	a.stateTimer = nil
	a.flushStateLocked()
}

// flushStateLocked sends the newest state to the subscribed sockets when it is not the one already
// sent. It must be called with stateMu held.
func (a *projectAgent) flushStateLocked() {
	if a.stateWant == a.stateSent {
		return
	}
	// stateSent starts as "", so the first transition is always sent, whenever the socket listed the
	// project. No state is assumed as the baseline.
	a.stateSent = a.stateWant
	a.stateSentAt = time.Now()
	out := a.stateMessage(a.stateSent, a.stateSince)
	for c := range a.stateSubs {
		if closedClient(c) {
			delete(a.stateSubs, c)
			continue
		}
		c.send(out)
	}
	a.s.audit.Log("project_state", a.fields(audit.Fields{Reason: a.stateSent}))
}

// sendSnapshot sends one socket the project's current agent state (G2, D-104): the state every listing
// call starts from, so a project already running when the phone reconnects is not shown as stopped. A
// project no agent has run for is "stopped". The snapshot is read under stateMu, the lock the change-only
// flush takes, so it is never older than a broadcast sent before it. It does not touch stateSent or
// stateSentAt (the change-only rule and the 2-a-second limit are unchanged), and it is not audited.
func (a *projectAgent) sendSnapshot(c *client) {
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	if closedClient(c) {
		return
	}
	agent := a.stateWant
	if agent == "" {
		agent = stateName(agentStopped) // no transition yet: no agent has run for this project
	}
	since := a.stateSince
	if since.IsZero() {
		since = time.Now()
	}
	c.send(a.stateMessage(agent, since))
}

// stateMessage is the `_agmente/project/state` notification (C2) for one agent state. It must be called
// with stateMu held.
func (a *projectAgent) stateMessage(agent string, since time.Time) []byte {
	params := jsonv.Obj()
	params.Set("projectId", jsonv.Str(a.id))
	params.Set("agent", jsonv.Str(agent))
	params.Set("since", jsonv.Str(since.UTC().Format(projectStateTime)))
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("method", jsonv.Str("_agmente/project/state"))
	msg.Set("params", params)
	return msg.Marshal()
}
