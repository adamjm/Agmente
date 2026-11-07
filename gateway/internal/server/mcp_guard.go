package server

// The phone's MCP server list (F1, D-084, D-089). A session/new, session/load or session/resume may
// carry only stdio entries and HTTP entries. An entry may name tools in alwaysAllow (D-089). The
// gateway checks each entry and refuses the request
// with -32602 before routing, so a refused list never reaches an agent. A refusal names the entry
// and the field, never a value: args, env and header values stay out of every message and log line.

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
)

// mcpMethods are the requests that carry an mcpServers list.
var mcpMethods = map[string]bool{"session/new": true, "session/load": true, "session/resume": true}

// maxMCPServers is the most entries one list may hold.
const maxMCPServers = 32

// An entry's alwaysAllow list (D-089): at most maxAlwaysAllow tool names, each at most
// maxToolNameLength characters.
const (
	maxAlwaysAllow    = 64
	maxToolNameLength = 128
)

// mcpCounts is what the audit line may say about an accepted list: the entries by transport, and
// the number of alwaysAllow names in all. Never the names.
type mcpCounts struct{ Stdio, HTTP, AlwaysAllow int }

// mcpRefusal is why a list was refused. Code is the audit reason; Message goes to the phone.
type mcpRefusal struct {
	Code    string
	Message string
}

func mcpRefuse(code, format string, args ...any) *mcpRefusal {
	return &mcpRefusal{Code: code, Message: fmt.Sprintf(format, args...)}
}

// checkMCPServers validates a phone's mcpServers value. An absent or null list is accepted with no
// entries. The list is read only; it is never rewritten (the agent gets what the phone sent).
func checkMCPServers(list *jsonv.Value) (mcpCounts, *mcpRefusal) {
	var counts mcpCounts
	if list.IsNull() {
		return counts, nil
	}
	if list.Kind != jsonv.Array {
		return counts, mcpRefuse("shape", "mcpServers must be an array")
	}
	if len(list.Arr) > maxMCPServers {
		return counts, mcpRefuse("too_many", "mcpServers holds at most %d entries", maxMCPServers)
	}
	names := map[string]bool{}
	for i, e := range list.Arr {
		at := fmt.Sprintf("mcpServers[%d]", i)
		if e.Kind != jsonv.Object {
			return counts, mcpRefuse("shape", "%s must be an object", at)
		}
		var allow int
		if aa := e.Get("alwaysAllow"); aa != nil {
			names, err := alwaysAllowNames(aa)
			if err != nil {
				return counts, mcpRefuse("alwaysAllow", "%s: %s", at, err)
			}
			allow = len(names)
		}
		kind := "stdio"
		if t := e.Get("type"); t != nil {
			s, ok := t.StringValue()
			switch {
			case !ok:
				return counts, mcpRefuse("type", "%s: type must be a string", at)
			case s == "stdio":
			case s == "http":
				kind = "http"
			default:
				return counts, mcpRefuse("type", "%s: type %q is not allowed; use stdio or http", at, s)
			}
		}
		name, ok := e.Get("name").StringValue()
		if !ok || strings.TrimSpace(name) == "" {
			return counts, mcpRefuse("name", "%s: name must be a non-empty string", at)
		}
		if names[name] {
			return counts, mcpRefuse("duplicate", "%s: another entry has the same name", at)
		}
		names[name] = true

		allowed := map[string]bool{"type": true, "name": true, "command": true, "args": true, "env": true, "alwaysAllow": true}
		if kind == "http" {
			allowed = map[string]bool{"type": true, "name": true, "url": true, "headers": true, "alwaysAllow": true}
		}
		for _, k := range e.Keys {
			if !allowed[k] {
				return counts, mcpRefuse("field", "%s: a field is not allowed for this server type", at)
			}
		}
		var refusal *mcpRefusal
		if kind == "http" {
			refusal = checkMCPHTTP(at, e)
			counts.HTTP++
		} else {
			refusal = checkMCPStdio(at, e)
			counts.Stdio++
		}
		if refusal != nil {
			return counts, refusal
		}
		counts.AlwaysAllow += allow
	}
	return counts, nil
}

