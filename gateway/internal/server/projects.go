package server

// Gateway extension methods (D-002, SPEC 6.2). The gateway answers every `_agmente/*` request
// itself; none reaches the agent. This file has the project registry (FR-17, PLAN 3.3).

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const (
	rpcMethodNotFound = -32601
	rpcInvalidParams  = -32602
	rpcInternal       = -32603
)

// rpcError is a JSON-RPC error for the phone.
type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func (e *rpcError) Error() string { return e.Message }

func invalidParams(format string, args ...any) *rpcError {
	return &rpcError{Code: rpcInvalidParams, Message: fmt.Sprintf(format, args...)}
}

// projectJSON is a project as the phone sees it (SPEC 6.2).
type projectJSON struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Path        string  `json:"path"`
	DefaultMode *string `json:"defaultMode"`
	// DenyPaths are the project's additions to the secret deny-list (D-050); left out when none.
	DenyPaths []string `json:"denyPaths,omitempty"`
	// WatchSkip are the folders the git watcher leaves out, added to the built-in list (D-065);
	// left out when none.
	WatchSkip []string `json:"watchSkip,omitempty"`
}

func toProjectJSON(p store.Project) projectJSON {
	out := projectJSON{ID: p.ID, Name: p.Name, Path: p.Path, DenyPaths: p.DenyPaths, WatchSkip: p.WatchSkip}
	if p.DefaultMode != "" {
		mode := p.DefaultMode
		out.DefaultMode = &mode
	}
	return out
}

