// Package server is the HTTP server with admission control before the WebSocket upgrade, and the
// router between authenticated sockets and one agent per project (ARCHITECTURE 2.1 to 2.3, D-025).
package server

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/connector"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

const killGrace = 2 * time.Second

// Version is the gateway version reported in initialize (D-026).
const Version = "0.3.0-dev"

// extensions lists the _acpcode/* method groups this gateway serves (D-026).
var extensions = []string{"projects", "sessions", "approvals", "git", "push", "files"}

//go:embed default-initialize.json
var defaultInitialize []byte // Bob 2.0.9's initialize result (F-11), until an agent has started

// Server is one gateway.
type Server struct {
	uploads uploadLocks // one upload in flight per project (D-115)
	cfg     *config.Config
	audit   *audit.Logger
	store   *store.Store
	runner  runner
	limiter *failureLimiter
	roots   []string
	http    *http.Server
	conns   atomic.Int64
	// connector is the remote connector's listener (D-095). Disabled by default: no listener starts.
	connector *connector.Connector

	mu          sync.Mutex
	perIdentity map[string]int64 // open sockets per identity
	clients     map[*client]struct{}
	agents      map[string]*projectAgent // by project id
	agentSlots  int64                    // starting, running or stopping agents

	permMu  sync.Mutex
	perms   map[string]*permission // gateway permission id -> agent request
	closing map[string]string      // approvals taken but not yet recorded: id -> who closed them
	permSeq int64
	elics   map[string]*elicitation // elicitations relayed to phones (FR-44), by gateway id; guarded by permMu

	capsMu sync.Mutex
	caps   []byte // the agent's last initialize result

	evMu sync.Mutex                           // held while an event is logged and delivered (subscribe.go)
	subs map[string]map[*client]*subscription // session id -> socket -> subscription

	push       *pushDelivery // APNs delivery; nil when the push block is absent (push_deliver.go)
	pushCtx    context.Context
	pushCancel context.CancelFunc

	snaps   turnSnapshots // turn snapshots in progress (snapshot.go)
	gits    gitStates     // the last git/status of each project: the diff allow-list (git.go)
	watches gitWatches    // projects whose git status is being watched (watch.go)

	revokedMu sync.Mutex      // guards revoked
	revoked   map[string]bool // token ids refused at every upgrade and request (token_revoke.go)
}

func New(cfg *config.Config, logger *audit.Logger, db *store.Store) *Server {
	s := &Server{
		cfg:    cfg,
		audit:  logger,
		store:  db,
		runner: newRunner(cfg),
		limiter: newFailureLimiter(int(cfg.Limits.AuthFailuresPerWindow),
			time.Duration(cfg.Limits.AuthWindowSeconds)*time.Second,
			time.Duration(cfg.Limits.LockoutSeconds)*time.Second),
		roots:       resolveRoots(cfg.Roots),
		perIdentity: map[string]int64{},
		clients:     map[*client]struct{}{},
		agents:      map[string]*projectAgent{},
		perms:       map[string]*permission{},
		closing:     map[string]string{},
		elics:       map[string]*elicitation{},
		subs:        map[string]map[*client]*subscription{},
		caps:        defaultInitialize,
	}
	s.initApprovals()
	s.connector = connector.New(connector.Options{
		Config: cfg.Connector, StateDir: cfg.StateDir, Version: Version, Audit: logger,
		Projects: func(ctx context.Context) ([]string, error) {
			ps, err := db.Projects(ctx)
			ids := make([]string, 0, len(ps))
			for _, p := range ps {
				ids = append(ids, p.ID)
			}
			return ids, err
		},
		SessionProject: db.SessionProject,
		Gateway:        &connectorBridge{s: s}, // the connector tools' reads and prompts (D-096)
	})
	s.pushCtx, s.pushCancel = context.WithCancel(context.Background())
	if data, err := os.ReadFile(s.capsPath()); err == nil {
		if v, err := jsonv.Parse(data); err == nil && v.Kind == jsonv.Object {
			s.caps = data
		}
	}
	s.http = &http.Server{
		Handler:           s,
		ReadHeaderTimeout: 10 * time.Second,
		MaxHeaderBytes:    16 * 1024,
	}
	// A secrets-file name that envPassthrough does not list is ignored; say so, by name only (PLAN 4.2).
	for _, name := range cfg.SecretsIgnored {
		s.audit.Log("secret_ignored", audit.Fields{Reason: name})
	}
	return s
}

