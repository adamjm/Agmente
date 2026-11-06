package server

// One agent per project, independent of sockets (FR-16, FR-45, D-015, D-025).
//
// A project's agent starts on the first request routed to the project. All sockets share it. The
// gateway gives every forwarded request its own agent-side id and maps the response back to the
// socket and id it came from. A replacement starts only after the old process has exited, and the
// runner holds the project's lock for as long as the process runs, so two agents never share a
// task store (F-21).

import (
	"context"
	"errors"
	"strconv"
	"sync"
	"time"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const agentStartTimeout = 60 * time.Second

const rpcAgentUnavailable = -32000

type agentState int

const (
	agentStopped agentState = iota
	agentStarting
	agentRunning
	agentStopping
)

type pendingRequest struct {
	c       *client      // nil for the gateway's own requests
	id      *jsonv.Value // the id the socket used
	method  string
	session string            // load and resume: the session to record on success
	turn    string            // session/prompt: the session whose turn this is (event log, D-027)
	sid     string            // set_mode, delete and close: the session they change
	modeID  string            // set_mode: the mode asked for
	reload  *reload           // a load or resume the gateway let through after a restart (FR-20)
	fence   *reload           // the gateway's session/list that ends that load's replay window
	reply   chan *jsonv.Value // the gateway's own requests
}

// liveSession is a session open in the current agent process (FR-20, D-029). result is what the
// agent answered when the session was created or loaded, kept current for modes, so the gateway can
// answer a later load or resume itself.
type liveSession struct {
	result *jsonv.Value
}

// reload is a load or resume forwarded to the agent for a session that is not live. After a
// successful response the agent replays the session's history: those updates go to the requesting
// socket only and are not logged. The gateway then sends a fence (session/list, read-only): the
// agent writes the replay before it answers the next request (verify against Bob), so the fence's
// answer ends the window. Until then, other requests for the session wait (D-029).
type reload struct {
	c    *client
	done chan struct{} // closed when the window ends: refused, fenced, or the agent exited
}

type projectAgent struct {
	s  *Server
	id string

	mu       sync.Mutex
	state    agentState
	proc     *agentProcess
	changed  chan struct{} // closed and replaced on every state change
	nextID   int64
	pending  map[int64]*pendingRequest
	sessions map[string]map[*client]struct{} // sockets attached to each session
	users    map[*client]struct{}            // sockets that sent anything to this project
	live     map[string]*liveSession         // sessions open in the current process
	reloads  map[string]*reload              // by session

	path          string               // the project folder, for the gateway's own session/load
	canClose      bool                 // the agent offers session/close (FR-24)
	lastActive    time.Time            // the last request, agent line or busy check of the project
	sessionActive map[string]time.Time // the same, per live session

	writeMu sync.Mutex
}

func newProjectAgent(s *Server, id string) *projectAgent {
	return &projectAgent{
		s: s, id: id, changed: make(chan struct{}),
		pending: map[int64]*pendingRequest{}, sessions: map[string]map[*client]struct{}{}, users: map[*client]struct{}{},
		live: map[string]*liveSession{}, reloads: map[string]*reload{}, sessionActive: map[string]time.Time{},
	}
}

// setState must be called with a.mu held.
func (a *projectAgent) setState(st agentState) {
	a.state = st
	close(a.changed)
	a.changed = make(chan struct{})
}

// project is the project as git needs it: its id and folder.
func (a *projectAgent) project() store.Project {
	a.mu.Lock()
	defer a.mu.Unlock()
	return store.Project{ID: a.id, Path: a.path}
}

func (a *projectAgent) fields(f audit.Fields) audit.Fields {
	f.Project = a.id
	return f
}

// ensure returns the running agent, starting it if needed. A start waits for an old process to
// exit first. It returns an RPC error when the agent cannot run.
func (a *projectAgent) ensure(ctx context.Context) (*agentProcess, *rpcError) {
	a.mu.Lock()
	for {
		switch a.state {
		case agentRunning:
			p := a.proc
			a.mu.Unlock()
			return p, nil
		case agentStarting, agentStopping:
			ch := a.changed
			a.mu.Unlock()
			select {
			case <-ch:
			case <-ctx.Done():
				return nil, &rpcError{Code: rpcAgentUnavailable, Message: "cancelled"}
			}
			a.mu.Lock()
		default: // stopped
			if !a.s.takeAgentSlot() {
				a.mu.Unlock()
				a.s.audit.Log("agent_capacity", a.fields(audit.Fields{}))
				return nil, &rpcError{Code: rpcAgentUnavailable, Message: "agent capacity reached: too many projects are running"}
			}
			a.setState(agentStarting)
			a.mu.Unlock()
			return a.start()
		}
	}
}

func (a *projectAgent) start() (*agentProcess, *rpcError) {
	ctx := context.Background()
	failStart := func(reason string, rerr *rpcError) (*agentProcess, *rpcError) {
		a.s.releaseAgentSlot()
		a.mu.Lock()
		a.setState(agentStopped)
		a.mu.Unlock()
		a.s.audit.Log("agent_error", a.fields(audit.Fields{Reason: reason}))
		return nil, rerr
	}
	project, err := a.s.store.ProjectByID(ctx, a.id)
	if err != nil || project == nil {
		return failStart("project", &rpcError{Code: rpcAgentUnavailable, Message: "unknown project"})
	}
	proc, err := a.s.runner.start(*project, a.s.projectHome(a.id))
	if errors.Is(err, errProjectLocked) {
		return failStart("locked", &rpcError{Code: rpcAgentUnavailable, Message: err.Error()})
	}
	if err != nil {
		return failStart(spawnErrorReason(err), &rpcError{Code: rpcAgentUnavailable, Message: "agent failed to start"})
	}
	a.s.audit.Log("agent_start", a.fields(audit.Fields{Pid: proc.pid()}))
	a.mu.Lock()
	a.proc = proc
	a.mu.Unlock()
	go a.readLoop(proc)
	go a.watchExit(proc)

	// The gateway initializes the agent itself, with no client capabilities: the phone has no
	// project files or terminal to offer (D-026).
	reply := make(chan *jsonv.Value, 1)
	a.mu.Lock()
	a.nextID++
	id := a.nextID
	a.pending[id] = &pendingRequest{method: "initialize", reply: reply}
	a.mu.Unlock()
	line := `{"jsonrpc":"2.0","id":` + strconv.FormatInt(id, 10) + `,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}` + "\n"
	_, _ = a.write(proc, []byte(line))

	fail := func(reason string) (*agentProcess, *rpcError) {
		a.stop(proc)
		a.s.audit.Log("agent_error", a.fields(audit.Fields{Reason: reason}))
		return nil, &rpcError{Code: rpcAgentUnavailable, Message: "agent failed to start"}
	}
	select {
	case resp := <-reply:
		if resp == nil {
			return nil, &rpcError{Code: rpcAgentUnavailable, Message: "agent exited during start"}
		}
		result := resp.Get("result")
		if result == nil || result.Kind != jsonv.Object {
			return fail("initialize")
		}
		a.s.captureCapabilities(result)
		a.mu.Lock()
		a.canClose = result.Get("agentCapabilities").Get("sessionCapabilities").Get("close") != nil
		a.mu.Unlock()
	case <-time.After(agentStartTimeout):
		return fail("initialize_timeout")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.proc != proc || a.state != agentStarting {
		return nil, &rpcError{Code: rpcAgentUnavailable, Message: "agent exited during start"}
	}
	a.path = project.Path
	a.lastActive = time.Now()
	a.setState(agentRunning)
	go a.idleLoop(proc)
	return proc, nil
}

// stop asks a process to exit. The state stays "stopping" until it has exited.
func (a *projectAgent) stop(proc *agentProcess) {
	a.mu.Lock()
	if a.proc == proc && a.state != agentStopping {
		a.setState(agentStopping)
	}
	a.mu.Unlock()
	proc.terminate(killGrace)
}

func (a *projectAgent) watchExit(proc *agentProcess) {
	<-proc.exited
	select { // forward what the agent wrote before it exited
	case <-proc.stdoutDone:
	case <-time.After(time.Second):
	}
	code, signal := proc.exitInfo()
	a.s.audit.Log("agent_exit", a.fields(audit.Fields{Pid: proc.pid(), HasExit: true, ExitCode: code, Signal: signal}))
	_ = proc.stdin.Close()
	// Release the lock and the slot before anyone can start a replacement.
	if proc.lock != nil {
		_ = proc.lock.Close()
	}
	a.s.releaseAgentSlot()

	a.mu.Lock()
	pending := a.pending
	a.pending = map[int64]*pendingRequest{}
	a.sessions = map[string]map[*client]struct{}{} // sessions are not live in a new process
	a.live = map[string]*liveSession{}
	a.sessionActive = map[string]time.Time{}
	for _, r := range a.reloads {
		close(r.done) // waiters retry against the next process
	}
	a.reloads = map[string]*reload{}
	if a.proc == proc {
		a.proc = nil
		a.setState(agentStopped)
	}
	a.mu.Unlock()
	a.s.dropPermissions(proc)

	for _, p := range pending {
		switch {
		case p.reply != nil:
			close(p.reply)
		case p.c != nil:
			resp := rpcErrorResponse(p.id, &rpcError{Code: rpcAgentUnavailable, Message: "agent exited"})
			if p.turn != "" {
				if v, err := jsonv.Parse(resp); err == nil {
					a.logTurnEnded(p.turn, v)
				}
			}
			p.c.send(resp)
		}
	}
}

func (a *projectAgent) readLoop(proc *agentProcess) {
	defer close(proc.stdoutDone)
	defer proc.stdout.Close()
	readLines(proc.stdout, a.s.cfg.Limits.MaxMessageBytes,
		func(line []byte) { a.onLine(proc, line) },
		func() {
			a.s.audit.Log("agent_line_too_big", a.fields(audit.Fields{}))
			a.stop(proc)
		})
}

func (a *projectAgent) onLine(proc *agentProcess, line []byte) {
	msg, err := jsonv.Parse(line)
	if err == nil && msg.Kind == jsonv.Object {
		sid, _ := msg.Get("params").Get("sessionId").StringValue()
		a.mu.Lock()
		a.touchLocked(sid)
		a.mu.Unlock()
	}
	if err != nil || msg.Kind != jsonv.Object {
		a.s.audit.Log("agent_noise", a.fields(audit.Fields{}))
		return
	}
	method, hasMethod := msg.Get("method").StringValue()
	id := msg.Get("id")
	hasID := !id.IsNull()
	if hasMethod {
		a.s.audit.Log("rpc", a.fields(audit.Fields{Dir: "out", Method: method}))
	}
	switch {
	case hasMethod && hasID:
		a.agentRequest(proc, msg, method, id)
	case hasMethod:
		a.notify(msg)
	case hasID:
		a.agentResponse(msg, id)
	default:
		a.s.audit.Log("agent_noise", a.fields(audit.Fields{}))
	}
}

// notify sends an agent notification to the sockets attached to its session, or, with no session,
// to every socket that has used the project. A session notification is logged first, and
// subscribers get it as `_agmente/event` instead (D-028).
func (a *projectAgent) notify(msg *jsonv.Value) {
	sid, _ := msg.Get("params").Get("sessionId").StringValue()
	out := msg.Marshal()
	a.mu.Lock()
	if sid != "" {
		u := msg.Get("params").Get("update")
		switch kind, _ := u.Get("sessionUpdate").StringValue(); kind {
		case "current_mode_update":
			if mode, ok := u.Get("currentModeId").StringValue(); ok {
				a.setMode(sid, mode)
			}
		case "session_info_update":
			if title, ok := u.Get("title").StringValue(); ok {
				a.mu.Unlock()
				if err := a.s.store.SetSessionTitle(context.Background(), sid, title); err != nil {
					a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_title"}))
				}
				a.mu.Lock()
			}
		}
		if r := a.reloads[sid]; r != nil {
			// The agent's replay after a load: the requesting socket shows it, the log already has
			// it, and other phones have seen it (FR-20, D-029).
			a.mu.Unlock()
			if r.c != nil { // nil: the gateway's own load, whose replay nobody asked for
				r.c.send(out)
			}
			return
		}
	}
	targets := a.users
	if sid != "" {
		targets = a.sessions[sid]
	}
	list := make([]*client, 0, len(targets))
	for c := range targets {
		list = append(list, c)
	}
	a.mu.Unlock()
	if sid == "" {
		for _, c := range list {
			c.send(out)
		}
		return
	}
	method, _ := msg.Get("method").StringValue()
	kind := "notification"
	if method == "session/update" {
		kind = "update"
	}
	a.s.emit(a.id, sid, kind, out, list)
}

func (a *projectAgent) agentResponse(msg, id *jsonv.Value) {
	n, ok := id.Int()
	a.mu.Lock()
	p := a.pending[n]
	delete(a.pending, n)
	a.mu.Unlock()
	if !ok || p == nil {
		a.s.audit.Log("agent_noise", a.fields(audit.Fields{Reason: "unexpected response"}))
		return
	}
	if p.reply != nil {
		p.reply <- msg
		return
	}
	if p.fence != nil {
		a.endReload(p.session, p.fence) // every line of the replay came before this answer
		return
	}
	if p.turn != "" {
		a.logTurnEnded(p.turn, msg)
	}
	result := msg.Get("result")
	if p.reload != nil {
		if result == nil {
			a.endReload(p.session, p.reload) // refused: the agent replays nothing
		} else {
			a.mu.Lock()
			a.live[p.session] = &liveSession{result: copyResult(result, "")}
			a.nextID++
			n := a.nextID
			a.pending[n] = &pendingRequest{method: "session/list", session: p.session, fence: p.reload}
			proc := a.proc
			a.mu.Unlock()
			if proc != nil {
				fence := `{"jsonrpc":"2.0","id":` + strconv.FormatInt(n, 10) + `,"method":"session/list","params":{}}` + "\n"
				_, _ = a.write(proc, []byte(fence))
			}
		}
	}
	if result != nil {
		switch p.method {
		case "session/new":
			if sid, ok := result.Get("sessionId").StringValue(); ok && sid != "" {
				a.mu.Lock()
				a.live[sid] = &liveSession{result: copyResult(result, "sessionId")}
				a.mu.Unlock()
				a.recordSession(sid, p.c)
			}
		case "session/load", "session/resume":
			if p.session != "" {
				a.recordSession(p.session, p.c)
			}
		case "session/set_mode":
			a.mu.Lock()
			a.setMode(p.sid, p.modeID)
			a.mu.Unlock()
		case "session/delete", "session/close":
			a.mu.Lock()
			delete(a.live, p.sid)
			a.mu.Unlock()
			if p.method == "session/delete" {
				if err := a.s.store.DeleteSession(context.Background(), p.sid); err != nil {
					a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "delete_session"}))
				}
			}
		}
	}
	if p.c == nil {
		return // the gateway's own load or close
	}
	msg.Obj["id"] = p.id
	p.c.send(msg.Marshal())
}

