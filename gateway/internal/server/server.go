// Package server is the HTTP server with admission control before the WebSocket upgrade, and the
// pipe between one authenticated socket and one agent process (ARCHITECTURE 2.1, 2.2).
package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/config"
)

const killGrace = 2 * time.Second

// Server is one gateway.
type Server struct {
	cfg     *config.Config
	audit   *audit.Logger
	limiter *failureLimiter
	roots   []string
	http    *http.Server
	conns   atomic.Int64

	mu          sync.Mutex
	active      int64
	perIdentity map[string]int64
	live        map[*liveConn]struct{}
}

type liveConn struct {
	ws   *websocket.Conn
	proc *agentProcess
}

func New(cfg *config.Config, logger *audit.Logger) *Server {
	s := &Server{
		cfg:   cfg,
		audit: logger,
		limiter: newFailureLimiter(int(cfg.Limits.AuthFailuresPerWindow),
			time.Duration(cfg.Limits.AuthWindowSeconds)*time.Second,
			time.Duration(cfg.Limits.LockoutSeconds)*time.Second),
		roots:       resolveRoots(cfg.Roots),
		perIdentity: map[string]int64{},
		live:        map[*liveConn]struct{}{},
	}
	s.http = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 10 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	return s
}

// Listen binds the configured loopback address.
func (s *Server) Listen() (net.Listener, error) {
	return net.Listen("tcp", net.JoinHostPort(s.cfg.ListenHost, strconv.Itoa(s.cfg.ListenPort)))
}

func (s *Server) Serve(ln net.Listener) error { return s.http.Serve(ln) }

// Shutdown stops accepting, drops every socket and sends SIGTERM to every agent.
func (s *Server) Shutdown() {
	_ = s.http.Close()
	s.mu.Lock()
	live := make([]*liveConn, 0, len(s.live))
	for c := range s.live {
		live = append(live, c)
	}
	s.mu.Unlock()
	for _, c := range live {
		_ = c.ws.CloseNow()
		if c.proc != nil {
			c.proc.terminate(killGrace)
		}
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if isUpgrade(r) {
		s.handleUpgrade(w, r)
		return
	}
	// Plain HTTP: only a health check. It reveals nothing about the agent.
	if r.Method == http.MethodGet && r.RequestURI == "/healthz" {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

func isUpgrade(r *http.Request) bool {
	if r.Header.Get("Upgrade") == "" {
		return false
	}
	for _, value := range r.Header.Values("Connection") {
		for _, token := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
				return true
			}
		}
	}
	return false
}

func reject(w http.ResponseWriter, status int, extra map[string]string) {
	h := w.Header()
	h.Set("Connection", "close")
	h.Set("Content-Length", "0")
	for k, v := range extra {
		h.Set(k, v)
	}
	w.WriteHeader(status)
}

func (s *Server) handleUpgrade(w http.ResponseWriter, r *http.Request) {
	client := clientKey(r, s.cfg.TrustProxy)

	// 1. Browsers always send Origin. A native client does not. Reject browsers (FR-3).
	if _, hasOrigin := r.Header["Origin"]; hasOrigin {
		s.audit.Log("reject", audit.Fields{Client: client, Status: 403, Reason: "origin"})
		reject(w, http.StatusForbidden, nil)
		return
	}
	// 2. Locked-out address (FR-8).
	if s.limiter.isLocked(client) {
		s.audit.Log("reject", audit.Fields{Client: client, Status: 429, Reason: "locked_out"})
		reject(w, http.StatusTooManyRequests, map[string]string{"Retry-After": strconv.FormatInt(s.cfg.Limits.LockoutSeconds, 10)})
		return
	}
	// 3. Token (FR-1).
	entry := findToken(s.cfg.Tokens, r.Header.Get("Authorization"))
	if entry == nil {
		s.limiter.recordFailure(client)
		s.audit.Log("reject", audit.Fields{Client: client, Status: 401, Reason: "token"})
		reject(w, http.StatusUnauthorized, map[string]string{"WWW-Authenticate": "Bearer"})
		return
	}
	// 4. Capacity (FR-5). Reserve the slot before the upgrade so parallel requests cannot pass the cap.
	s.mu.Lock()
	if s.perIdentity[entry.Identity] >= s.cfg.Limits.MaxAgentsPerIdentity || s.active >= s.cfg.Limits.MaxAgentsTotal {
		s.mu.Unlock()
		s.audit.Log("reject", audit.Fields{Identity: entry.Identity, Device: entry.ID, Client: client, Status: 429, Reason: "capacity"})
		reject(w, http.StatusTooManyRequests, map[string]string{"Retry-After": "30"})
		return
	}
	s.active++
	s.perIdentity[entry.Identity]++
	s.mu.Unlock()
	var releaseOnce sync.Once
	release := func() {
		releaseOnce.Do(func() {
			s.mu.Lock()
			s.active--
			s.perIdentity[entry.Identity]--
			s.mu.Unlock()
		})
	}

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		release() // Accept has written the error response
		return
	}
	ws.SetReadLimit(s.cfg.Limits.MaxMessageBytes)
	s.handleConnection(ws, entry, client, release)
}

