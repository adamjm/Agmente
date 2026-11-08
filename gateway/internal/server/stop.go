package server

// Stop a turn or a project's agent, flag stalled turns, and remove leftover containers (D-106).
//
// _acpcode/sessions/stop {sessionId, scope: "turn"|"agent", force?}:
//   - scope "turn" cancels the session's running prompt (session/cancel) and waits up to
//     stopTurnWait for the prompt to end. A hung agent does not answer, so the outcome is
//     still_running and nothing else is done. The phone may then ask for the agent scope.
//   - scope "agent" cancels every running prompt and open approval of the project, ends the
//     prompts as stopped, terminates the project's agent, and removes its container by name. It is
//     refused (-32001) while another session of the project has a running turn, unless force is true.
//
// Nothing here is automatic. The gateway flags a stalled turn (sessions/index) and an idle stop
// skips a stalled turn when it decides whether the project is busy (idle.go). It never cancels or
// kills a turn on its own.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"sort"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// stopTurnWait is how long a turn-scope stop waits for the cancelled prompt to end.
const stopTurnWait = 10 * time.Second

// stopExitWait bounds the wait for an agent process after SIGTERM and the kill grace.
const stopExitWait = killGrace + 5*time.Second

// rpcStopConflict is the code for a stop refused because other sessions are running (the same
// code as the approval answers use for a state conflict, D-031).
const rpcStopConflict = -32001

// turnEnd is the number of turns that have ended for a session in this process, and how the last
// one ended (its stopReason, or "" for an error). The turn-scope stop waits for the count to grow.
type turnEnd struct {
	n          int
	stopReason string
}

// stallTime is the time a turn may go without an event before it is flagged stalled (D-106).
func (s *Server) stallTime() time.Duration {
	return time.Duration(s.cfg.Limits.StallSeconds) * time.Second
}

// turnStalled reports whether a turn has had no event for longer than threshold, with no approval
// open for its session (D-106). It is a flag only.
func turnStalled(lastEvent, now time.Time, threshold time.Duration, approvalOpen bool) bool {
	if approvalOpen || threshold <= 0 || lastEvent.IsZero() {
		return false
	}
	return now.Sub(lastEvent) > threshold
}

// keepsAgentAwake reports whether a pending request holds off the project's idle stop (D-106). A
// stalled turn does not: its agent is hung, and the idle stop is what ends it. Other requests keep
// the rule they had before.
func keepsAgentAwake(p *pendingRequest, stalled func(sid string) bool) bool {
	if p.turn == "" {
		return true
	}
	return !stalled(p.turn)
}

// turnStopOutcome maps what a turn-scope stop saw to its outcome (D-106). hadTurn is whether a
// prompt was running when the stop started; ended, whether it ended within the wait; stopReason,
// how it ended.
func turnStopOutcome(hadTurn, ended bool, stopReason string) string {
	switch {
	case !hadTurn:
		return "not_running"
	case !ended:
		return "still_running"
	case stopReason == "cancelled":
		return "cancelled"
	}
	return "not_running" // the turn finished on its own before the cancel took effect
}

// agentStopOutcome is the outcome of an agent-scope stop: stopped when this call stopped a running
// agent, not_running otherwise (D-106).
func agentStopOutcome(stoppedNow bool) string {
	if stoppedNow {
		return "stopped"
	}
	return "not_running"
}

// shouldReap reports whether a start removes a container that holds the project's name (D-106).
// It does so while this process has not yet dealt with leftovers, and never while a process of
// this gateway runs the project's agent.
func shouldReap(reapDone, tracked bool) bool {
	return !reapDone && !tracked
}

// containsName reports whether a container listing has the name.
func containsName(listed []string, name string) bool {
	for _, n := range listed {
		if n == name {
			return true
		}
	}
	return false
}

// containerRemover is implemented by the container runners (D-106). The host runner has no
// container, so it does not implement it.
type containerRemover interface {
	// removeContainer removes the project's container by name if one exists. It reports whether it
	// removed one. It never kills anything else.
	removeContainer(p store.Project) (bool, error)
}

// stopArgs is the validated params of _acpcode/sessions/stop.
type stopArgs struct {
	sessionID string
	scope     string
	force     bool
}

