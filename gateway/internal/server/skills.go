package server

// Skill files (FR-43, F-17, D-085, D-087). `_agmente/skills/list`, `read`, `put` and `delete` manage
// <project>/.bob/skills/<name>/SKILL.md. Every folder on the path is checked with Lstat, one at a
// time: none may be a link, and each must be a folder inside the project (D-063, D-085). The write
// is atomic. Nothing is executed, and the content is written as given.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"unicode/utf8"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

const (
	skillMaxName    = 64
	skillMaxContent = 64 * 1024 // D-087: the gateway's cap, below Bob's own limit (P6)
	skillFileName   = "SKILL.md"
)

// skillNamePattern is the name rule (D-087): the rule Bob applies to the folder name (P6).
var skillNamePattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// skillFailHook is nil in production. A test sets it to fail a write after the temp file is
// written and before the rename.
var skillFailHook func() error

// skillInfo is one skill as the phone sees it (SPEC 6.2).
type skillInfo struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
}

// validSkillName is true for a name of at most 64 characters that matches the rule.
func validSkillName(name string) bool {
	return len(name) <= skillMaxName && skillNamePattern.MatchString(name)
}

// checkSkillContent refuses content that is not UTF-8 or is over the cap (D-087).
func checkSkillContent(content string) *rpcError {
	if !utf8.ValidString(content) {
		return invalidParams("content must be UTF-8 text")
	}
	if len(content) > skillMaxContent {
		return invalidParams("content must be at most 65536 bytes")
	}
	return nil
}

// serveSkills answers one skills request. handled is false for any other method.
func (s *Server) serveSkills(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (result any, rerr *rpcError, handled bool) {
	switch method {
	case "_agmente/skills/list", "_agmente/skills/read", "_agmente/skills/put", "_agmente/skills/delete":
	default:
		return nil, nil, false
	}
	if scope, ok := params.Get("scope").StringValue(); !ok || scope != "project" {
		return nil, invalidParams("scope must be \"project\""), true
	}
	pid, ok := params.Get("projectId").StringValue()
	if !ok || pid == "" {
		return nil, invalidParams("projectId is required"), true
	}
	name, content := "", ""
	if method != "_agmente/skills/list" {
		n, ok := params.Get("name").StringValue()
		if !ok || !validSkillName(n) {
			return nil, invalidParams("name must be lowercase kebab-case (a-z, 0-9, single hyphens), at most 64 characters"), true
		}
		name = n
	}
	if method == "_agmente/skills/put" {
		c, ok := params.Get("content").StringValue()
		if !ok {
			return nil, invalidParams("content is required and must be a string"), true
		}
		if rerr := checkSkillContent(c); rerr != nil {
			return nil, rerr, true
		}
		content = c
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read projects"}, true
	}
	if p == nil {
		return nil, invalidParams("unknown project"), true
	}
	switch method {
	case "_agmente/skills/list":
		result, rerr = s.skillsList(p)
	case "_agmente/skills/read":
		result, rerr = s.skillRead(who, p, name)
	case "_agmente/skills/put":
		result, rerr = s.skillPut(who, p, name, content)
	default:
		result, rerr = s.skillDelete(who, p, name)
	}
	return result, rerr, true
}

func skillPathRefused() *rpcError {
	return invalidParams("the skill path must be real folders inside the project, with no links (D-085)")
}

// projectRoot is the realpath of the project folder.
func projectRoot(p *store.Project) (string, *rpcError) {
	root, err := realpath(p.Path)
	if err != nil {
		return "", invalidParams("the project folder cannot be read")
	}
	return root, nil
}

// skillDir returns <root>/.bob/skills, or <root>/.bob/skills/<name> when name is set. Each folder is
// checked with Lstat in turn: a link or a non-folder is refused. With create, a missing folder is
// made with mode 0755. Without create, a missing folder gives "" and no error.
func skillDir(root, name string, create bool) (string, *rpcError) {
	parts := []string{".bob", "skills"}
	if name != "" {
		parts = append(parts, name)
	}
	dir := root
	for _, part := range parts {
		dir = filepath.Join(dir, part)
		ok, rerr := ensureRealDir(dir, create)
		if rerr != nil {
			return "", rerr
		}
		if !ok {
			return "", nil
		}
	}
	return dir, nil
}

// ensureRealDir is true when path is a real folder (not a link). It makes the folder when create
// is set and the folder is missing.
func ensureRealDir(path string, create bool) (bool, *rpcError) {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		if !create {
			return false, nil
		}
		if err := os.Mkdir(path, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
			return false, &rpcError{Code: rpcInternal, Message: "cannot create the skill folder"}
		}
		info, err = os.Lstat(path)
	}
	if err != nil {
		return false, &rpcError{Code: rpcInternal, Message: "cannot read the skill folder"}
	}
	if info.Mode()&fs.ModeSymlink != 0 || !info.IsDir() {
		return false, skillPathRefused()
	}
	return true, nil
}

