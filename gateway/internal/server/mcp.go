package server

// MCP config methods (FR-41, F-16, D-084, D-085, D-089, PLAN 6A.2). The gateway lists the servers
// in Bob's MCP config files and sets a server's `disabled` flag and, when the phone sends it, its
// `alwaysAllow` list (D-089). It never adds a server, and never runs anything: the files are read and written on the host through the
// project folder and the project's home (D-085). The parsing and the atomic write are in
// internal/mcpconf; this file holds the path rules and the methods.

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"unicode"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/mcpconf"
	"agmente/gateway/internal/store"
)

// mcpMu serialises the read-modify-write of a config file, so two sets cannot lose each other's
// change. It is held only inside the MCP methods.
var mcpMu sync.Mutex

const (
	mcpSourceProject = "project"
	mcpSourceHome    = "home"
	maxMCPName       = 200
)

// mcpFile is one config file the gateway may read or write. The file must stay inside anchor,
// and no component between anchor and the file may be a link (D-085).
type mcpFile struct {
	source string   // "project" or "home"
	anchor string   // the project folder, or the project's home
	rel    []string // the components below anchor
}

// mcpFiles lists the two files for a project, the project's first.
func (s *Server) mcpFiles(p *store.Project) []mcpFile {
	return []mcpFile{
		{source: mcpSourceProject, anchor: p.Path, rel: []string{".bob", "mcp.json"}},
		{source: mcpSourceHome, anchor: s.projectHome(p.ID), rel: []string{".bob", "settings", "mcp.json"}},
	}
}

// errMCPMissing means a folder or the file does not exist: there is no config from this source.
var errMCPMissing = errors.New("mcp config missing")

// mcpRefused is a refusal with a reason from a fixed set, as the audit log and the phone see it.
type mcpRefused string

func (r mcpRefused) Error() string { return string(r) }

// mcpPath checks every component from the anchor to the file before the file is opened: none
// may be a link, the folders must be folders, and after realpath the file must be inside the
// anchor. A missing component gives errMCPMissing.
func mcpPath(f mcpFile) (string, error) {
	info, err := os.Lstat(f.anchor)
	if errors.Is(err, os.ErrNotExist) {
		return "", errMCPMissing
	}
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return "", mcpRefused("symlink")
	}
	if !info.IsDir() {
		return "", mcpRefused("not_directory")
	}
	cur := f.anchor
	for i, part := range f.rel {
		cur = filepath.Join(cur, part)
		info, err := os.Lstat(cur)
		if errors.Is(err, os.ErrNotExist) {
			return "", errMCPMissing
		}
		if err != nil {
			return "", err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", mcpRefused("symlink")
		}
		if i < len(f.rel)-1 && !info.IsDir() {
			return "", mcpRefused("not_directory")
		}
	}
	real, err := filepath.EvalSymlinks(cur)
	if err != nil {
		return "", err
	}
	root, err := filepath.EvalSymlinks(f.anchor)
	if err != nil {
		return "", err
	}
	if !isInsideRoots(real, []string{root}) {
		return "", mcpRefused("outside_root")
	}
	return cur, nil
}

// mcpDoc is a config file read and parsed.
type mcpDoc struct {
	path string
	file *mcpconf.File
}

