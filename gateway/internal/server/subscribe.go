package server

// Subscribe and replay (FR-19, NFR-6, PLAN 3.6, D-028).
//
// Every logged session event goes through emit, which holds evMu while it appends the event and
// delivers it. A subscribe registers its listener and reads the head seq under the same lock, so
// each event is either at or below the head (and read by the replay) or above it (and delivered
// live), never both and never neither. Live events that arrive during the replay wait in the
// subscription and are sent after it, so a phone sees seq afterSeq+1, afterSeq+2, ... in order.

import (
	"context"
	"strconv"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

// replayPage is how many events the replay reads per query. The store has one connection, so a
// page is read into memory and the connection released before the events are sent: a slow phone
// never holds up the event log.
const replayPage = 512

type subscription struct {
	c         *client
	sid       string
	cancel    context.CancelFunc
	plain     bool     // a reopened session for a phone that does not subscribe (D-029)
	project   string   // keeps the project running while the socket subscribes (FR-45)
	replaying bool     // guarded by Server.evMu
	pending   [][]byte // live events that arrived during the replay
	pendingN  int64
}

// deliver sends one live event. It must be called with evMu held.
func (sub *subscription) deliver(note []byte) {
	if !sub.replaying {
		sub.c.send(note)
		return
	}
	sub.pending = append(sub.pending, note)
	sub.pendingN += int64(len(note))
	if sub.pendingN > sub.c.limit {
		sub.c.slow()
	}
}

// eventNotification wraps a logged message: `_agmente/event {sessionId, seq, message}`.
func eventNotification(sessionID string, seq int64, message []byte) []byte {
	b := make([]byte, 0, len(message)+len(sessionID)+80)
	b = append(b, `{"jsonrpc":"2.0","method":"_agmente/event","params":{"sessionId":`...)
	b = jsonv.AppendString(b, sessionID)
	b = append(b, `,"seq":`...)
	b = strconv.AppendInt(b, seq, 10)
	b = append(b, `,"message":`...)
	b = append(b, message...)
	return append(b, `}}`...)
}

// emit logs one session event, then delivers it: as `_agmente/event` to the session's
// subscribers, and as the plain message to each socket in raw that is not subscribed to the
// session. The event is committed before anything is sent (D-027). If the write fails, the raw
// sockets still get the message, but subscribers do not: the event has no seq.
func (s *Server) emit(projectID, sessionID, kind string, message []byte, raw []*client) {
	s.evMu.Lock()
	defer s.evMu.Unlock()
	subs := s.subs[sessionID]
	seq, err := s.store.AppendEvent(context.Background(), sessionID, kind, message)
	if err != nil {
		s.audit.Log("store_error", audit.Fields{Project: projectID, Reason: "append_event"})
	}
	var note []byte
	for _, sub := range subs {
		switch {
		case sub.plain:
			if plainKind(kind) {
				sub.deliver(message)
			}
		case err == nil:
			if note == nil {
				note = eventNotification(sessionID, seq, message)
			}
			sub.deliver(note)
		}
	}
	for _, c := range raw {
		if subs[c] == nil {
			c.send(message)
		}
	}
}

// subscribe handles `_agmente/sessions/subscribe {sessionId, afterSeq}`. It answers `{headSeq}`
// first, then replays the events after afterSeq up to headSeq, then streams live events. A second
// subscribe from the same socket for the same session replaces the first.
func (s *Server) subscribe(c *client, id, params *jsonv.Value) {
	reply := func(result any, rerr *rpcError) {
		if rerr != nil {
			c.send(rpcErrorResponse(id, rerr))
		} else {
			c.send(rpcResult(id, result))
		}
	}
	sid, _ := params.Get("sessionId").StringValue()
	if sid == "" {
		reply(nil, invalidParams("sessionId is required"))
		return
	}
	var after int64
	if v := params.Get("afterSeq"); !v.IsNull() {
		n, ok := v.Int()
		if !ok || n < 0 || v.Kind != jsonv.Number {
			reply(nil, invalidParams("afterSeq must be a non-negative integer"))
			return
		}
		after = n
	}
	pid, err := s.store.SessionProject(c.ctx, sid)
	if err != nil {
		reply(nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"})
		return
	}
	if pid == "" {
		reply(nil, invalidParams("unknown session"))
		return
	}

	ctx, cancel := context.WithCancel(c.ctx)
	sub := &subscription{c: c, sid: sid, cancel: cancel, replaying: true, project: pid}
	s.evMu.Lock()
	head, err := s.store.HeadSeq(ctx, sid)
	if err != nil {
		s.evMu.Unlock()
		cancel()
		reply(nil, &rpcError{Code: rpcInternal, Message: "cannot read events"})
		return
	}
	set := s.subs[sid]
	if set == nil {
		set = map[*client]*subscription{}
		s.subs[sid] = set
	}
	if old := set[c]; old != nil {
		old.cancel()
	}
	set[c] = sub
	// Queued under the lock, so it precedes every event of this subscription.
	reply(map[string]any{"headSeq": head}, nil)
	s.evMu.Unlock()
	s.audit.Log("subscribe", with(c.who, audit.Fields{Project: pid}))

	go s.replay(ctx, sub, after, head)
}

func (s *Server) replay(ctx context.Context, sub *subscription, after, head int64) {
	c := sub.c
	for cur := after; cur < head; {
		upTo := min(cur+replayPage, head)
		batch := make([][]byte, 0, upTo-cur)
		err := s.store.EventsAfter(ctx, sub.sid, cur, upTo, func(e store.Event) error {
			if sub.plain {
				batch = append(batch, s.history(e)...)
			} else {
				batch = append(batch, eventNotification(sub.sid, e.Seq, []byte(e.Message)))
			}
			return nil
		})
		if err != nil {
			if ctx.Err() == nil {
				s.audit.Log("store_error", with(c.who, audit.Fields{Reason: "replay"}))
				c.closeWith(1011, "replay failed") // the phone resubscribes; a gap is never left open
			}
			return
		}
		for _, b := range batch {
			if !c.sendWait(ctx, b) {
				return
			}
		}
		cur = upTo
	}
	s.evMu.Lock()
	defer s.evMu.Unlock()
	if s.subs[sub.sid][c] != sub {
		return // replaced or closed
	}
	for _, b := range sub.pending {
		c.send(b)
	}
	sub.pending, sub.pendingN, sub.replaying = nil, 0, false
}

// unsubscribeAll drops every subscription of a closed socket.
func (s *Server) unsubscribeAll(c *client) {
	s.evMu.Lock()
	defer s.evMu.Unlock()
	for sid, set := range s.subs {
		if sub := set[c]; sub != nil {
			sub.cancel()
			delete(set, c)
			if len(set) == 0 {
				delete(s.subs, sid)
			}
		}
	}
}

// plainKind reports whether a socket that does not subscribe gets events of this kind as they
// happen: the agent's messages do, the gateway's turn markers do not.
func plainKind(kind string) bool {
	return kind == "update" || kind == "notification" || kind == "permission_request"
}

// reopenLive answers a load or resume for a session that is live in the agent, which never sees it
// (FR-20, D-029). The response is the agent's cached result. Then, as the agent would, the gateway
// sends the session's history to that socket: the logged events as plain messages (history), then
// live ones. A socket subscribed to the session already has the events and gets only the response.
func (s *Server) reopenLive(a *projectAgent, c *client, id *jsonv.Value, sid, method string, result []byte) {
	resp := []byte(`{"jsonrpc":"2.0","id":`)
	resp = id.AppendTo(resp)
	resp = append(resp, `,"result":`...)
	resp = append(resp, result...)
	resp = append(resp, '}')
	s.audit.Log("reopen_answered", with(c.who, audit.Fields{Method: method, Project: a.id}))

	s.evMu.Lock()
	set := s.subs[sid]
	if old := set[c]; old != nil && !old.plain {
		c.send(resp)
		s.evMu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(c.ctx)
	head, err := s.store.HeadSeq(ctx, sid)
	if err != nil {
		s.evMu.Unlock()
		cancel()
		c.send(rpcErrorResponse(id, &rpcError{Code: rpcInternal, Message: "cannot read events"}))
		return
	}
	if set == nil {
		set = map[*client]*subscription{}
		s.subs[sid] = set
	}
	if old := set[c]; old != nil {
		old.cancel()
	}
	sub := &subscription{c: c, sid: sid, cancel: cancel, plain: true, replaying: true, project: a.id}
	set[c] = sub
	c.send(resp)
	s.evMu.Unlock()
	go s.replay(ctx, sub, 0, head)
}

// history turns one logged event into what an agent replays after a load: a turn's prompt becomes
// user_message_chunk updates (Bob does not echo prompts, so the log has them only here), agent
// messages are sent as they were, a permission request only while it is still unanswered, and the
// gateway's turn markers not at all.
func (s *Server) history(e store.Event) [][]byte {
	switch e.Kind {
	case "update", "notification":
		return [][]byte{[]byte(e.Message)}
	case "permission_request":
		msg, err := jsonv.Parse([]byte(e.Message))
		if err != nil {
			return nil
		}
		key, _ := msg.Get("id").StringValue()
		s.permMu.Lock()
		open := s.perms[key] != nil
		s.permMu.Unlock()
		if open {
			return [][]byte{[]byte(e.Message)}
		}
	case "turn_started":
		msg, err := jsonv.Parse([]byte(e.Message))
		if err != nil {
			return nil
		}
		var out [][]byte
		prompt := msg.Get("params").Get("prompt")
		if prompt == nil {
			return nil
		}
		for _, block := range prompt.Arr {
			u := jsonv.Obj()
			u.Set("sessionUpdate", jsonv.Str("user_message_chunk"))
			u.Set("content", block)
			params := jsonv.Obj()
			params.Set("sessionId", jsonv.Str(e.SessionID))
			params.Set("update", u)
			note := jsonv.Obj()
			note.Set("jsonrpc", jsonv.Str("2.0"))
			note.Set("method", jsonv.Str("session/update"))
			note.Set("params", params)
			out = append(out, note.Marshal())
		}
		return out
	}
	return nil
}