// insideProject re-resolves dir and checks that it is the project folder or inside it (D-063).
func insideProject(root, dir string) bool {
	real, err := realpath(dir)
	return err == nil && isInsideRoots(real, []string{root})
}

// skillFile returns the SKILL.md info when folder is a real folder holding a regular SKILL.md, or nil.
func skillFile(folder string) fs.FileInfo {
	fi, err := os.Lstat(folder)
	if err != nil || !fi.IsDir() {
		return nil
	}
	sf, err := os.Lstat(filepath.Join(folder, skillFileName))
	if err != nil || !sf.Mode().IsRegular() {
		return nil
	}
	return sf
}

// skillsList answers _agmente/skills/list. A folder whose name fails the rule, or that has no
// regular SKILL.md, or that is a link, is skipped.
func (s *Server) skillsList(p *store.Project) (any, *rpcError) {
	root, rerr := projectRoot(p)
	if rerr != nil {
		return nil, rerr
	}
	dir, rerr := skillDir(root, "", false)
	if rerr != nil {
		return nil, rerr
	}
	out := []skillInfo{}
	if dir == "" {
		return map[string]any{"skills": out}, nil
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skills folder"}
	}
	for _, e := range ents {
		if !validSkillName(e.Name()) {
			continue
		}
		if sf := skillFile(filepath.Join(dir, e.Name())); sf != nil {
			out = append(out, skillInfo{Name: e.Name(), Bytes: sf.Size()})
		}
	}
	return map[string]any{"skills": out}, nil
}

// skillRead answers _agmente/skills/read. It returns the name, the content and the byte count of
// SKILL.md. The path is checked as for put and delete (D-085): no link in any folder, and the file
// is a regular file of at most 65536 bytes that is UTF-8 text. The content is never logged; the
// audit line holds the project, the name and the byte count only.
func (s *Server) skillRead(who audit.Who, p *store.Project, name string) (any, *rpcError) {
	root, rerr := projectRoot(p)
	if rerr != nil {
		return nil, rerr
	}
	dir, rerr := skillDir(root, name, false)
	if rerr != nil {
		return nil, rerr
	}
	if dir == "" {
		return nil, skillNotFound()
	}
	if !insideProject(root, dir) {
		return nil, skillPathRefused()
	}
	target := filepath.Join(dir, skillFileName)
	sf, err := os.Lstat(target)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil, skillNotFound()
	case err != nil:
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skill file"}
	case !sf.Mode().IsRegular():
		return nil, skillPathRefused()
	case sf.Size() > skillMaxContent:
		return nil, skillTooLarge()
	}
	f, err := os.OpenFile(target, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, syscall.ELOOP) {
		return nil, skillPathRefused()
	}
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skill file"}
	}
	defer func() { _ = f.Close() }()
	data, err := io.ReadAll(io.LimitReader(f, skillMaxContent+1))
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skill file"}
	}
	if len(data) > skillMaxContent {
		return nil, skillTooLarge()
	}
	if !utf8.Valid(data) {
		return nil, invalidParams("the skill is not UTF-8 text, so it cannot be edited here")
	}
	s.audit.LogSkill("skill_read", with(who, audit.Fields{Project: p.ID}), name, len(data))
	return map[string]any{"name": name, "content": string(data), "bytes": len(data)}, nil
}