func parseStop(params *jsonv.Value) (stopArgs, *rpcError) {
	var a stopArgs
	sid, ok := params.Get("sessionId").StringValue()
	if !ok || sid == "" {
		return a, invalidParams("sessionId is required")
	}
	a.sessionID, a.scope = sid, "turn"
	if v := params.Get("scope"); !v.IsNull() {
		scope, ok := v.StringValue()
		if !ok || (scope != "turn" && scope != "agent") {
			return a, invalidParams("scope must be turn or agent")
		}
		a.scope = scope
	}
	if v := params.Get("force"); !v.IsNull() {
		if v.Kind != jsonv.Bool {
			return a, invalidParams("force must be true or false")
		}
		a.force = v.B
	}
	return a, nil
}

// serveStop answers one _acpcode/sessions/stop request. A stop can wait for the agent, so it runs
// in its own goroutine, as git requests do (D-033 guards a panic here too).
func (s *Server) serveStop(ctx context.Context, who audit.Who, id, params *jsonv.Value, reply func(*jsonv.Value, any, *rpcError)) {
	defer func() {
		if recover() != nil {
			s.audit.Log("panic", with(who, audit.Fields{Method: "_acpcode/sessions/stop"}))
			reply(id, nil, &rpcError{Code: rpcInternal, Message: "internal error"})
		}
	}()
	result, rerr := s.stopSession(ctx, who, params)
	reply(id, result, rerr)
}

// stopSession runs the stop and returns {outcome, stoppedSessions}.
func (s *Server) stopSession(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	args, rerr := parseStop(params)
	if rerr != nil {
		return nil, rerr
	}
	pid, err := s.store.SessionProject(ctx, args.sessionID)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read sessions"}
	}
	if pid == "" {
		return nil, &rpcError{Code: rpcInvalidParams, Message: "unknown session", Data: map[string]string{"reason": "unknown_session"}}
	}
	outcome, stopped := "not_running", []string{}
	if a := s.existingAgent(pid); a != nil {
		if args.scope == "turn" {
			outcome = a.stopTurn(args.sessionID)
			if outcome == "cancelled" {
				stopped = []string{args.sessionID}
			}
		} else {
			o, ids, rerr := a.stopAgent(ctx, args.sessionID, args.force)
			if rerr != nil {
				s.audit.Log("session_stop", with(who, audit.Fields{Project: pid, Reason: args.scope + ":" + rerr.Message}))
				return nil, rerr
			}
			outcome, stopped = o, ids
		}
	}
	s.audit.Log("session_stop", with(who, audit.Fields{Project: pid, Reason: args.scope + ":" + outcome}))
	return map[string]any{"outcome": outcome, "stoppedSessions": stopped}, nil
}

// existingAgent returns the project's agent if one was ever made in this process, without making one.
func (s *Server) existingAgent(projectID string) *projectAgent {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.agents[projectID]
}

// lastEvents returns when each session last had an event in this process (the projects' agents).
func (s *Server) lastEvents() map[string]time.Time {
	out := map[string]time.Time{}
	s.mu.Lock()
	agents := make([]*projectAgent, 0, len(s.agents))
	for _, a := range s.agents {
		agents = append(agents, a)
	}
	s.mu.Unlock()
	for _, a := range agents {
		a.mu.Lock()
		for sid, t := range a.eventAt {
			if t.After(out[sid]) {
				out[sid] = t
			}
		}
		a.mu.Unlock()
	}
	return out
}

// turnPendingLocked reports whether a prompt for the session is with the agent. a.mu must be held.
func (a *projectAgent) turnPendingLocked(sid string) bool {
	for _, p := range a.pending {
		if p.turn == sid {
			return true
		}
	}
	return false
}

// noteTurnEnd counts a turn end for the turn-scope stop. It is called where turn_ended is logged.
func (a *projectAgent) noteTurnEnd(sid, stopReason string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.turnEnds == nil {
		a.turnEnds = map[string]turnEnd{}
	}
	e := a.turnEnds[sid]
	e.n++
	e.stopReason = stopReason
	a.turnEnds[sid] = e
}