// Listen binds the configured loopback address.
func (s *Server) Listen() (net.Listener, error) {
	ln, err := net.Listen("tcp", net.JoinHostPort(s.cfg.ListenHost, strconv.Itoa(s.cfg.ListenPort)))
	if err != nil {
		return nil, err
	}
	if err := s.connector.Listen(); err != nil { // the connector listener, when enabled (D-095)
		_ = ln.Close()
		return nil, err
	}
	return ln, nil
}

func (s *Server) Serve(ln net.Listener) error {
	s.connector.Start() // no-op unless the connector is enabled
	return s.http.Serve(ln)
}

// Shutdown stops accepting, drops every socket, and stops every agent and waits for it to exit
// (up to the kill grace), so no agent outlives the gateway by more than that.
func (s *Server) Shutdown() {
	s.pushCancel()
	s.connector.Close()
	_ = s.http.Close()
	s.mu.Lock()
	clients := make([]*client, 0, len(s.clients))
	for c := range s.clients {
		clients = append(clients, c)
	}
	agents := make([]*projectAgent, 0, len(s.agents))
	for _, a := range s.agents {
		agents = append(agents, a)
	}
	s.mu.Unlock()
	for _, c := range clients {
		_ = c.ws.CloseNow()
	}
	var wg sync.WaitGroup
	for _, a := range agents {
		a.mu.Lock()
		proc := a.proc
		a.mu.Unlock()
		if proc == nil {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.stop(proc)
			select {
			case <-proc.exited:
			case <-time.After(killGrace + time.Second):
			}
		}()
	}
	wg.Wait()
}

func (s *Server) agent(projectID string) *projectAgent {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.agents[projectID]
	if a == nil {
		a = newProjectAgent(s, projectID)
		s.agents[projectID] = a
	}
	return a
}

func (s *Server) takeAgentSlot() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.agentSlots >= s.cfg.Limits.MaxAgentsTotal {
		return false
	}
	s.agentSlots++
	return true
}

func (s *Server) releaseAgentSlot() {
	s.mu.Lock()
	s.agentSlots--
	s.mu.Unlock()
}

func (s *Server) capsPath() string { return filepath.Join(s.cfg.StateDir, "agent-initialize.json") }

// captureCapabilities keeps the agent's initialize result for the next phone initialize.
func (s *Server) captureCapabilities(result *jsonv.Value) {
	data := result.Marshal()
	s.capsMu.Lock()
	s.caps = data
	s.capsMu.Unlock()
	tmp := s.capsPath() + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, s.capsPath())
	}
}

// initializeResult is the gateway's answer to a phone's initialize: the agent's capabilities plus
// _meta["acpcode/gateway"] (D-026). The phone's initialize never reaches an agent.
func (s *Server) initializeResult() *jsonv.Value {
	s.capsMu.Lock()
	data := s.caps
	s.capsMu.Unlock()
	v, err := jsonv.Parse(data)
	if err != nil || v.Kind != jsonv.Object {
		v, _ = jsonv.Parse(defaultInitialize)
	}
	exts := &jsonv.Value{Kind: jsonv.Array}
	for _, e := range extensions {
		exts.Arr = append(exts.Arr, jsonv.Str(e))
	}
	gw := jsonv.Obj()
	gw.Set("version", jsonv.Str(Version))
	gw.Set("extensions", exts)
	meta := v.Get("_meta")
	if meta == nil || meta.Kind != jsonv.Object {
		meta = jsonv.Obj()
		v.Set("_meta", meta)
	}
	meta.Set("acpcode/gateway", gw)
	return v
}