// endReload ends a load's replay window and releases the requests that waited for it.
func (a *projectAgent) endReload(sid string, r *reload) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.reloads[sid] == r {
		delete(a.reloads, sid)
		close(r.done)
	}
}

// copyResult copies a response result object, without the key drop.
func copyResult(result *jsonv.Value, drop string) *jsonv.Value {
	out := jsonv.Obj()
	if result.Kind != jsonv.Object {
		return out
	}
	for _, k := range result.Keys {
		if k != drop {
			out.Set(k, result.Obj[k])
		}
	}
	return out
}

// setMode records a session's current mode in its cached result. It must be called with a.mu held.
func (a *projectAgent) setMode(sid, mode string) {
	ls := a.live[sid]
	if ls == nil || mode == "" {
		return
	}
	modes := ls.result.Get("modes")
	if modes == nil || modes.Kind != jsonv.Object {
		return
	}
	next := copyResult(modes, "") // the cached value may be marshalled concurrently: replace, do not edit
	next.Set("currentModeId", jsonv.Str(mode))
	res := copyResult(ls.result, "")
	res.Set("modes", next)
	ls.result = res
}

func (a *projectAgent) recordSession(sid string, c *client) {
	if err := a.s.store.RecordSession(context.Background(), sid, a.id); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "record_session"}))
	}
	a.attach(sid, c)
}