// stopTurn cancels the session's running prompt and waits up to stopTurnWait for it to end.
func (a *projectAgent) stopTurn(sid string) string {
	a.mu.Lock()
	if a.state != agentRunning || !a.turnPendingLocked(sid) {
		a.mu.Unlock()
		return turnStopOutcome(false, false, "")
	}
	proc := a.proc
	before := a.turnEnds[sid].n
	sent := a.turnRequestLocked(sid).sent
	if !sent {
		a.turnRequestLocked(sid).cancel = true // the prompt is not with the agent yet: promptWritten sends the cancel
	}
	a.mu.Unlock()

	if sent {
		a.writeCancel(proc, sid)
	}
	a.s.cancelPermissions(a, sid) // ACP: the client answers open requests with cancelled
	a.s.audit.Log("session_cancel", a.fields(audit.Fields{Reason: "stop"}))

	deadline := time.Now().Add(stopTurnWait)
	for {
		a.mu.Lock()
		e := a.turnEnds[sid]
		a.mu.Unlock()
		if e.n > before {
			return turnStopOutcome(true, true, e.stopReason)
		}
		if time.Now().After(deadline) {
			return turnStopOutcome(true, false, "")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// turnRequestLocked returns the prompt pending for a session, or a throwaway if none. a.mu must be held.
func (a *projectAgent) turnRequestLocked(sid string) *pendingRequest {
	for _, p := range a.pending {
		if p.turn == sid {
			return p
		}
	}
	return &pendingRequest{}
}

// promptWritten marks a prompt as with the agent. A cancel that a stop asked for before that is
// sent now, after the prompt, so the agent never reads the cancel first and ignores it (D-106).
// A turn shows as running before its prompt is written, because the start snapshot runs first.
func (a *projectAgent) promptWritten(p *pendingRequest, proc *agentProcess, sid string) {
	a.mu.Lock()
	p.sent = true
	cancel := p.cancel
	p.cancel = false
	a.mu.Unlock()
	if cancel {
		a.writeCancel(proc, sid)
	}
}

// writeCancel sends session/cancel for one session to the agent (a notification, as ACP defines).
func (a *projectAgent) writeCancel(proc *agentProcess, sid string) {
	params := jsonv.Obj()
	params.Set("sessionId", jsonv.Str(sid))
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("method", jsonv.Str("session/cancel"))
	msg.Set("params", params)
	_, _ = a.write(proc, append(msg.Marshal(), '\n'))
}

// waitSettled waits while the agent is starting or stopping. It returns once the state is stable.
func (a *projectAgent) waitSettled(ctx context.Context) *rpcError {
	for {
		a.mu.Lock()
		if a.state != agentStarting && a.state != agentStopping {
			a.mu.Unlock()
			return nil
		}
		ch := a.changed
		a.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return &rpcError{Code: rpcAgentUnavailable, Message: "cancelled"}
		}
	}
}

// busyElsewhere lists the other sessions of the project that are running, for the refusal (D-106).
func busyElsewhere(others map[string]string) *rpcError {
	list := make([]map[string]string, 0, len(others))
	ids := make([]string, 0, len(others))
	for sid := range others {
		ids = append(ids, sid)
	}
	sort.Strings(ids)
	for _, sid := range ids {
		list = append(list, map[string]string{"sessionId": sid, "status": others[sid]})
	}
	return &rpcError{
		Code:    rpcStopConflict,
		Message: "other sessions are running in this project",
		Data:    map[string]any{"reason": "busy_elsewhere", "otherSessions": list},
	}
}

// stopAgent stops the project's agent for the agent scope (D-106). It returns the outcome and the
// sessions whose turns or approvals this stop ended. The caller's session is not refused; other
// sessions are, unless force is set.
func (a *projectAgent) stopAgent(ctx context.Context, sid string, force bool) (string, []string, *rpcError) {
	if rerr := a.waitSettled(ctx); rerr != nil {
		return "", nil, rerr
	}
	approvals := a.s.approvalSessions(a) // read before a.mu is taken: approvals have their own lock

	a.mu.Lock()
	if a.state != agentRunning {
		a.mu.Unlock()
		return agentStopOutcome(false), []string{}, nil // a concurrent stop finished first
	}
	turns := map[string]bool{}
	sentTurn := map[string]bool{}
	for _, p := range a.pending {
		if p.turn != "" {
			turns[p.turn] = true
			sentTurn[p.turn] = p.sent
		}
	}
	others := map[string]string{}
	for s := range turns {
		if s != sid {
			others[s] = "running"
		}
	}
	for s := range approvals {
		if s != sid {
			others[s] = "awaiting_approval"
		}
	}
	if len(others) > 0 && !force {
		a.mu.Unlock()
		return "", nil, busyElsewhere(others)
	}
	proc := a.proc
	pending := a.pending
	a.pending = map[int64]*pendingRequest{}
	a.setState(agentStopping) // every forward and ensure waits for the exit from here on
	a.mu.Unlock()

	for s := range turns {
		if sentTurn[s] {
			a.writeCancel(proc, s) // a prompt not yet written is ended below, and never reaches the agent
		}
	}
	cancelled := a.s.cancelAgentPermissions(a)
	a.endPending(pending)

	affected := map[string]bool{}
	for s := range turns {
		affected[s] = true
	}
	for _, s := range cancelled {
		affected[s] = true
	}
	stopped := make([]string, 0, len(affected))
	for s := range affected {
		stopped = append(stopped, s)
	}
	sort.Strings(stopped)

	a.s.audit.Log("agent_stop", a.fields(audit.Fields{Pid: proc.pid()}))
	proc.terminate(killGrace)
	select {
	case <-proc.exited:
	case <-time.After(stopExitWait):
	}
	if rerr := a.removeAfterStop(ctx); rerr != nil {
		return "", nil, rerr
	}
	if rerr := a.waitStopped(ctx); rerr != nil {
		return "", nil, rerr
	}
	return agentStopOutcome(true), stopped, nil
}

// endPending ends every request the agent had not answered, because the process is going away and
// watchExit will no longer see them. A prompt is answered as cancelled and logged as stopped
// (turn_ended with stopped: true, no push). Other requests get an error.
func (a *projectAgent) endPending(pending map[int64]*pendingRequest) {
	for _, p := range pending {
		switch {
		case p.turn != "":
			a.logTurnStopped(p.turn)
			if p.c != nil {
				result := jsonv.Obj()
				result.Set("stopReason", jsonv.Str("cancelled"))
				p.c.send(replyResult(p.id, result))
			}
		case p.reply != nil:
			close(p.reply)
		case p.c != nil:
			p.c.send(rpcErrorResponse(p.id, &rpcError{Code: rpcAgentUnavailable, Message: "agent stopped"}))
		}
	}
}

// logTurnStopped records a turn that the stop ended: turn_ended with stopReason cancelled and
// stopped true. The session is idle afterwards, and no push is sent for a turn the person stopped.
func (a *projectAgent) logTurnStopped(sid string) {
	if err := a.s.store.SetSessionStatus(context.Background(), sid, "idle"); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_status"}))
	}
	fields := map[string]*jsonv.Value{"stopReason": jsonv.Str("cancelled"), "stopped": {Kind: jsonv.Bool, B: true}}
	a.logEvent(sid, "turn_ended", gatewayNotification("_acpcode/turn_ended", sid, fields, "stopReason", "stopped"))
	a.noteTurnEnd(sid, "cancelled")
	a.snapshotTurnEnd(sid)
}

// replyResult builds a JSON-RPC result for a request the gateway answers itself.
func replyResult(id, result *jsonv.Value) []byte {
	msg := jsonv.Obj()
	msg.Set("jsonrpc", jsonv.Str("2.0"))
	msg.Set("id", id)
	msg.Set("result", result)
	return msg.Marshal()
}

// approvalSessions returns the sessions with an open approval for this agent. It takes only the
// approval lock.
func (s *Server) approvalSessions(a *projectAgent) map[string]bool {
	s.permMu.Lock()
	defer s.permMu.Unlock()
	out := map[string]bool{}
	for _, p := range s.perms {
		if p.agent == a && p.session != "" {
			out[p.session] = true
		}
	}
	return out
}

// cancelAgentPermissions answers every open approval of the agent with cancelled, recorded as
// answered by a stop (D-106). It returns the sessions that had one, sorted.
func (s *Server) cancelAgentPermissions(a *projectAgent) []string {
	s.permMu.Lock()
	var ids []string
	sessions := map[string]bool{}
	for id, p := range s.perms {
		if p.agent == a {
			ids = append(ids, id)
			if p.session != "" {
				sessions[p.session] = true
			}
		}
	}
	s.permMu.Unlock()
	for _, id := range ids {
		if p := s.takePermission(id, "stop"); p != nil {
			s.resolve(p, outcomeResponse(id, cancelled()), "stop")
		}
	}
	out := make([]string, 0, len(sessions))
	for sid := range sessions {
		out = append(out, sid)
	}
	sort.Strings(out)
	return out
}

// removeAfterStop removes the project's container by name after the process has exited (D-106).
// A failure is reported, and the next start removes it again.
func (a *projectAgent) removeAfterStop(ctx context.Context) *rpcError {
	p := a.project()
	rm, ok := a.s.runner.(containerRemover)
	if !ok {
		return nil
	}
	removed, err := rm.removeContainer(p)
	if err != nil {
		a.mu.Lock()
		a.reapDone = false
		a.mu.Unlock()
		a.s.audit.Log("container_remove_failed", a.fields(audit.Fields{Reason: "stop"}))
		return &rpcError{Code: rpcAgentUnavailable, Message: "could not stop the agent; try again", Data: map[string]string{"reason": "remove_failed"}}
	}
	if removed {
		a.s.audit.Log("container_removed", a.fields(audit.Fields{Reason: "stop"}))
	}
	return nil
}

// waitStopped waits until watchExit has set the agent to stopped.
func (a *projectAgent) waitStopped(ctx context.Context) *rpcError {
	deadline := time.NewTimer(stopExitWait)
	defer deadline.Stop()
	for {
		a.mu.Lock()
		st := a.state
		ch := a.changed
		a.mu.Unlock()
		if st != agentStopping {
			return nil
		}
		select {
		case <-ch:
		case <-deadline.C:
			return &rpcError{Code: rpcAgentUnavailable, Message: "the agent did not stop in time"}
		case <-ctx.Done():
			return &rpcError{Code: rpcAgentUnavailable, Message: "cancelled"}
		}
	}
}

// reapIfNeeded removes a container that holds the project's name before a start, when this
// process has not dealt with leftovers since its last exit (D-106). Without it, a container that
// survived its CLI holds the name, and the start fails with "agent failed to start" (D-032).
func (a *projectAgent) reapIfNeeded(p store.Project) {
	a.mu.Lock()
	do := shouldReap(a.reapDone, a.proc != nil)
	a.mu.Unlock()
	if !do {
		return
	}
	rm, ok := a.s.runner.(containerRemover)
	if !ok {
		a.setReapDone()
		return
	}
	removed, err := rm.removeContainer(p)
	if err != nil {
		a.s.audit.Log("container_reap_failed", a.fields(audit.Fields{Reason: "start"}))
		return // reapDone stays false: the next start tries again
	}
	a.setReapDone()
	if removed {
		a.s.audit.Log("container_reaped", a.fields(audit.Fields{Reason: "leftover"}))
	}
}

func (a *projectAgent) setReapDone() {
	a.mu.Lock()
	a.reapDone = true
	a.mu.Unlock()
}

// removeContainer removes the podman container named for the project, if it exists (D-106). The
// name is acpcode-<projectId>, the lock of D-015. `podman rm -f` also stops a running container.
func (r podmanRunner) removeContainer(p store.Project) (bool, error) {
	name := "acpcode-" + p.ID
	bin := r.cfg.Runner.Podman
	if bin == "" {
		bin = "podman"
	}
	exists := exec.Command(bin, "container", "exists", name)
	exists.Env = os.Environ()
	switch err := exists.Run(); {
	case err == nil:
	case errorExitCode(err) == 1:
		return false, nil
	default:
		return false, err
	}
	rm := exec.Command(bin, "rm", "-f", "-t", "0", name)
	rm.Env = os.Environ()
	if out, err := rm.CombinedOutput(); err != nil {
		_ = out // podman's text may name the container; it is not logged
		return false, errors.New("podman rm failed")
	}
	return true, nil
}

// removeContainer removes the Apple container named for the project, if it is listed (D-106).
// The listing is the running containers only (verify: stopped leftovers under `container list`).
func (r *appleRunner) removeContainer(p store.Project) (bool, error) {
	name := appleAgentName(p)
	up, err := r.listedRunning(name)
	if err != nil {
		return false, err
	}
	if !up {
		return false, nil
	}
	rm := exec.Command(r.cli(), "delete", "--force", name)
	rm.Env = os.Environ()
	if out, err := rm.CombinedOutput(); err != nil {
		_ = out
		return false, errors.New("container delete failed")
	}
	return true, nil
}

// errorExitCode returns the exit status of a finished command, or -1.
func errorExitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}
