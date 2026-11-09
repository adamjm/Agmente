package server

// The token scope check (config.Token.Scope). handleMessage runs it after the cwd check and before
// the method switch, so every method, the _acpcode/ branch, the permission answers and the connector
// path all pass through one policy. Fail closed: an unknown scope, or an empty one, allows nothing.

import (
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
)

// rpcForbidden is -32003: the token's scope does not allow the call. It is not used for a bad
// parameter (-32602) or a state refusal (-32001).
const rpcForbidden = -32003

// intentMethods are the calls an intent token may make: start a session with a prompt, continue one,
// list projects, and the handshake. Everything else is refused, including session/load (it replays a
// transcript), session/list and every _acpcode/ read or write that is not listed here.
var intentMethods = map[string]bool{
	"initialize":               true,
	"_acpcode/projects/list":   true,
	"_acpcode/sessions/create": true,
	"_acpcode/sessions/prompt": true,
	"session/new":              true,
	"session/prompt":           true,
}

// connectorMethods are the calls a connector token may make: the prompt path only.
var connectorMethods = map[string]bool{
	"session/prompt": true,
}

// scopeDenial returns the refusal for a request from a token of this scope, or nil when the request
// may go on. method is "" for a response (a permission answer). Only the full scope may approve or
// revoke a connector pairing or grant (D-097): the other scopes' lists do not name those methods.
func scopeDenial(scope, method string, params *jsonv.Value) *rpcError {
	switch scope {
	case config.ScopeFull:
		return nil
	case config.ScopeIntent:
		if !intentMethods[method] {
			return forbidden(method)
		}
	case config.ScopeConnector:
		if !connectorMethods[method] {
			return forbidden(method)
		}
	default:
		return forbidden(method) // an unknown or empty scope: fail closed
	}
	// The phone's MCP list is the phone's to choose (D-084). An intent token starts a session with
	// the gateway's own list only.
	if (method == "session/new" || method == "_acpcode/sessions/create") && !params.Get("mcpServers").IsNull() {
		return &rpcError{Code: rpcForbidden, Message: "this token may not pass mcpServers"}
	}
	return nil
}

func forbidden(method string) *rpcError {
	return &rpcError{Code: rpcForbidden, Message: "this token may not call " + method}
}