func (a *projectAgent) attach(sid string, c *client) {
	if sid == "" || c == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.attachLocked(sid, c)
}

// attachLocked must be called with a.mu held.
func (a *projectAgent) attachLocked(sid string, c *client) {
	set := a.sessions[sid]
	if set == nil {
		set = map[*client]struct{}{}
		a.sessions[sid] = set
	}
	set[c] = struct{}{}
}

func (a *projectAgent) detach(c *client) {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.users, c)
	for _, set := range a.sessions {
		delete(set, c)
	}
}

// agentRequest handles a request from the agent. A permission request goes to the sockets
// attached to its session under a gateway id; the first answer goes back (D-009: the gateway
// itself never answers one). Other agent requests are refused: the phone offers no fs or terminal.
func (a *projectAgent) agentRequest(proc *agentProcess, msg *jsonv.Value, method string, id *jsonv.Value) {
	if method != "session/request_permission" {
		_, _ = a.write(proc, append(rpcErrorResponse(id, &rpcError{Code: rpcMethodNotFound, Message: "Method not found"}), '\n'))
		return
	}
	sid, _ := msg.Get("params").Get("sessionId").StringValue()
	gwID := a.s.addPermission(a, proc, id, sid, msg.Get("params"))
	msg.Obj["id"] = &jsonv.Value{Kind: jsonv.String, Str: gwID}
	out := msg.Marshal()
	a.mu.Lock()
	list := make([]*client, 0, len(a.sessions[sid]))
	for c := range a.sessions[sid] {
		list = append(list, c)
	}
	a.mu.Unlock()
	if sid == "" {
		for _, c := range list {
			c.send(out)
		}
		return
	}
	a.s.emit(a.id, sid, "permission_request", out, list)
}

