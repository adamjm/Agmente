package server

// The per-message crash guard (D-033). net/http recovers a panic in a connection's goroutine, but
// a WebSocket handler that panics leaves its socket open with nobody reading it, so the phone
// waits for an answer that never comes. guardMessage turns a panic while handling one phone
// message into an error answer and a closed socket: the phone gets -32603 for that request, then
// close 1011, and reconnects. The rest of the gateway keeps running.
//
// Limit: a panic while a lock is held leaves that lock held. Every lock in this package is taken
// and released around short sections, mostly with defer; a panic inside one would still stall the
// paths that need the lock. The guard does not and cannot repair that.

import (
	"fmt"
	"time"

	"github.com/coder/websocket"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
)

// panicHook, when set (unit tests only), runs before each phone message is handled.
var panicHook func(method string)

const closeInternalError = 1011

func (s *Server) guardMessage(c *client, data []byte, handle func()) {
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		// The method and id come from a fresh parse: the handler's own values may be half-built.
		// Only the method name and the panic's type are logged, never message content.
		method, id := "", (*jsonv.Value)(nil)
		if msg, err := jsonv.Parse(data); err == nil && msg.Kind == jsonv.Object {
			method, _ = msg.Get("method").StringValue()
			id = msg.Get("id")
		}
		s.audit.Log("panic", with(c.who, audit.Fields{Method: method, Reason: fmt.Sprintf("%T", r)}))
		if method != "" && !id.IsNull() {
			c.send(rpcErrorResponse(id, &rpcError{Code: rpcInternal, Message: "internal error"}))
		}
		c.closeAfterDrain(closeInternalError, "internal error")
	}()
	if panicHook != nil {
		method := ""
		if msg, err := jsonv.Parse(data); err == nil {
			method, _ = msg.Get("method").StringValue()
		}
		panicHook(method)
	}
	handle()
}

// closeAfterDrain stops all further sends now, then closes the socket once what is already queued
// has been written (at most 1 s), so a final error answer reaches the phone before the close.
func (c *client) closeAfterDrain(code int, reason string) {
	if !c.closing.CompareAndSwap(false, true) {
		return
	}
	go func() {
		deadline := time.After(time.Second)
		for c.queued.Load() > 0 {
			select {
			case <-c.drained:
			case <-deadline:
				_ = c.ws.Close(websocket.StatusCode(code), reason)
				return
			case <-c.done:
				return
			}
		}
		_ = c.ws.Close(websocket.StatusCode(code), reason)
	}()
}