// mcpLoad reads one source. A missing source gives (nil, nil): there are no servers from it.
func mcpLoad(f mcpFile) (*mcpDoc, error) {
	path, err := mcpPath(f)
	if errors.Is(err, errMCPMissing) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	data, err := mcpconf.Read(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	parsed, err := mcpconf.Parse(data)
	if err != nil {
		return nil, err
	}
	return &mcpDoc{path: path, file: parsed}, nil
}

// refusalReason maps a read, parse or path error to the fixed reason set.
func refusalReason(err error) string {
	var refused mcpRefused
	switch {
	case errors.As(err, &refused):
		return string(refused)
	case errors.Is(err, mcpconf.ErrSymlink):
		return "symlink"
	case errors.Is(err, mcpconf.ErrNotRegular):
		return "not_regular"
	case errors.Is(err, mcpconf.ErrTooLarge):
		return "too_large"
	case errors.Is(err, mcpconf.ErrInvalidJSON):
		return "invalid_json"
	case errors.Is(err, mcpconf.ErrInvalid):
		return "invalid_config"
	}
	return ""
}

// mcpServerJSON is one server as the phone sees it. No headers, URLs or arguments are in it.
type mcpServerJSON struct {
	Name        string `json:"name"`
	Disabled    bool   `json:"disabled"`
	AlwaysAllow int    `json:"alwaysAllow"` // the count of names only (D-089)
	Source      string `json:"source"`
	Transport   string `json:"transport"`
}

// mcpProject reads the required projectId. The config lives in a project's folder and home, so
// a request without one has nothing to read.
func (s *Server) mcpProject(ctx context.Context, params *jsonv.Value) (*store.Project, *rpcError) {
	pid, ok := params.Get("projectId").StringValue()
	if !ok || pid == "" {
		return nil, invalidParams("projectId is required")
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	return p, nil
}

// mcpServers lists the servers of both sources. A refused file refuses the whole list, and the
// refusal is audited with the reason only.
func (s *Server) mcpServers(who audit.Who, p *store.Project, sources ...string) ([]mcpServerJSON, *rpcError) {
	out := make([]mcpServerJSON, 0)
	for _, f := range s.mcpFiles(p) {
		if len(sources) > 0 && !containsString(sources, f.source) {
			continue
		}
		doc, err := mcpLoad(f)
		if err != nil {
			reason := refusalReason(err)
			if reason == "" {
				return nil, &rpcError{Code: rpcInternal, Message: "cannot read the MCP config"}
			}
			s.audit.Log("mcp_refused", with(who, audit.Fields{Project: p.ID, Reason: reason}))
			return nil, invalidParams("MCP config file refused: %s", reason)
		}
		if doc == nil {
			continue
		}
		for _, sv := range doc.file.Servers() {
			out = append(out, mcpServerJSON{
				Name: sv.Name, Disabled: sv.Disabled, AlwaysAllow: sv.AlwaysAllow,
				Source: f.source, Transport: sv.Transport,
			})
		}
	}
	return out, nil
}

func containsString(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

// mcpList answers _agmente/mcp/list {projectId}.
func (s *Server) mcpList(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	p, rerr := s.mcpProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	mcpMu.Lock()
	defer mcpMu.Unlock()
	servers, rerr := s.mcpServers(who, p)
	if rerr != nil {
		return nil, rerr
	}
	return map[string]any{"servers": servers}, nil
}

// validMCPName is true for a server name of 1 to 200 bytes, valid UTF-8, with no control character.
func validMCPName(name string) bool {
	if name == "" || len(name) > maxMCPName || !utf8.ValidString(name) {
		return false
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// mcpSet answers _agmente/mcp/set {projectId, name, disabled, alwaysAllow?, source?}. It changes
// `disabled`, and `alwaysAllow` when the phone sends it, of a server already in the file and
// nothing else (D-089). source ("project" or "home") picks the file; left
// out, the project's file is tried first, then the home's.
func (s *Server) mcpSet(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	p, rerr := s.mcpProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	name, ok := params.Get("name").StringValue()
	if !ok || !validMCPName(name) {
		return nil, invalidParams("name must be 1 to %d characters with no control characters", maxMCPName)
	}
	// alwaysAllow is optional. Absent or null leaves the file's list as it is. When the phone sends
	// it, it must be an array of tool names (D-089), checked before anything is written.
	var allow []string
	setAllow := false
	if av := params.Get("alwaysAllow"); !av.IsNull() {
		names, err := alwaysAllowNames(av)
		if err != nil {
			return nil, invalidParams("%s", err.Error())
		}
		allow, setAllow = names, true
	}
	dv := params.Get("disabled")
	if dv == nil || dv.Kind != jsonv.Bool {
		return nil, invalidParams("disabled must be true or false")
	}
	disabled := dv.B
	var sources []string
	if sv := params.Get("source"); !sv.IsNull() {
		src, ok := sv.StringValue()
		if !ok || (src != mcpSourceProject && src != mcpSourceHome) {
			return nil, invalidParams("source must be \"project\" or \"home\"")
		}
		sources = []string{src}
	}

	mcpMu.Lock()
	defer mcpMu.Unlock()
	for _, f := range s.mcpFiles(p) {
		if len(sources) > 0 && !containsString(sources, f.source) {
			continue
		}
		doc, err := mcpLoad(f)
		if err != nil {
			reason := refusalReason(err)
			if reason == "" {
				return nil, &rpcError{Code: rpcInternal, Message: "cannot read the MCP config"}
			}
			s.audit.Log("mcp_refused", with(who, audit.Fields{Project: p.ID, Reason: reason}))
			return nil, invalidParams("MCP config file refused: %s", reason)
		}
		if doc == nil || !doc.file.Has(name) {
			continue
		}
		if err := doc.file.SetDisabled(name, disabled); err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot change the MCP config"}
		}
		if setAllow {
			if err := doc.file.SetAlwaysAllow(name, allow); err != nil {
				return nil, &rpcError{Code: rpcInternal, Message: "cannot change the MCP config"}
			}
		}
		out, err := doc.file.Marshal()
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot change the MCP config"}
		}
		if err := mcpconf.Write(doc.path, out); err != nil {
			reason := refusalReason(err)
			if reason == "" {
				s.audit.Log("mcp_refused", with(who, audit.Fields{Project: p.ID, Reason: "write"}))
				return nil, &rpcError{Code: rpcInternal, Message: "cannot write the MCP config"}
			}
			s.audit.Log("mcp_refused", with(who, audit.Fields{Project: p.ID, Reason: reason}))
			return nil, invalidParams("MCP config file refused: %s", reason)
		}
		// The audit line holds the project, the server name and the values: a count for alwaysAllow,
		// never a tool name and never the file (FR-9, D-089).
		reason := fmt.Sprintf("name=%s disabled=%t", name, disabled)
		if setAllow {
			reason += fmt.Sprintf(" alwaysAllow=%d", len(allow))
		}
		s.audit.Log("mcp_set", with(who, audit.Fields{Project: p.ID, Reason: reason}))
		servers, rerr := s.mcpServers(who, p)
		if rerr != nil {
			return nil, rerr
		}
		return map[string]any{"servers": servers}, nil
	}
	return nil, invalidParams("no MCP server with that name is in the config (the gateway does not add servers, D-084)")
}

// serveMCPConfig answers the two MCP config methods. handled is false for any other method, so the
// caller can go on to its own list. The main session wires it into handleExtension.
func (s *Server) serveMCPConfig(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (result any, rerr *rpcError, handled bool) {
	switch method {
	case "_agmente/mcp/list":
		result, rerr = s.mcpList(ctx, who, params)
		return result, rerr, true
	case "_agmente/mcp/set":
		result, rerr = s.mcpSet(ctx, who, params)
		return result, rerr, true
	}
	return nil, nil, false
}
