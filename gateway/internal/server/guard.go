package server

// Protocol guard for client-to-agent messages (FR-6, FR-7, NFR-3).

import (
	"bytes"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"acpcode/gateway/internal/jsonv"
)

const (
	closeUnsupportedData = 1003
	closeInvalidPayload  = 1007
	closeTooBig          = 1009
	closeAgentExited     = 1011
)

type violation struct {
	code   int
	reason string
}

// parseClientMessage accepts exactly one JSON-RPC 2.0 object, with at most one trailing newline.
// It rejects arrays (batches), several lines and binary frames, because each of these could carry
// a second request past the cwd check.
func parseClientMessage(data []byte, isText bool, maxBytes int64) (*jsonv.Value, *violation) {
	if !isText {
		return nil, &violation{closeUnsupportedData, "text frames only"}
	}
	if int64(len(data)) > maxBytes {
		return nil, &violation{closeTooBig, "message too big"}
	}
	if !utf8.Valid(data) {
		return nil, &violation{closeInvalidPayload, "invalid UTF-8"}
	}
	if bytes.HasSuffix(data, []byte("\r\n")) {
		data = data[:len(data)-2]
	} else if bytes.HasSuffix(data, []byte("\n")) {
		data = data[:len(data)-1]
	}
	if bytes.ContainsAny(data, "\r\n") {
		return nil, &violation{closeInvalidPayload, "one JSON object per message"}
	}
	msg, err := jsonv.Parse(data)
	if err != nil {
		return nil, &violation{closeInvalidPayload, "invalid JSON"}
	}
	if msg.Kind != jsonv.Object {
		return nil, &violation{closeInvalidPayload, "JSON-RPC object required"}
	}
	if v, ok := msg.Get("jsonrpc").StringValue(); !ok || v != "2.0" {
		return nil, &violation{closeInvalidPayload, `jsonrpc must be "2.0"`}
	}
	return msg, nil
}

// resolveRoots resolves the configured roots once. A root that does not exist is skipped, so it
// allows nothing.
func resolveRoots(roots []string) []string {
	var out []string
	for _, root := range roots {
		if real, err := realpath(root); err == nil {
			out = append(out, real)
		}
	}
	return out
}

func realpath(p string) (string, error) {
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", err
	}
	return filepath.Abs(resolved)
}

// isInsideRoots is true when path (already a realpath) is a root or inside one.
func isInsideRoots(path string, roots []string) bool {
	for _, root := range roots {
		prefix := root
		if !strings.HasSuffix(prefix, string(filepath.Separator)) {
			prefix += string(filepath.Separator)
		}
		if path == root || strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}

// cwdAllowed checks params.cwd on any message. It is allowed when absent or null, or when it is
// an absolute path whose realpath is inside a root.
func cwdAllowed(msg *jsonv.Value, roots []string) bool {
	cwd := msg.Get("params").Get("cwd")
	if cwd.IsNull() {
		return true
	}
	s, ok := cwd.StringValue()
	if !ok || !filepath.IsAbs(s) {
		return false
	}
	real, err := realpath(s)
	if err != nil {
		return false // missing path or permission error
	}
	return isInsideRoots(real, roots)
}

// cwdRejection is the JSON-RPC error response for a refused request.
func cwdRejection(id *jsonv.Value) []byte {
	buf := []byte(`{"jsonrpc":"2.0","id":`)
	buf = id.AppendTo(buf)
	return append(buf, `,"error":{"code":-32602,"message":"cwd is outside the allowed project roots"}}`...)
}