func skillNotFound() *rpcError {
	return invalidParams("skill not found")
}

func skillTooLarge() *rpcError {
	return invalidParams("the skill is over 65536 bytes")
}

// skillPut answers _agmente/skills/put. The content is written as given. The audit line holds the
// project, the name and the byte count only.
func (s *Server) skillPut(who audit.Who, p *store.Project, name, content string) (any, *rpcError) {
	root, rerr := projectRoot(p)
	if rerr != nil {
		return nil, rerr
	}
	dir, rerr := skillDir(root, name, true)
	if rerr != nil {
		return nil, rerr
	}
	if dir == "" || !insideProject(root, dir) {
		return nil, skillPathRefused()
	}
	target := filepath.Join(dir, skillFileName)
	sf, err := os.Lstat(target)
	switch {
	case err == nil && !sf.Mode().IsRegular():
		return nil, skillPathRefused()
	case err != nil && !errors.Is(err, fs.ErrNotExist):
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skill file"}
	}
	if err := writeSkillFile(dir, []byte(content)); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot save the skill"}
	}
	s.audit.LogSkill("skill_put", with(who, audit.Fields{Project: p.ID}), name, len(content))
	return map[string]any{"skill": skillInfo{Name: name, Bytes: int64(len(content))}}, nil
}

// skillDelete answers _agmente/skills/delete. It removes SKILL.md and the folder, and nothing else:
// a folder that holds any other entry is refused and left as it is.
func (s *Server) skillDelete(who audit.Who, p *store.Project, name string) (any, *rpcError) {
	root, rerr := projectRoot(p)
	if rerr != nil {
		return nil, rerr
	}
	dir, rerr := skillDir(root, name, false)
	if rerr != nil {
		return nil, rerr
	}
	if dir == "" {
		return nil, invalidParams("skill does not exist")
	}
	if !insideProject(root, dir) {
		return nil, skillPathRefused()
	}
	sf := skillFile(dir)
	if sf == nil {
		return nil, invalidParams("skill does not exist")
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the skill folder"}
	}
	for _, e := range ents {
		if e.Name() != skillFileName {
			return nil, invalidParams("the skill folder holds other files, so nothing was deleted")
		}
	}
	if err := os.Remove(filepath.Join(dir, skillFileName)); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot delete the skill"}
	}
	if err := os.Remove(dir); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot delete the skill folder"}
	}
	s.audit.LogSkill("skill_deleted", with(who, audit.Fields{Project: p.ID}), name, int(sf.Size()))
	return map[string]any{}, nil
}

// writeSkillFile writes data to folder/SKILL.md atomically (D-085): a temp file in the same folder,
// created with O_EXCL and O_NOFOLLOW at mode 0644, fsynced, then renamed over SKILL.md. A failure
// removes the temp file.
func writeSkillFile(folder string, data []byte) (err error) {
	suffix, err := randomHex(8)
	if err != nil {
		return err
	}
	tmp := filepath.Join(folder, "."+skillFileName+"."+suffix+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp)
		}
	}()
	if err = f.Chmod(0o644); err != nil {
		_ = f.Close()
		return err
	}
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if skillFailHook != nil {
		if err = skillFailHook(); err != nil {
			return err
		}
	}
	if err = os.Rename(tmp, filepath.Join(folder, skillFileName)); err != nil {
		return err
	}
	if d, derr := os.Open(folder); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
