package server

// Gateway extension methods (D-002, SPEC 6.2). The gateway answers every `_acpcode/*` request
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

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
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

// handleExtension answers one `_acpcode/*` request. It returns the result to send, or an error.
func (s *Server) handleExtension(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (any, *rpcError) {
	if result, rerr, handled := s.serveMCPConfig(ctx, who, method, params); handled {
		return result, rerr
	}
	if result, rerr, handled := s.serveSkills(ctx, who, method, params); handled {
		return result, rerr
	}
	if result, rerr, handled := s.serveUploads(ctx, who, method, params); handled {
		return result, rerr
	}
	switch method {
	case "_acpcode/projects/list":
		projects, err := s.store.Projects(ctx)
		if err != nil {
			return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
		}
		s.watchProjectStates(ctx, who.Conn, "") // C2: this socket is told the agent state of the projects it lists
		out := make([]projectJSON, 0, len(projects))
		for _, p := range projects {
			out = append(out, toProjectJSON(p))
		}
		return map[string]any{"projects": out}, nil
	case "_acpcode/projects/create":
		p, folderCreated, gitRes, rerr := s.createProject(ctx, params)
		if rerr != nil {
			return nil, rerr
		}
		s.audit.Log("project_created", with(who, audit.Fields{Project: p.ID, FolderCreated: folderCreated}))
		out := map[string]any{"project": toProjectJSON(*p)}
		if gitRes != nil { // D-105: only a create that asked for git has this field
			reason := "no_remote"
			if gitRes.Remote != nil {
				reason = "remote"
			}
			s.audit.Log("project_git_init", with(who, audit.Fields{Project: p.ID, Reason: reason}))
			out["git"] = gitRes
		}
		return out, nil
	case "_acpcode/projects/roots":
		return s.projectRoots(), nil
	case "_acpcode/projects/addDenyPaths":
		return s.addProjectList(ctx, who, params, "denyPaths")
	case "_acpcode/projects/addWatchSkip":
		return s.addProjectList(ctx, who, params, "watchSkip")
	case "_acpcode/sessions/index":
		return s.sessionIndex(ctx, who, params)
	case "_acpcode/sessions/read":
		return s.markRead(ctx, who, params)
	case "_acpcode/approvals/pending":
		return s.pendingApprovals()
	case "_acpcode/approvals/answer":
		return s.answerApproval(ctx, who, params)
	case "_acpcode/elicitation/answer":
		return s.answerElicitation(ctx, who, params)
	case "_acpcode/push/register":
		return s.pushRegister(ctx, who, params)
	case "_acpcode/push/unregister":
		return s.pushUnregister(ctx, who)
	case "_acpcode/git/status":
		return s.gitStatus(ctx, params)
	case "_acpcode/git/diff":
		return s.gitDiff(ctx, params)
	case "_acpcode/git/turnDiff":
		return s.gitTurnDiff(ctx, params)
	case "_acpcode/git/log":
		return s.gitLog(ctx, params)
	case "_acpcode/git/credentials/list":
		return s.listGitCredentials(ctx)
	case "_acpcode/git/credentials/set":
		return s.setGitCredential(ctx, who, params)
	case "_acpcode/git/credentials/delete":
		return s.deleteGitCredential(ctx, who, params)
	case "_acpcode/git/push":
		return s.gitPush(ctx, who, params)
	case "_acpcode/files/url":
		return s.fileURL(ctx, who, params)
	default:
		return nil, &rpcError{Code: rpcMethodNotFound, Message: "Method not found"}
	}
}

func with(who audit.Who, f audit.Fields) audit.Fields {
	f.Identity, f.Device, f.Client, f.Conn = who.Identity, who.Device, who.Client, who.Conn
	f.Source, f.Grant = who.Source, who.Grant // a connector prompt's lines name the source and grant (D-096)
	f.Scope = who.Scope
	return f
}

// createProject validates and registers a project (FR-17, T-25). The path must be an existing
// directory whose realpath is inside a configured root; the realpath is what is stored. It then
// creates the project's HOME under stateDir and trusts the project folder for Bob (D-013).
//
// With createFolder true the gateway makes <path>/<name> first, and <name> is the project's name
// (D-091). The bool result is true when this call created the folder. With gitInit the new folder
// gets `git init` and, with gitRemote, an origin; the git result is then non-nil (D-105). Every
// check, git's included, runs before the folder is made.
func (s *Server) createProject(ctx context.Context, params *jsonv.Value) (*store.Project, bool, *gitInitResult, *rpcError) {
	createFolder, rerr := folderFlag(params.Get("createFolder"))
	if rerr != nil {
		return nil, false, nil, rerr
	}
	rawName, nameOK := params.Get("name").StringValue()
	name := strings.TrimSpace(rawName)
	switch {
	case createFolder:
		if !nameOK {
			return nil, false, nil, invalidParams("folder name must be a string")
		}
		if rerr := checkFolderName(rawName); rerr != nil {
			return nil, false, nil, rerr
		}
		name = rawName
	case !nameOK || name == "" || utf8.RuneCountInString(name) > maxProjectName || strings.IndexFunc(name, unicode.IsControl) >= 0:
		return nil, false, nil, invalidParams("name must be 1 to %d characters with no control characters", maxProjectName)
	}
	mode, deny, skip, rerr := parseProjectOptions(params)
	if rerr != nil {
		return nil, false, nil, rerr
	}
	gitOpts, rerr := parseGitOptions(params)
	if rerr != nil {
		return nil, false, nil, rerr
	}
	if _, rerr := s.checkGitOptions(ctx, gitOpts, createFolder); rerr != nil {
		return nil, false, nil, rerr
	}
	if createFolder {
		p, gitRes, rerr := s.createFolderProject(ctx, params, name, mode, deny, skip, gitOpts)
		return p, true, gitRes, rerr
	}
	rawPath, ok := params.Get("path").StringValue()
	if !ok || !filepath.IsAbs(rawPath) {
		return nil, false, nil, invalidParams("path must be an absolute path")
	}
	real, err := realpath(rawPath)
	if err != nil {
		return nil, false, nil, invalidParams("path does not exist")
	}
	if info, err := os.Stat(real); err != nil || !info.IsDir() {
		return nil, false, nil, invalidParams("path must be a directory")
	}
	if !isInsideRoots(real, s.roots) {
		return nil, false, nil, invalidParams("path is outside the allowed project roots")
	}
	if rerr := projectAboveHome(real); rerr != nil {
		return nil, false, nil, rerr
	}
	if existing, err := s.store.ProjectByPath(ctx, real); err != nil {
		return nil, false, nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	} else if existing != nil {
		return nil, false, nil, &rpcError{Code: rpcInvalidParams, Message: store.ErrDuplicatePath.Error(), Data: map[string]string{"projectId": existing.ID}}
	}
	p, rerr := s.registerProject(ctx, name, real, mode, deny, skip)
	return p, false, nil, rerr
}

// projectAboveHome refuses a project folder that is the home folder or a folder above it. It is the
// rule config.Validate applies to projects.roots, checked again at create. The error names the rule.
func projectAboveHome(real string) *rpcError {
	home, err := config.HomeFolder()
	if err != nil {
		return &rpcError{Code: rpcInternal, Message: "cannot read the home folder to check the project path"}
	}
	if config.AtOrAboveHome(real, home) {
		return invalidParams("path is the home folder or a folder above it. Rule: no project root at or above $HOME; choose a folder inside your home folder")
	}
	return nil
}

// parseProjectOptions reads the optional defaultMode, denyPaths and watchSkip of a create request
// (D-050, D-065). Each is checked the same way in both create modes.
func parseProjectOptions(params *jsonv.Value) (string, []string, []string, *rpcError) {
	mode := ""
	if m := params.Get("defaultMode"); !m.IsNull() {
		v, ok := m.StringValue()
		if !ok || !modeID.MatchString(v) {
			return "", nil, nil, invalidParams("defaultMode must be a mode id such as \"agent\", \"plan\" or \"ask\"")
		}
		mode = v
	}
	var deny []string
	if dv := params.Get("denyPaths"); !dv.IsNull() {
		in, rerr := stringList(dv, "denyPaths must be a list of glob strings")
		if rerr != nil {
			return "", nil, nil, rerr
		}
		if deny, rerr = checkedList("denyPaths", in, validateDenyPaths); rerr != nil {
			return "", nil, nil, rerr
		}
	}
	var skip []string
	if wv := params.Get("watchSkip"); !wv.IsNull() {
		in, rerr := stringList(wv, "watchSkip must be a list of folder names")
		if rerr != nil {
			return "", nil, nil, rerr
		}
		if skip, rerr = checkedList("watchSkip", in, validateWatchSkip); rerr != nil {
			return "", nil, nil, rerr
		}
	}
	return mode, deny, skip, nil
}

// registerProject stores a checked project folder under a new id (FR-17, D-024). It creates the
// project's HOME and trusts the folder for Bob (D-013). It is the one path both create modes use.
func (s *Server) registerProject(ctx context.Context, name, real, mode string, deny, skip []string) (*store.Project, *rpcError) {
	id, err := newProjectID()
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot create a project id"}
	}
	return s.registerProjectID(ctx, id, name, real, mode, deny, skip)
}