// projectForCwd returns the registered project whose path is the cwd or contains it (the deepest
// one), or nil. cwd has passed the guard, so it is absolute and inside a root.
func (s *Server) projectForCwd(ctx context.Context, cwd string) (*store.Project, error) {
	real, err := realpath(cwd)
	if err != nil {
		return nil, nil
	}
	projects, err := s.store.Projects(ctx)
	if err != nil {
		return nil, err
	}
	var best *store.Project
	for i := range projects {
		p := &projects[i]
		if (real == p.Path || strings.HasPrefix(real, p.Path+string(filepath.Separator))) && (best == nil || len(p.Path) > len(best.Path)) {
			best = p
		}
	}
	return best, nil
}

// route picks the project for a phone message: by sessionId when the gateway knows the session,
// else by cwd, else the project this socket used last (D-025).
func (s *Server) route(ctx context.Context, c *client, msg *jsonv.Value, method string) (*projectAgent, *rpcError) {
	params := msg.Get("params")
	sid, _ := params.Get("sessionId").StringValue()
	cwd, _ := params.Get("cwd").StringValue()
	internal := &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	var byCwd *store.Project
	if cwd != "" {
		p, err := s.projectForCwd(ctx, cwd)
		if err != nil {
			return nil, internal
		}
		byCwd = p
	}
	if sid != "" {
		pid, err := s.store.SessionProject(ctx, sid)
		if err != nil {
			return nil, internal
		}
		if pid != "" {
			if byCwd != nil && byCwd.ID != pid {
				return nil, invalidParams("the session belongs to another project")
			}
			return s.agent(pid), nil
		}
	}
	if byCwd != nil {
		return s.agent(byCwd.ID), nil
	}
	switch {
	case cwd != "":
		return nil, invalidParams("cwd is not inside a registered project")
	case method == "session/new":
		return nil, invalidParams("session/new needs a cwd inside a registered project")
	case sid != "":
		return nil, invalidParams("unknown session")
	}
	if a := c.project(); a != nil {
		return a, nil
	}
	return nil, invalidParams("no project: send a cwd inside a registered project or a sessionId")
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// The files host serves signed files only, and never the ACP socket (D-061, ARCHITECTURE 2.5).
	if s.isFilesHost(r) {
		if isUpgrade(r) {
			s.audit.Log("reject", audit.Fields{Client: clientKey(r, s.cfg.TrustProxy), Status: 403, Reason: "files_host"})
			reject(w, http.StatusForbidden, nil)
			return
		}
		s.serveFile(w, r)
		return
	}
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
	// 3b. A revoked token is refused at every upgrade (token_revoke.go). It is a real token, so no
	// failure is counted against the address.
	if s.isRevoked(entry.ID) {
		s.audit.Log("reject", audit.Fields{Identity: entry.Identity, Device: entry.ID, Client: client, Status: 401, Reason: "token_revoked"})
		reject(w, http.StatusUnauthorized, map[string]string{"WWW-Authenticate": "Bearer"})
		return
	}
	// 4. Connections per identity (FR-5, D-025). Reserve before the upgrade so parallel requests
	// cannot pass the cap. No agent starts here: agents start per project, on a routed request.
	s.mu.Lock()
	if s.perIdentity[entry.Identity] >= s.cfg.Limits.MaxConnectionsPerIdentity {
		s.mu.Unlock()
		s.audit.Log("reject", audit.Fields{Identity: entry.Identity, Device: entry.ID, Client: client, Status: 429, Reason: "capacity"})
		reject(w, http.StatusTooManyRequests, map[string]string{"Retry-After": "30"})
		return
	}
	s.perIdentity[entry.Identity]++
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.perIdentity[entry.Identity]--
		s.mu.Unlock()
	}()

	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return // Accept has written the error response
	}
	ws.SetReadLimit(s.cfg.Limits.MaxMessageBytes)
	s.handleConnection(ws, entry, client, connectionSecure(r, s.cfg.TrustProxy))
}