func (s *Server) handleConnection(ws *websocket.Conn, entry *config.Token, client string, release func()) {
	who := audit.Who{Identity: entry.Identity, Device: entry.ID, Client: client, Conn: int(s.conns.Add(1))}
	with := func(f audit.Fields) audit.Fields {
		f.Identity, f.Device, f.Client, f.Conn = who.Identity, who.Device, who.Client, who.Conn
		return f
	}
	maxBytes := s.cfg.Limits.MaxMessageBytes

	proc, err := startAgent(s.cfg.AgentCommand, s.cfg.EnvPassthrough)
	if err != nil {
		s.audit.Log("agent_error", with(audit.Fields{Reason: spawnErrorReason(err)}))
		release()
		_ = ws.Close(closeAgentExited, "agent failed to start")
		return
	}
	s.audit.Log("connect", with(audit.Fields{Pid: proc.pid()}))

	live := &liveConn{ws: ws, proc: proc}
	s.mu.Lock()
	s.live[live] = struct{}{}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.live, live)
		s.mu.Unlock()
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// After the gateway starts a close, nothing more is forwarded in either direction.
	var closing atomic.Bool
	closeWith := func(code int, reason string) {
		if closing.CompareAndSwap(false, true) {
			go func() { _ = ws.Close(websocket.StatusCode(code), reason) }()
		}
	}
	// The slot is released when the agent exits, not here: a new agent must not start while this
	// one may still be saving to the shared task store (F-21, D-015).
	var finishOnce sync.Once
	finish := func() { finishOnce.Do(func() { proc.terminate(killGrace) }) }

	// Agent -> phone (ARCHITECTURE 2.2). A blocking write is the backpressure: while the phone is
	// slow, the gateway stops reading the agent's stdout, and the agent's pipe fills.
	stdoutDone := make(chan struct{})
	go func() {
		defer close(stdoutDone)
		defer proc.stdout.Close()
		readLines(proc.stdout, maxBytes,
			func(line []byte) {
				if !json.Valid(line) {
					s.audit.Log("agent_noise", with(audit.Fields{}))
					return
				}
				if method, ok := agentMethod(line); ok {
					s.audit.Log("rpc", with(audit.Fields{Dir: "out", Method: method}))
				}
				if closing.Load() {
					return
				}
				if !utf8.Valid(line) {
					line = bytes.ToValidUTF8(line, []byte("�"))
				}
				_ = ws.Write(ctx, websocket.MessageText, line)
			},
			func() {
				s.audit.Log("agent_line_too_big", with(audit.Fields{}))
				closeWith(closeTooBig, "agent message too big")
				finish()
			})
	}()

	go func() {
		<-proc.exited
		// Forward what the agent wrote before it exited (bounded: a grandchild may hold the pipe).
		select {
		case <-stdoutDone:
		case <-time.After(time.Second):
		}
		code, signal := proc.exitInfo()
		s.audit.Log("agent_exit", with(audit.Fields{HasExit: true, ExitCode: code, Signal: signal}))
		release()
		closeWith(closeAgentExited, "agent exited")
		_ = proc.stdin.Close()
	}()

	// Phone -> agent, in order: each message is checked and written before the next is read.
	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			code := int(websocket.CloseStatus(err))
			if code == -1 {
				code = 1006
			}
			s.audit.Log("disconnect", with(audit.Fields{Code: code}))
			break
		}
		// After a violation the socket is closing: nothing queued behind it may reach the agent.
		if closing.Load() {
			continue
		}
		msg, bad := parseClientMessage(data, typ == websocket.MessageText, maxBytes)
		if bad != nil {
			s.audit.Log("protocol_violation", with(audit.Fields{Code: bad.code, Reason: bad.reason}))
			closeWith(bad.code, bad.reason)
			continue
		}
		method, isRequest := msg.Get("method").StringValue()
		if !cwdAllowed(msg, s.roots) {
			s.audit.Log("cwd_rejected", with(audit.Fields{Method: method}))
			if id := msg.Get("id"); !id.IsNull() {
				_ = ws.Write(ctx, websocket.MessageText, cwdRejection(id))
			}
			continue
		}
		if !isRequest {
			method = "response"
		}
		s.audit.Log("rpc", with(audit.Fields{Dir: "in", Method: method}))
		// Re-serialize: exactly one line on the agent's stdin.
		full, _ := proc.writeLine(append(msg.Marshal(), '\n')) // EPIPE after exit is handled by the exit path
		if full {
			s.audit.Log("backpressure", with(audit.Fields{Dir: "in"}))
		}
	}
	cancel()
	finish()
}

// agentMethod returns the "method" of an agent line when it is a JSON object with a string method.
// Key lookup is exact: encoding/json struct fields would also match "METHOD".
func agentMethod(line []byte) (string, bool) {
	if len(line) == 0 || line[0] != '{' {
		trimmed := bytes.TrimLeft(line, " \t")
		if len(trimmed) == 0 || trimmed[0] != '{' {
			return "", false
		}
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(line, &fields) != nil {
		return "", false
	}
	raw, ok := fields["method"]
	if !ok {
		return "", false
	}
	var method string
	if json.Unmarshal(raw, &method) != nil {
		return "", false
	}
	return method, true
}
