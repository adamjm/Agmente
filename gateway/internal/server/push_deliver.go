package server

import (
	"context"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/push"
)

// pushQueueSize bounds the APNs queue (PLAN 3.11). The agent path only enqueues: when the queue is
// full the push is dropped and audited (push_dropped), so a slow APNs never blocks a turn.
const pushQueueSize = 64

type pushJob struct {
	event     push.Event
	projectID string
	sessionID string
}

// pushDelivery is the APNs sender and its queue (D-053).
type pushDelivery struct {
	client *push.Client
	queue  chan pushJob
}

// SetPush turns APNs delivery on (FR-23, D-053). Call it once, before Serve. Without it nothing is
// queued and no request is made.
func (s *Server) SetPush(c *push.Client) {
	p := &pushDelivery{client: c, queue: make(chan pushJob, pushQueueSize)}
	s.push = p
	go s.pushWorker(s.pushCtx, p)
}

// pushNotify queues a push for a session event. It never blocks and never takes the server lock.
// A session with no id has no payload, so it is skipped.
func (s *Server) pushNotify(event push.Event, projectID, sessionID string) {
	p := s.push
	if p == nil || sessionID == "" {
		return
	}
	select {
	case p.queue <- pushJob{event: event, projectID: projectID, sessionID: sessionID}:
	default:
		s.audit.Log("push_dropped", audit.Fields{Project: projectID, Reason: string(event)})
	}
}

func (s *Server) pushWorker(ctx context.Context, p *pushDelivery) {
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-p.queue:
			s.deliverPush(ctx, p, job)
		}
	}
}

// deliverPush sends one event to every stored token, except a device that has a live subscriber
// on the session right now (FR-23: the app already shows it). An answer that says the token is
// gone or never matched this app deletes that token (PLAN 3.11).
func (s *Server) deliverPush(ctx context.Context, p *pushDelivery, job pushJob) {
	name := ""
	if proj, err := s.store.ProjectByID(ctx, job.projectID); err == nil && proj != nil {
		name = proj.Name
	}
	payload, err := push.Build(job.event, name, job.sessionID)
	if err != nil {
		s.audit.Log("push_failed", audit.Fields{Project: job.projectID, Reason: "payload"})
		return
	}
	tokens, err := s.store.AllPushTokens(ctx)
	if err != nil {
		s.audit.Log("store_error", audit.Fields{Project: job.projectID, Reason: "push_tokens"})
		return
	}
	for _, t := range tokens {
		if ctx.Err() != nil {
			return
		}
		if s.subscribedDevice(job.sessionID, t.Identity, t.Device) {
			continue
		}
		fields := audit.Fields{Identity: t.Identity, Device: t.Device, Project: job.projectID}
		res, err := p.client.Deliver(ctx, t.Token, t.Environment, payload)
		if err != nil {
			s.audit.Log("push_failed", withPushResult(fields, res, "bad_environment"))
			continue
		}
		switch push.Decide(res.Status, res.Reason) {
		case push.Sent:
			fields.Reason = string(job.event)
			fields.Status = res.Status
			s.audit.Log("push_sent", fields)
		case push.RemoveToken:
			s.audit.Log("push_failed", withPushResult(fields, res, ""))
			removed, err := s.store.DeletePushTokenIfEqual(ctx, t.Identity, t.Device, t.Token)
			if err != nil {
				s.audit.Log("store_error", audit.Fields{Identity: t.Identity, Device: t.Device, Reason: "push_tokens"})
			} else if removed {
				s.audit.Log("push_token_removed", withPushResult(fields, res, ""))
			}
		default:
			s.audit.Log("push_failed", withPushResult(fields, res, ""))
		}
	}
}

// withPushResult adds APNs' status and reason to an audit line. A reason of "" keeps APNs' own.
func withPushResult(f audit.Fields, res push.Result, reason string) audit.Fields {
	f.Status = res.Status
	f.Reason = res.Reason
	if reason != "" {
		f.Reason = reason
	}
	return f
}

// subscribedDevice reports whether one of this device's sockets subscribes to the session now.
func (s *Server) subscribedDevice(sessionID, identity, device string) bool {
	s.evMu.Lock()
	defer s.evMu.Unlock()
	for c := range s.subs[sessionID] {
		if c.who.Identity == identity && c.who.Device == device {
			return true
		}
	}
	return false
}