// registerProjectID is registerProject with the id chosen by the caller (D-105: a git step runs
// in the project's container before it is registered).
func (s *Server) registerProjectID(ctx context.Context, id, name, real, mode string, deny, skip []string) (*store.Project, *rpcError) {
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
// (acpcode-<projectId>, D-015) and in a path.
func newProjectID() (string, error) {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// prepareHome creates the HOME folder (0700) and trusts the project folder for Bob (F-15, D-013):
// it adds TRUST_FOLDER for agentPath to <home>/.bob/trustedFolders.json. The trusted path is the
// path the agent sees; with the host runner that is the host path, and the container runners mount
// the project at its host path too, so it is the same string in both cases.
func prepareHome(home, agentPath string) error {
	bob := filepath.Join(home, ".bob")
	if err := os.MkdirAll(bob, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(home, 0o700); err != nil {
		return err
	}
	return addTrustEntry(filepath.Join(bob, "trustedFolders.json"), agentPath)
}

// addTrustEntry sets folders[folder] to "TRUST_FOLDER" in the trust file at path, keeping every
// other entry and every other key. The format is the one Bob 2.0.9 writes and reads (RESULTS
// 2026-11-06): {"version":1,"folders":{"<path>":"TRUST_FOLDER"}}. A file that is not that shape is
// refused and left as it is, so no entry is ever lost. The write is atomic (writeFileAtomic).
func addTrustEntry(path, folder string) error {
	doc := map[string]json.RawMessage{}
	folders := map[string]json.RawMessage{}
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		// A new file.
	case err != nil:
		return err
	default:
		if err := json.Unmarshal(data, &doc); err != nil || doc == nil {
			return errors.New("trustedFolders.json is not a JSON object")
		}
		if raw, ok := doc["folders"]; ok && string(raw) != "null" {
			if err := json.Unmarshal(raw, &folders); err != nil {
				return errors.New("trustedFolders.json: folders must be an object")
			}
		}
	}
	if _, ok := doc["version"]; !ok {
		doc["version"] = json.RawMessage("1")
	}
	folders[folder] = json.RawMessage(`"TRUST_FOLDER"`)
	encoded, err := json.Marshal(folders)
	if err != nil {
		return err
	}
	doc["folders"] = encoded
	out, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, out)
}

// writeFileAtomic replaces path with data: a new temporary file in the same folder, created with
// O_EXCL and mode 0600, fsynced, then renamed over path. The folder is fsynced after the rename.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	var suffix [8]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return err
	}
	tmp := filepath.Join(dir, "."+filepath.Base(path)+"."+hex.EncodeToString(suffix[:])+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	done := false
	defer func() {
		if !done {
			f.Close()
			os.Remove(tmp)
		}
	}()
	if _, err := f.Write(data); err != nil {
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	done = true
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
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
