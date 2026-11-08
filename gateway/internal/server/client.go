package server

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
)

// client is one authenticated phone socket (D-025). It owns no agent. Everything sent to it goes
// through one queue, so its messages keep their order, and a slow phone never blocks a shared
// agent: when the queue holds more than `limit` bytes, the socket is closed with 1013 and the phone
// reconnects (from phase 3 task 3.6 on, it then replays what it missed from the event log).
type client struct {
	ws      *websocket.Conn
	who     audit.Who
	ctx     context.Context
	out     chan []byte
	done    chan struct{}
	drained chan struct{} // signalled after each write, for sendWait
	queued  atomic.Int64
	limit   int64
	closing atomic.Bool
	onSlow  func()

	mu          sync.Mutex
	lastProject *projectAgent
}

const clientQueueMessages = 4096

func newClient(ctx context.Context, ws *websocket.Conn, who audit.Who, maxMessageBytes int64, onSlow func()) *client {
	c := &client{
		ws: ws, who: who, ctx: ctx,
		out:     make(chan []byte, clientQueueMessages),
		done:    make(chan struct{}),
		drained: make(chan struct{}, 1),
		limit:   2*maxMessageBytes + 1<<20,
		onSlow:  onSlow,
	}
	go c.writeLoop()
	return c
}

func (c *client) writeLoop() {
	for {
		select {
		case b := <-c.out:
			_ = c.ws.Write(c.ctx, websocket.MessageText, b)
			c.queued.Add(-int64(len(b)))
			select {
			case c.drained <- struct{}{}:
			default:
			}
		case <-c.done:
			return
		}
	}
}

// send queues one message. It never blocks.
func (c *client) send(b []byte) {
	if c.closing.Load() {
		return
	}
	if c.queued.Add(int64(len(b))) > c.limit {
		c.slow()
		return
	}
	select {
	case c.out <- b:
	default:
		c.slow()
	}
}

// sendWait queues one replayed message. It waits while the queue is over half its byte or message
// limit, so a long replay neither closes a slow phone with 1013 nor crowds out live messages
// (D-028). It returns false when the socket is closing or ctx ends.
func (c *client) sendWait(ctx context.Context, b []byte) bool {
	for c.queued.Load()+int64(len(b)) > c.limit/2 || len(c.out) > cap(c.out)/2 {
		if c.closing.Load() {
			return false
		}
		select {
		case <-c.drained:
		case <-ctx.Done():
			return false
		case <-c.done:
			return false
		}
	}
	c.send(b)
	return !c.closing.Load()
}

func (c *client) slow() {
	if c.closing.Load() {
		return
	}
	c.onSlow()
	c.closeWith(1013, "client too slow")
}

// closeWith starts a close handshake once. After it, nothing more is sent or forwarded.
func (c *client) closeWith(code int, reason string) {
	if c.closing.CompareAndSwap(false, true) {
		go func() { _ = c.ws.Close(websocket.StatusCode(code), reason) }()
	}
}

func (c *client) setProject(a *projectAgent) {
	c.mu.Lock()
	c.lastProject = a
	c.mu.Unlock()
}

func (c *client) project() *projectAgent {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastProject
}