// alwaysAllowNames checks an alwaysAllow value (D-089): an array of at most 64 tool names, each a
// non-empty string of at most 128 characters. It returns the names as sent. An error names the
// position only, never a name.
func alwaysAllowNames(v *jsonv.Value) ([]string, error) {
	if v == nil || v.Kind != jsonv.Array {
		return nil, errors.New("alwaysAllow must be an array of tool names")
	}
	if len(v.Arr) > maxAlwaysAllow {
		return nil, fmt.Errorf("alwaysAllow holds at most %d tool names", maxAlwaysAllow)
	}
	names := make([]string, 0, len(v.Arr))
	for i, it := range v.Arr {
		s, ok := it.StringValue()
		if !ok || strings.TrimSpace(s) == "" || utf8.RuneCountInString(s) > maxToolNameLength {
			return nil, fmt.Errorf("alwaysAllow[%d] must be a non-empty string of at most %d characters", i, maxToolNameLength)
		}
		names = append(names, s)
	}
	return names, nil
}

func checkMCPStdio(at string, e *jsonv.Value) *mcpRefusal {
	if cmd, ok := e.Get("command").StringValue(); !ok || strings.TrimSpace(cmd) == "" {
		return mcpRefuse("command", "%s: command must be a non-empty string", at)
	}
	if args := e.Get("args"); args.Kind != jsonv.Array || !allStrings(args.Arr) {
		return mcpRefuse("args", "%s: args must be an array of strings", at)
	}
	if !pairList(e.Get("env")) {
		return mcpRefuse("env", "%s: env must be an array of {name, value} strings", at)
	}
	return nil
}

func checkMCPHTTP(at string, e *jsonv.Value) *mcpRefusal {
	raw, ok := e.Get("url").StringValue()
	if !ok || !mcpURLAllowed(raw) {
		return mcpRefuse("url", "%s: url must be https, or http to a loopback address", at)
	}
	if !pairList(e.Get("headers")) {
		return mcpRefuse("headers", "%s: headers must be an array of {name, value} strings", at)
	}
	return nil
}

// mcpURLAllowed accepts https to any host, and http only to a loopback host (the transport policy
// of D-019, for the gateway's side of the connection).
func mcpURLAllowed(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return false
	}
	switch u.Scheme {
	case "https":
		return true
	case "http":
		host := u.Hostname()
		if strings.EqualFold(host, "localhost") {
			return true
		}
		ip := net.ParseIP(host)
		return ip != nil && ip.IsLoopback()
	}
	return false
}

func allStrings(items []*jsonv.Value) bool {
	for _, it := range items {
		if it.Kind != jsonv.String {
			return false
		}
	}
	return true
}

// pairList checks an array of {name, value} objects: a non-empty name and a string value.
func pairList(v *jsonv.Value) bool {
	if v.Kind != jsonv.Array {
		return false
	}
	for _, it := range v.Arr {
		if it.Kind != jsonv.Object || len(it.Keys) != 2 {
			return false
		}
		name, ok := it.Get("name").StringValue()
		if !ok || name == "" {
			return false
		}
		if _, ok := it.Get("value").StringValue(); !ok {
			return false
		}
	}
	return true
}

// mcpKept is the list the gateway keeps for a session and sends on its own session/load (D-088).
// A request that sends no list keeps an empty one.
func mcpKept(params *jsonv.Value) *jsonv.Value {
	if v := params.Get("mcpServers"); v != nil && v.Kind == jsonv.Array {
		return v
	}
	return &jsonv.Value{Kind: jsonv.Array}
}

// keptMCPLocked is the list the gateway's own session/load sends for sid: the list the phone last
// sent, or an empty one when none is known (D-088). It must be called with a.mu held.
func (a *projectAgent) keptMCPLocked(sid string) *jsonv.Value {
	if v := a.mcp[sid]; v != nil {
		return v
	}
	return &jsonv.Value{Kind: jsonv.Array}
}

// checkMCPList runs the list check for a phone request before it is routed. It audits the method
// and the counts (accepted) or the refusal's reason (refused), and returns the refusal to send.
func (s *Server) checkMCPList(who audit.Who, method string, params *jsonv.Value) *rpcError {
	list := params.Get("mcpServers")
	counts, refusal := checkMCPServers(list)
	if refusal != nil {
		s.audit.Log("mcp_refused", with(who, audit.Fields{Method: method, Reason: refusal.Code}))
		return invalidParams("%s", refusal.Message)
	}
	if !list.IsNull() {
		reason := fmt.Sprintf("stdio=%d http=%d", counts.Stdio, counts.HTTP)
		if counts.AlwaysAllow > 0 {
			reason += fmt.Sprintf(" alwaysAllow=%d", counts.AlwaysAllow)
		}
		s.audit.Log("mcp_servers", with(who, audit.Fields{Method: method, Reason: reason}))
	}
	return nil
}