// handleConnection serves one admitted socket. secure says whether the connection may carry a git
// credential (D-105); it is checked where the credential is set, not here.
func (s *Server) handleConnection(ws *websocket.Conn, entry *config.Token, clientAddr string, secure bool) {
	who := audit.Who{Identity: entry.Identity, Device: entry.ID, Client: clientAddr, Conn: int(s.conns.Add(1)), Scope: entry.Scope, Secure: secure}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := newClient(ctx, ws, who, s.cfg.Limits.MaxMessageBytes, func() { s.audit.Log("client_slow", with(who, audit.Fields{})) })
	s.audit.Log("connect", with(who, audit.Fields{}))

	s.mu.Lock()
	s.clients[c] = struct{}{}
	s.mu.Unlock()
	defer func() {
		close(c.done)
		left := s.unsubscribeAll(c)
		s.mu.Lock()
		delete(s.clients, c)
		agents := make([]*projectAgent, 0, len(s.agents))
		for _, a := range s.agents {
			agents = append(agents, a)
		}
		s.mu.Unlock()
		for _, a := range agents {
			a.detach(c) // the agents keep running (D-025)
			a.touchSessions(left)
		}
	}()

	reply := func(id *jsonv.Value, result any, rerr *rpcError) {
		if id.IsNull() {
			return
		}
		if rerr != nil {
			c.send(rpcErrorResponse(id, rerr))
		} else {
			c.send(rpcResult(id, result))
		}
	}

	// Phone -> gateway, in order: each message is checked and routed before the next is read.
	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			code := int(websocket.CloseStatus(err))
			if errors.Is(err, websocket.ErrMessageTooBig) {
				code = closeTooBig
			} else if code == -1 {
				code = 1006
			}
			s.audit.Log("disconnect", with(who, audit.Fields{Code: code}))
			// Finish the close handshake. For a message over the cap the library has already sent
			// 1009; Close then reads (and drops) the rest of the frame and waits for the peer's
			// close, so a TCP reset cannot discard the 1009 frame. The socket owns no agent, so
			// nothing else would close it (D-025).
			if code == closeTooBig {
				_ = ws.Close(closeTooBig, "message too big")
			} else {
				_ = ws.Close(websocket.StatusNormalClosure, "")
			}
			return
		}
		// After a violation the socket is closing: nothing queued behind it may reach an agent.
		if c.closing.Load() {
			continue
		}
		s.guardMessage(c, data, func() { s.handleMessage(ctx, c, typ, data, reply) })

	}
}

