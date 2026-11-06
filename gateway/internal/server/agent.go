package server

// Start the configured agent and read its stdout as lines (FR-4).

import (
	"bufio"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// buildAgentEnv builds the child environment from an allow-list. Nothing else from the gateway
// leaks in.
func buildAgentEnv(names []string) []string {
	env := []string{}
	for _, name := range names {
		if value, ok := os.LookupEnv(name); ok {
			env = append(env, name+"="+value)
		}
	}
	return env
}

// agentProcess is one running agent with pipes the gateway owns.
type agentProcess struct {
	cmd    *exec.Cmd
	stdin  *os.File // write end; pollable, so writes can take a deadline
	stdout *os.File // read end
	exited chan struct{}
	state  *os.ProcessState
	lock   *os.File // the project lock (host runner); closed after the process exits

	stdoutDone chan struct{} // closed when the gateway has read all of stdout
}

// startProcess starts cmd with pipes the gateway owns. extra files are passed to the child as
// fds 3 and up (the project lock, D-015). The client never supplies the command, arguments or
// environment: runners build cmd from the config only.
func startProcess(cmd *exec.Cmd, extra []*os.File) (*agentProcess, error) {
	inR, inW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		return nil, err
	}
	cmd.Stdin = inR
	cmd.Stdout = outW
	cmd.Stderr = nil // /dev/null: agent logs stay on the host
	cmd.ExtraFiles = extra
	if err := cmd.Start(); err != nil {
		inR.Close()
		inW.Close()
		outR.Close()
		outW.Close()
		return nil, err
	}
	inR.Close()
	outW.Close()
	p := &agentProcess{cmd: cmd, stdin: inW, stdout: outR, exited: make(chan struct{}), stdoutDone: make(chan struct{})}
	go func() {
		_ = cmd.Wait() // stdio are *os.File, so Wait returns when the process exits
		p.state = cmd.ProcessState
		close(p.exited)
	}()
	return p, nil
}

func spawnErrorReason(err error) string {
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, exec.ErrNotFound) {
		return "ENOENT"
	}
	if errors.Is(err, fs.ErrPermission) {
		return "EACCES"
	}
	return "error"
}

func (p *agentProcess) pid() int { return p.cmd.Process.Pid }

func (p *agentProcess) hasExited() bool {
	select {
	case <-p.exited:
		return true
	default:
		return false
	}
}

// exitInfo returns the exit code (nil when killed by a signal) and the signal name.
func (p *agentProcess) exitInfo() (*int, string) {
	if p.state == nil {
		return nil, ""
	}
	if ws, ok := p.state.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return nil, signalName(ws.Signal())
	}
	code := p.state.ExitCode()
	return &code, ""
}

// terminate sends SIGTERM, then SIGKILL after grace if the process is still running.
func (p *agentProcess) terminate(grace time.Duration) {
	if p.hasExited() {
		return
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	go func() {
		select {
		case <-p.exited:
		case <-time.After(grace):
			_ = p.cmd.Process.Kill()
		}
	}()
}

// writeLine writes one line to the agent's stdin. It reports whether the pipe was full (the
// gateway then blocks until the agent drains it, so the phone socket is not read meanwhile).
func (p *agentProcess) writeLine(line []byte) (full bool, err error) {
	_ = p.stdin.SetWriteDeadline(time.Now().Add(2 * time.Millisecond))
	n, err := p.stdin.Write(line)
	_ = p.stdin.SetWriteDeadline(time.Time{})
	if err == nil {
		return false, nil
	}
	if !errors.Is(err, os.ErrDeadlineExceeded) {
		return false, err
	}
	_, err = p.stdin.Write(line[n:])
	return true, err
}

var signalNames = map[syscall.Signal]string{
	syscall.SIGHUP: "SIGHUP", syscall.SIGINT: "SIGINT", syscall.SIGQUIT: "SIGQUIT", syscall.SIGILL: "SIGILL",
	syscall.SIGTRAP: "SIGTRAP", syscall.SIGABRT: "SIGABRT", syscall.SIGBUS: "SIGBUS", syscall.SIGFPE: "SIGFPE",
	syscall.SIGKILL: "SIGKILL", syscall.SIGUSR1: "SIGUSR1", syscall.SIGSEGV: "SIGSEGV", syscall.SIGUSR2: "SIGUSR2",
	syscall.SIGPIPE: "SIGPIPE", syscall.SIGALRM: "SIGALRM", syscall.SIGTERM: "SIGTERM",
}

func signalName(s syscall.Signal) string {
	if name, ok := signalNames[s]; ok {
		return name
	}
	return s.String()
}

// readLines splits r into newline-terminated lines, without the newline and one trailing CR.
// Empty lines are skipped. A line longer than maxBytes calls onOverflow once, and the rest of the
// stream is drained and ignored. A last line with no newline is dropped.
func readLines(r io.Reader, maxBytes int64, onLine func([]byte), onOverflow func()) {
	br := bufio.NewReaderSize(r, 64*1024)
	var line []byte
	for {
		chunk, err := br.ReadSlice('\n')
		contentLen := int64(len(line) + len(chunk))
		if err == nil {
			contentLen-- // the newline
		}
		if contentLen > maxBytes {
			onOverflow()
			_, _ = io.Copy(io.Discard, br)
			return
		}
		line = append(line, chunk...)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return // EOF or read error: a partial last line is dropped
		}
		text := line[:len(line)-1]
		if len(text) > 0 && text[len(text)-1] == '\r' {
			text = text[:len(text)-1]
		}
		if len(text) > 0 {
			onLine(text)
		}
		line = line[:0]
	}
}