// forward sends a phone message to the project's agent, starting it if needed. A load or resume
// (reopen is its session) never reaches an agent in which the session is live: the gateway answers
// it itself (FR-20, D-029).
func (a *projectAgent) forward(c *client, msg *jsonv.Value, method string, isRequest bool, sid, reopen string) *rpcError {
	if reopen != "" && !isRequest {
		// A load sent as a notification has no answer to give, and would make the agent replay
		// history outside the guard.
		a.s.audit.Log("dropped", with(c.who, audit.Fields{Method: method, Project: a.id}))
		return nil
	}
	key := sid
	if reopen != "" {
		key = reopen
	}
	autoLoaded := false
	for attempt := 0; attempt < 2; {
		proc, rerr := a.ensure(c.ctx)
		if rerr != nil {
			return rerr
		}
		a.mu.Lock()
		if a.proc != proc || a.state != agentRunning {
			a.mu.Unlock()
			attempt++
			continue // it exited between ensure and here: start again
		}
		if r := a.reloads[key]; key != "" && r != nil {
			// A load for this session is with the agent, or its replay is still arriving: send
			// nothing for the session until the window ends, so the agent gets one load, no turn
			// runs during it, and no replayed line is taken for a new one.
			done := r.done
			a.mu.Unlock()
			select {
			case <-done:
			case <-c.ctx.Done():
				return &rpcError{Code: rpcAgentUnavailable, Message: "cancelled"}
			}
			continue
		}
		if !autoLoaded && autoLoad[method] && sid != "" && a.live[sid] == nil {
			// The session is not open in this agent (it restarted, stopped when idle, or closed the
			// session): open it first with the gateway's own load, once and with no turn running
			// (FR-20). Its replay goes nowhere; this request waits for the window to end (D-032).
			autoLoaded = true
			rl := &reload{done: make(chan struct{})}
			a.reloads[sid] = rl
			a.nextID++
			n := a.nextID
			a.pending[n] = &pendingRequest{method: "session/load", session: sid, reload: rl}
			params := jsonv.Obj()
			params.Set("sessionId", jsonv.Str(sid))
			params.Set("cwd", jsonv.Str(a.path))
			params.Set("mcpServers", &jsonv.Value{Kind: jsonv.Array})
			load := jsonv.Obj()
			load.Set("jsonrpc", jsonv.Str("2.0"))
			load.Set("id", &jsonv.Value{Kind: jsonv.Number, Num: strconv.FormatInt(n, 10)})
			load.Set("method", jsonv.Str("session/load"))
			load.Set("params", params)
			a.mu.Unlock()
			a.s.audit.Log("reload", with(c.who, audit.Fields{Method: method, Project: a.id, Reason: "gateway"}))
			_, _ = a.write(proc, append(load.Marshal(), '\n'))
			continue
		}
		a.touchLocked(key)
		a.users[c] = struct{}{}
		if reopen != "" {
			if ls := a.live[reopen]; ls != nil {
				result := ls.result.Marshal()
				a.attachLocked(reopen, c)
				a.mu.Unlock()
				a.s.reopenLive(a, c, msg.Get("id"), reopen, method, result)
				return nil
			}
		}
		if sid != "" {
			a.attachLocked(sid, c)
		}
		var rl *reload
		turn := ""
		if isRequest {
			if reopen != "" {
				rl = &reload{c: c, done: make(chan struct{})}
				a.reloads[reopen] = rl
			}
			if method == "session/prompt" {
				turn = sid
			}
			p := &pendingRequest{c: c, id: msg.Get("id"), method: method, session: reopen, turn: turn, reload: rl}
			switch method {
			case "session/set_mode":
				p.sid = sid
				p.modeID, _ = msg.Get("params").Get("modeId").StringValue()
			case "session/delete", "session/close":
				p.sid = sid
			}
			a.nextID++
			n := a.nextID
			a.pending[n] = p
			msg.Obj["id"] = &jsonv.Value{Kind: jsonv.Number, Num: strconv.FormatInt(n, 10)}
		}
		a.mu.Unlock()
		if rl != nil {
			a.s.audit.Log("reload", with(c.who, audit.Fields{Method: method, Project: a.id}))
		}
		if turn != "" {
			// Logged before the agent sees the prompt, so it precedes every update of the turn.
			a.logTurnStarted(turn, msg.Get("params").Get("prompt"))
			a.snapshotTurnStart(turn) // before the agent sees the prompt, so it cannot change files first (D-036)
		}
		full, _ := a.write(proc, append(msg.Marshal(), '\n')) // after an exit, the exit path answers
		if full {
			a.s.audit.Log("backpressure", with(c.who, audit.Fields{Dir: "in", Project: a.id}))
		}
		if method == "session/cancel" && sid != "" {
			a.s.cancelPermissions(a, sid) // ACP: the client answers open requests with cancelled
		}
		return nil
	}
	return &rpcError{Code: rpcAgentUnavailable, Message: "agent exited"}
}

