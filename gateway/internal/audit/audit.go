// Package audit writes one JSON line per event (FR-9).
// Callers pass only the fields below. Never pass prompt text, tool output or tokens.
package audit

import (
	"io"
	"strconv"
	"sync"
	"time"

	"acpcode/gateway/internal/jsonv"
)

// Fields holds the allowed audit fields. Unset fields are left out of the line.
// ExitCode and Signal are written as null when their Has flag is set but they have no value,
// as the agent_exit event does for a process that was killed by a signal.
type Fields struct {
	Identity, Device, Client string
	Conn                     int
	Status                   int
	Reason, Method, Dir      string
	Code                     int
	Pid                      int
	HasExit                  bool // write exitCode and signal (each may be null)
	ExitCode                 *int
	Signal                   string
	Project                  string
	Path                     string // a project-relative file path (file events, D-063); never a token
	FolderCreated            bool   // project_created: the gateway made the project folder (D-091)
	Source, Grant            string // a connector prompt: source "claude" and the grant id (D-096)
	Scope                    string // the token's scope on the line (scope.go)
	Credential, Host         string // git credential profile id and its host (D-105); never a token
}

// Who identifies one connection in every line it writes.
type Who struct {
	Identity, Device, Client string
	Conn                     int
	Source, Grant            string // set for a connector prompt: source "claude" and the grant id (D-096)
	Scope                    string // the token's scope (config.TokenScopes); empty for a call with no token
	Secure                   bool   // the connection is secure (wss, or a loopback-only gateway); D-105. Not logged.
}

func (w Who) Fields() Fields {
	return Fields{Identity: w.Identity, Device: w.Device, Client: w.Client, Conn: w.Conn, Source: w.Source, Grant: w.Grant, Scope: w.Scope}
}

// Logger writes audit lines to a sink. It is safe for concurrent use.
type Logger struct {
	mu  sync.Mutex
	out io.Writer
	now func() time.Time
}

func New(out io.Writer) *Logger { return &Logger{out: out, now: time.Now} }

// Log writes one line: {"ts":..., "event":..., then the set fields in a fixed order}.
func (l *Logger) Log(event string, f Fields) {
	buf := make([]byte, 0, 256)
	buf = append(buf, `{"ts":`...)
	buf = jsonv.AppendString(buf, l.now().UTC().Format("2006-01-02T15:04:05.000Z"))
	buf = append(buf, `,"event":`...)
	buf = jsonv.AppendString(buf, event)
	str := func(key, value string) {
		if value != "" {
			buf = append(buf, ',', '"')
			buf = append(buf, key...)
			buf = append(buf, '"', ':')
			buf = jsonv.AppendString(buf, value)
		}
	}
	num := func(key string, value int, set bool) {
		if set {
			buf = append(buf, ',', '"')
			buf = append(buf, key...)
			buf = append(buf, '"', ':')
			buf = strconv.AppendInt(buf, int64(value), 10)
		}
	}
	str("identity", f.Identity)
	str("device", f.Device)
	str("client", f.Client)
	num("conn", f.Conn, f.Conn != 0)
	str("source", f.Source)
	str("grant", f.Grant)
	str("scope", f.Scope)
	num("status", f.Status, f.Status != 0)
	str("reason", f.Reason)
	str("method", f.Method)
	str("dir", f.Dir)
	str("project", f.Project)
	str("path", f.Path)
	str("credential", f.Credential)
	str("host", f.Host)
	if f.FolderCreated {
		buf = append(buf, `,"folderCreated":true`...)
	}
	num("code", f.Code, f.Code != 0)
	num("pid", f.Pid, f.Pid != 0)
	if f.HasExit {
		if f.ExitCode != nil {
			num("exitCode", *f.ExitCode, true)
		} else {
			buf = append(buf, `,"exitCode":null`...)
		}
		if f.Signal != "" {
			str("signal", f.Signal)
		} else {
			buf = append(buf, `,"signal":null`...)
		}
	} else {
		str("signal", f.Signal)
	}
	buf = append(buf, '}', '\n')
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.out.Write(buf)
}
