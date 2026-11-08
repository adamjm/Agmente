package connector

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"

	"acpcode/gateway/internal/audit"
)

// protocolVersion is the MCP revision this endpoint speaks by default (MCP 2025-11-25).
const protocolVersion = "2025-11-25"

// supportedVersions are the MCP revisions the endpoint negotiates. The header MCP-Protocol-Version
// must name one of them (MCP Transports, Protocol Version Header).
var supportedVersions = map[string]bool{"2025-11-25": true, "2025-06-18": true, "2025-03-26": true}

// maxMCPBody bounds one POST /mcp body. A prompt is capped at maxPromptBytes; the rest of the room
// is JSON escaping and the envelope.
const maxMCPBody = 256 * 1024

// rpcRequest is one JSON-RPC message from the client: a request, a notification or a response.
type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  *string         `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   json.RawMessage `json:"error"`
}

// serveMCP answers one POST /mcp. Every message is its own POST (Streamable HTTP, Sending Messages).
// The endpoint is stateless: it issues no MCP-Session-Id, so every request carries the bearer token.
func (c *Connector) serveMCP(w http.ResponseWriter, r *http.Request) {
	g := c.authenticate(w, r)
	if g == nil {
		return
	}
	if v := r.Header.Get("MCP-Protocol-Version"); v != "" && !supportedVersions[v] {
		writeRPCError(w, http.StatusBadRequest, nil, &RPCError{Code: rpcInvalidRequest, Message: "unsupported MCP-Protocol-Version: " + v})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMCPBody)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeRPCError(w, http.StatusRequestEntityTooLarge, nil, &RPCError{Code: rpcInvalidRequest, Message: "request body is too large"})
		return
	}
	data = bytes.TrimSpace(data)
	if len(data) > 0 && data[0] == '[' {
		writeRPCError(w, http.StatusBadRequest, nil, &RPCError{Code: rpcInvalidRequest, Message: "batch requests are not supported"})
		return
	}
	var req rpcRequest
	if err := json.Unmarshal(data, &req); err != nil {
		writeRPCError(w, http.StatusBadRequest, nil, &RPCError{Code: rpcParseError, Message: "parse error"})
		return
	}
	if req.Method == nil {
		// A response to a request the gateway sent (none in this connector) or an invalid message.
		if len(req.Result) > 0 || len(req.Error) > 0 {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		writeRPCError(w, http.StatusBadRequest, nil, &RPCError{Code: rpcInvalidRequest, Message: "not a JSON-RPC request"})
		return
	}
	if len(req.ID) == 0 {
		// A notification: accepted, nothing to return (Sending Messages, step 4).
		w.WriteHeader(http.StatusAccepted)
		return
	}
	result, rerr := c.dispatch(g, *req.Method, req.Params)
	if rerr != nil {
		writeRPCError(w, http.StatusOK, req.ID, rerr)
		return
	}
	writeRPCResult(w, req.ID, result)
}

// dispatch answers one request method. Unknown methods are method-not-found.
func (c *Connector) dispatch(g *Grant, method string, params json.RawMessage) (any, *RPCError) {
	switch method {
	case "initialize":
		return c.initializeResult(params), nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		return c.toolList(), nil
	case "tools/call":
		return c.callTool(g, params)
	}
	return nil, &RPCError{Code: rpcMethodNotFound, Message: "method not found: " + method}
}

func (c *Connector) initializeResult(params json.RawMessage) map[string]any {
	var in struct {
		ProtocolVersion string `json:"protocolVersion"`
	}
	_ = json.Unmarshal(params, &in)
	version := protocolVersion
	if supportedVersions[in.ProtocolVersion] {
		version = in.ProtocolVersion // negotiate: echo the client's revision when this endpoint speaks it
	}
	return map[string]any{
		"protocolVersion": version,
		"capabilities":    map[string]any{"tools": map[string]any{}},
		"serverInfo":      map[string]any{"name": "acpcode-connector", "version": c.opts.Version},
	}
}

// callTool runs one tool. A refused call is a tool error (isError true), so the model sees the
// plain reason. An unknown tool name is a protocol error.
func (c *Connector) callTool(g *Grant, params json.RawMessage) (any, *RPCError) {
	var in struct {
		Name      string                     `json:"name"`
		Arguments map[string]json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(params, &in); err != nil || in.Name == "" {
		return nil, invalidParams("tools/call needs a tool name")
	}
	spec := findTool(in.Name)
	if spec == nil {
		return nil, invalidParams("unknown tool: " + in.Name)
	}
	c.audit.Log("connector_mcp", audit.Fields{Method: "tools/call", Reason: in.Name + " grant:" + g.ID})
	out, err := spec.call(c, g, in.Arguments)
	if err != nil {
		return toolResult(err.Error(), true), nil
	}
	text, merr := json.Marshal(out)
	if merr != nil {
		return toolResult("internal error", true), nil
	}
	return toolResult(string(text), false), nil
}

func toolResult(text string, isError bool) map[string]any {
	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": text}},
		"isError": isError,
	}
}

func writeRPCResult(w http.ResponseWriter, id json.RawMessage, result any) {
	writeJSONRPC(w, http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

// writeRPCError writes a JSON-RPC error. A nil id is sent as null (parse and envelope errors).
func writeRPCError(w http.ResponseWriter, status int, id json.RawMessage, rerr *RPCError) {
	if len(id) == 0 {
		id = json.RawMessage("null")
	}
	writeJSONRPC(w, status, map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": rerr.Code, "message": rerr.Message}})
}

func writeJSONRPC(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

const (
	rpcParseError     = -32700
	rpcInvalidRequest = -32600
)