var modeID = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,31}$`)

const maxProjectName = 100

// handleExtension answers one `_agmente/*` request. It returns the result to send, or an error.
func (s *Server) handleExtension(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (any, *rpcError) {
	switch method {
	case "_agmente/projects/list":
		projects, err := s.store.Projects(ctx)
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
		}
		out := make([]projectJSON, 0, len(projects))
		for _, p := range projects {
			out = append(out, toProjectJSON(p))
		}
		return map[string]any{"projects": out}, nil
	case "_agmente/projects/create":
		p, rerr := s.createProject(ctx, params)
		if rerr != nil {
			return nil, rerr
		}
		s.audit.Log("project_created", with(who, audit.Fields{Project: p.ID}))
		return map[string]any{"project": toProjectJSON(*p)}, nil
	case "_agmente/projects/addDenyPaths":
		return s.addProjectList(ctx, who, params, "denyPaths")
	case "_agmente/projects/addWatchSkip":
		return s.addProjectList(ctx, who, params, "watchSkip")
	case "_agmente/sessions/index":
		return s.sessionIndex(ctx, who, params)
	case "_agmente/sessions/read":
		return s.markRead(ctx, who, params)
	case "_agmente/approvals/pending":
		return s.pendingApprovals()
	case "_agmente/approvals/answer":
		return s.answerApproval(ctx, who, params)
	case "_agmente/push/register":
		return s.pushRegister(ctx, who, params)
	case "_agmente/push/unregister":
		return s.pushUnregister(ctx, who)
	case "_agmente/git/status":
		return s.gitStatus(ctx, params)
	case "_agmente/git/diff":
		return s.gitDiff(ctx, params)
	case "_agmente/git/turnDiff":
		return s.gitTurnDiff(ctx, params)
	case "_agmente/git/log":
		return s.gitLog(ctx, params)
	default:
		return nil, &rpcError{Code: rpcMethodNotFound, Message: "Method not found"}
	}
}

func with(who audit.Who, f audit.Fields) audit.Fields {
	f.Identity, f.Device, f.Client, f.Conn = who.Identity, who.Device, who.Client, who.Conn
	return f
}

// createProject validates and registers a project (FR-17, T-25). The path must be an existing
// directory whose realpath is inside a configured root; the realpath is what is stored. It then
// creates the project's HOME under stateDir and trusts the project folder for Bob (D-013).
func (s *Server) createProject(ctx context.Context, params *jsonv.Value) (*store.Project, *rpcError) {
	name, ok := params.Get("name").StringValue()
	name = strings.TrimSpace(name)
	if !ok || name == "" || utf8.RuneCountInString(name) > maxProjectName || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return nil, invalidParams("name must be 1 to %d characters with no control characters", maxProjectName)
	}
	mode := ""
	if m := params.Get("defaultMode"); !m.IsNull() {
		v, ok := m.StringValue()
		if !ok || !modeID.MatchString(v) {
			return nil, invalidParams("defaultMode must be a mode id such as \"agent\", \"plan\" or \"ask\"")
		}
		mode = v
	}
	var deny []string
	if dv := params.Get("denyPaths"); !dv.IsNull() {
		in, rerr := stringList(dv, "denyPaths must be a list of glob strings")
		if rerr != nil {
			return nil, rerr
		}
		if deny, rerr = checkedList("denyPaths", in, validateDenyPaths); rerr != nil {
			return nil, rerr
		}
	}
	var skip []string
	if wv := params.Get("watchSkip"); !wv.IsNull() {
		in, rerr := stringList(wv, "watchSkip must be a list of folder names")
		if rerr != nil {
			return nil, rerr
		}
		if skip, rerr = checkedList("watchSkip", in, validateWatchSkip); rerr != nil {
			return nil, rerr
		}
	}
	rawPath, ok := params.Get("path").StringValue()
	if !ok || !filepath.IsAbs(rawPath) {
		return nil, invalidParams("path must be an absolute path")
	}
	real, err := realpath(rawPath)
	if err != nil {
		return nil, invalidParams("path does not exist")
	}
	if info, err := os.Stat(real); err != nil || !info.IsDir() {
		return nil, invalidParams("path must be a directory")
	}
	if !isInsideRoots(real, s.roots) {
		return nil, invalidParams("path is outside the allowed project roots")
	}
	if existing, err := s.store.ProjectByPath(ctx, real); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	} else if existing != nil {
		return nil, &rpcError{Code: rpcInvalidParams, Message: store.ErrDuplicatePath.Error(), Data: map[string]string{"projectId": existing.ID}}
	}

	id, err := newProjectID()
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot create a project id"}
	}
	home := s.projectHome(id)
	if err := prepareHome(home, real); err != nil {
		_ = os.RemoveAll(home)
		return nil, &rpcError{Code: rpcInternal, Message: "cannot create the project home"}
	}
	p := store.Project{ID: id, Name: name, Path: real, DefaultMode: mode, DenyPaths: deny, WatchSkip: skip, Created: time.Now().UTC().Format("2006-01-02T15:04:05.000Z")}
	if err := s.store.CreateProject(ctx, p); err != nil {
		_ = os.RemoveAll(home)
		if errors.Is(err, store.ErrDuplicatePath) {
			return nil, &rpcError{Code: rpcInvalidParams, Message: err.Error()}
		}
		return nil, &rpcError{Code: rpcInternal, Message: "cannot save the project"}
	}
	return &p, nil
}

// stringList reads a JSON array of strings. msg is the error for anything else.
func stringList(v *jsonv.Value, msg string) ([]string, *rpcError) {
	if v.Kind != jsonv.Array {
		return nil, invalidParams("%s", msg)
	}
	out := []string{}
	for _, item := range v.Arr {
		str, ok := item.StringValue()
		if !ok {
			return nil, invalidParams("%s", msg)
		}
		out = append(out, str)
	}
	return out, nil
}

// checkedList runs one of the two validators on input from the phone (D-066: the same rules at
// create and in the additive methods). Its error names the list.
func checkedList(field string, in []string, validate func([]string) ([]string, error)) ([]string, *rpcError) {
	out, err := validate(in)
	if err != nil {
		return nil, invalidParams("%s", err.Error())
	}
	return out, nil
}

// addProjectList adds entries to a project's deny-list or watch skip list (D-066). It only adds:
// no input removes an entry, the built-in lists always apply, and the 32-entry cap counts the
// stored total. A refused request changes nothing.
func (s *Server) addProjectList(ctx context.Context, who audit.Who, params *jsonv.Value, field string) (any, *rpcError) {
	id, ok := params.Get("projectId").StringValue()
	if !ok || id == "" {
		return nil, invalidParams("projectId is required")
	}
	v := params.Get(field)
	if v.IsNull() {
		return nil, invalidParams("%s is required and must be a list of strings", field)
	}
	in, rerr := stringList(v, field+" must be a list of strings")
	if rerr != nil {
		return nil, rerr
	}
	validate := validateDenyPaths
	if field == "watchSkip" {
		validate = validateWatchSkip
	}
	add, rerr := checkedList(field, in, validate)
	if rerr != nil {
		return nil, rerr
	}
	var refused error
	p, err := s.store.UpdateProjectLists(ctx, id, func(cur *store.Project) error {
		target := &cur.DenyPaths
		if field == "watchSkip" {
			target = &cur.WatchSkip
		}
		merged, err := mergeEntries(field, *target, add)
		if err != nil {
			refused = err
			return err
		}
		*target = merged
		return nil
	})
	if refused != nil {
		return nil, invalidParams("%s", refused.Error())
	}
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot save the project"}
	}
	if p == nil {
		return nil, invalidParams("unknown project")
	}
	s.audit.Log("project_updated", with(who, audit.Fields{Project: id}))
	return map[string]any{"project": toProjectJSON(*p)}, nil
}

// projectHome is the project's HOME for its agent: <stateDir>/homes/<projectId>.
func (s *Server) projectHome(id string) string {
	return filepath.Join(s.cfg.StateDir, "homes", id)
}

// newProjectID returns 12 lowercase hex characters. It is safe in a container name
// (agmente-<projectId>, D-015) and in a path.
func newProjectID() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// prepareHome creates the HOME folder (0700) and writes Bob's trust file for the project folder,
// so the project keeps working if Bob brings back the 2.0.7 default of refusing unlisted folders
// (F-15, D-013). The trusted path is the path the agent sees; with the host runner that is the
// host path (task 3.4 sets the container path for the podman runner).
func prepareHome(home, agentPath string) error {
	bob := filepath.Join(home, ".bob")
	if err := os.MkdirAll(bob, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(home, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(map[string]any{"version": 1, "folders": map[string]string{agentPath: "TRUST_FOLDER"}})
	if err != nil {
		return err
	}
	tmp := filepath.Join(bob, ".trustedFolders.json.tmp")
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(bob, "trustedFolders.json"))
}

// rpcResult and rpcErrorResponse build the JSON-RPC response for a request id.
func rpcResult(id *jsonv.Value, result any) []byte {
	body, err := json.Marshal(result)
	if err != nil {
		return rpcErrorResponse(id, &rpcError{Code: rpcInternal, Message: "cannot encode the result"})
	}
	buf := []byte(`{"jsonrpc":"2.0","id":`)
	buf = id.AppendTo(buf)
	buf = append(buf, `,"result":`...)
	buf = append(buf, body...)
	return append(buf, '}')
}

func rpcErrorResponse(id *jsonv.Value, e *rpcError) []byte {
	body, _ := json.Marshal(e)
	buf := []byte(`{"jsonrpc":"2.0","id":`)
	buf = id.AppendTo(buf)
	buf = append(buf, `,"error":`...)
	buf = append(buf, body...)
	return append(buf, '}')
}