// handleMessage checks and routes one phone message.
func (s *Server) handleMessage(ctx context.Context, c *client, typ websocket.MessageType, data []byte, reply func(*jsonv.Value, any, *rpcError)) {
	who := c.who
	maxBytes := s.cfg.Limits.MaxMessageBytes
	msg, bad := parseClientMessage(data, typ == websocket.MessageText, maxBytes)
	if bad != nil {
		s.audit.Log("protocol_violation", with(who, audit.Fields{Code: bad.code, Reason: bad.reason}))
		c.closeWith(bad.code, bad.reason)
		return
	}
	method, hasMethod := msg.Get("method").StringValue()
	id := msg.Get("id")
	if s.isRevoked(who.Device) {
		// A token revoked since the socket opened: its next message closes the socket (token_revoke.go).
		s.audit.Log("token_revoked", with(who, audit.Fields{Method: method}))
		c.closeWith(revokedClosedCode, "token revoked")
		return
	}
	if !cwdAllowed(msg, s.roots) {
		s.audit.Log("cwd_rejected", with(who, audit.Fields{Method: method}))
		if !id.IsNull() {
			c.send(cwdRejection(id))
		}
		return
	}
	// The token's scope (scope.go). A refused response (a permission answer) is dropped with no reply.
	if rerr := scopeDenial(who.Scope, method, msg.Get("params")); rerr != nil {
		s.audit.Log("scope_denied", with(who, audit.Fields{Method: method, Reason: "not in the token's scope"}))
		if hasMethod && !id.IsNull() {
			reply(id, nil, rerr)
		}
		return
	}
	switch {
	case !hasMethod:
		// A response: the only requests the gateway forwards to phones are permission requests.
		if !id.IsNull() {
			s.answerPermission(c, msg, id)
		}
		return
	case strings.HasPrefix(method, "_acpcode/"):
		// Gateway extension methods are answered here and never reach an agent (D-002, D-024).
		s.audit.Log("rpc", with(who, audit.Fields{Dir: "in", Method: method}))
		if method == "_acpcode/sessions/subscribe" && !id.IsNull() {
			s.subscribe(c, id, msg.Get("params"))
			return
		}
		if (method == "_acpcode/sessions/create" || method == "_acpcode/sessions/prompt") && !id.IsNull() {
			// Each waits for the agent, so it runs in its own goroutine (sessions_create.go).
			if method == "_acpcode/sessions/create" {
				go s.serveCreate(who, id, msg.Get("params"), reply)
			} else {
				go s.servePrompt(who, id, msg.Get("params"), reply)
			}
			return
		}
		if strings.HasPrefix(method, "_acpcode/connector/") { // the phone's pairing and grant methods (C5, D-095)
			if !id.IsNull() {
				result, cerr := s.connector.Phone(ctx, who, method, msg.Get("params"))
				if cerr != nil {
					reply(id, nil, &rpcError{Code: cerr.Code, Message: cerr.Message})
				} else {
					reply(id, result, nil)
				}
			}
			return
		}
		if method == "_acpcode/sessions/stop" && !id.IsNull() {
			// Stopping can wait for the agent (D-106): answer from a goroutine, as git requests do.
			go s.serveStop(ctx, who, id, msg.Get("params"), reply)
			return
		}
		if strings.HasPrefix(method, "_acpcode/git/") {
			// git runs in a container and can take seconds: answer from a goroutine so the socket's
			// other requests are not held up. A panic here is answered like any other (D-033).
			params := msg.Get("params")
			go s.serveGit(ctx, c, who, method, id, params, reply)
			return
		}
		if !id.IsNull() {
			result, rerr := s.handleExtension(ctx, who, method, msg.Get("params"))
			reply(id, result, rerr)
		}
		return
	case method == "initialize":
		s.audit.Log("rpc", with(who, audit.Fields{Dir: "in", Method: method}))
		reply(id, s.initializeResult(), nil)
		return
	}

	if mcpMethods[method] {
		// The phone's MCP list is checked before routing, so a refused list reaches no agent (D-084).
		if rerr := s.checkMCPList(who, method, msg.Get("params")); rerr != nil {
			reply(id, nil, rerr)
			return
		}
	}
	a, rerr := s.route(ctx, c, msg, method)
	if rerr != nil {
		s.audit.Log("route_refused", with(who, audit.Fields{Method: method, Reason: rerr.Message}))
		reply(id, nil, rerr)
		return
	}
	c.setProject(a)
	s.audit.Log("rpc", with(who, audit.Fields{Dir: "in", Method: method, Project: a.id}))
	sid, _ := msg.Get("params").Get("sessionId").StringValue()
	reopen := ""
	if method == "session/load" || method == "session/resume" {
		reopen = sid
	}
	if method == "session/load" || method == "session/resume" || method == "session/new" {
		sid = "" // attached when the agent's response succeeds
	}
	if rerr := a.forward(c, msg, method, !id.IsNull(), sid, reopen); rerr != nil {
		reply(id, nil, rerr)
	}
}

// serveGit answers one _acpcode/git/* request. A successful git/status also adds the socket to the
// project's watchers, so it is told when the status changes (FR-27, D-037).
func (s *Server) serveGit(ctx context.Context, c *client, who audit.Who, method string, id *jsonv.Value, params *jsonv.Value,
	reply func(*jsonv.Value, any, *rpcError)) {
	defer func() {
		if r := recover(); r != nil {
			s.audit.Log("panic", with(who, audit.Fields{Method: method, Reason: fmt.Sprintf("%T", r)}))
			reply(id, nil, &rpcError{Code: rpcInternal, Message: "internal error"})
		}
	}()
	if id.IsNull() {
		return
	}
	var baseline uint64
	if method == "_acpcode/git/status" {
		baseline = s.watchBaseline(ctx, params) // before git runs (D-037, D-065)
	}
	result, rerr := s.handleExtension(ctx, who, method, params)
	if rerr == nil && method == "_acpcode/git/status" {
		if m, ok := result.(map[string]any); ok {
			if hash, ok := m["hash"].(string); ok {
				if pid, ok := params.Get("projectId").StringValue(); ok {
					s.watchGit(c, pid, hash, baseline)
				}
			}
		}
	}
	reply(id, result, rerr)
}