func (a *projectAgent) write(proc *agentProcess, line []byte) (bool, error) {
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	return proc.writeLine(line)
}

// logEvent logs a gateway event for a session and sends it to the session's subscribers (FR-18,
// D-027, D-028). Other sockets do not get gateway events.
func (a *projectAgent) logEvent(sessionID, kind string, message []byte) {
	a.s.emit(a.id, sessionID, kind, message, nil)
}

// gatewayNotification builds a JSON-RPC notification the gateway itself sends about a session.
func gatewayNotification(method, sessionID string, fields map[string]*jsonv.Value, order ...string) []byte {
	params := jsonv.Obj()
	params.Set("sessionId", jsonv.Str(sessionID))
	for _, k := range order {
		if v := fields[k]; v != nil {
			params.Set(k, v)
		}
	}
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("method", jsonv.Str(method))
	msg.Set("params", params)
	return msg.Marshal()
}

// logTurnStarted records the user's prompt: Bob does not echo it while the turn runs, so other
// devices learn it only from this event.
func (a *projectAgent) logTurnStarted(sessionID string, prompt *jsonv.Value) {
	if prompt == nil {
		prompt = &jsonv.Value{Kind: jsonv.Array}
	}
	a.logEvent(sessionID, "turn_started", gatewayNotification("_agmente/turn_started", sessionID, map[string]*jsonv.Value{"prompt": prompt}, "prompt"))
}

// logTurnEnded records how a turn ended: the agent's result (stopReason) or its error.
func (a *projectAgent) logTurnEnded(sessionID string, response *jsonv.Value) {
	fields := map[string]*jsonv.Value{}
	if r := response.Get("result"); r != nil {
		fields["stopReason"] = r.Get("stopReason")
	}
	status := "idle"
	if e := response.Get("error"); e != nil {
		fields["error"] = e
		status = "error"
	}
	if err := a.s.store.SetSessionStatus(context.Background(), sessionID, status); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_status"}))
	}
	a.logEvent(sessionID, "turn_ended", gatewayNotification("_agmente/turn_ended", sessionID, fields, "stopReason", "error"))
	a.snapshotTurnEnd(sessionID)
}
