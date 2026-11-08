package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// skillFixture is a gateway with one project folder and a folder outside it (FR-43, D-085).
type skillFixture struct {
	t       *testing.T
	srv     *Server
	logs    *syncBuffer
	project string // realpath of the project folder
	outside string // a folder beside the project, not inside it
	id      string
}

const skillTestProjectID = "skillproj"

func newSkillFixture(t *testing.T) *skillFixture {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := &skillFixture{t: t, project: filepath.Join(dir, "project"), outside: filepath.Join(dir, "outside"), id: skillTestProjectID}
	for _, d := range []string{f.project, f.outside} {
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	sum := sha256.Sum256([]byte("skills-test-token-abcdefgh"))
	raw, _ := json.Marshal(map[string]any{
		"listen":   map[string]any{"host": "127.0.0.1", "port": 0},
		"tokens":   []any{map[string]any{"id": "phone", "identity": "owner", "sha256": hex.EncodeToString(sum[:])}},
		"agent":    map[string]any{"command": []string{"/bin/false"}},
		"projects": map[string]any{"roots": []string{dir}},
		"stateDir": filepath.Join(dir, "state"),
		"runner":   map[string]any{"kind": "host", "allowHost": true},
	})
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Validate(v)
	if err != nil {
		t.Fatal(err)
	}
	db, err := store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	f.logs = &syncBuffer{}
	f.srv = New(cfg, audit.New(f.logs), db)
	if err := db.CreateProject(context.Background(), store.Project{ID: f.id, Name: "p", Path: f.project, Created: "2026-11-07T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	return f
}

// call sends one request to serveSkills with params given as a Go map.
func (f *skillFixture) call(method string, params map[string]any) (any, *rpcError, bool) {
	f.t.Helper()
	raw, err := json.Marshal(params)
	if err != nil {
		f.t.Fatal(err)
	}
	v, err := jsonv.Parse(raw)
	if err != nil {
		f.t.Fatal(err)
	}
	who := audit.Who{Identity: "owner", Device: "dev-1", Client: "client-1", Conn: 7}
	return f.srv.serveSkills(context.Background(), who, method, v)
}

// put saves a skill with the project and the project scope, and returns the refusal, if any.
func (f *skillFixture) put(name, content string) *rpcError {
	f.t.Helper()
	_, rerr, handled := f.call("_acpcode/skills/put", map[string]any{"projectId": f.id, "scope": "project", "name": name, "content": content})
	if !handled {
		f.t.Fatalf("put %q: not handled", name)
	}
	return rerr
}

func (f *skillFixture) del(name string) *rpcError {
	f.t.Helper()
	_, rerr, handled := f.call("_acpcode/skills/delete", map[string]any{"projectId": f.id, "scope": "project", "name": name})
	if !handled {
		f.t.Fatalf("delete %q: not handled", name)
	}
	return rerr
}

func (f *skillFixture) list() ([]skillInfo, *rpcError) {
	f.t.Helper()
	res, rerr, handled := f.call("_acpcode/skills/list", map[string]any{"projectId": f.id, "scope": "project"})
	if !handled {
		f.t.Fatal("list: not handled")
	}
	if rerr != nil {
		return nil, rerr
	}
	return res.(map[string]any)["skills"].([]skillInfo), nil
}

func (f *skillFixture) mustInvalid(what string, rerr *rpcError) {
	f.t.Helper()
	if rerr == nil {
		f.t.Fatalf("%s: accepted, want -32602", what)
	}
	if rerr.Code != rpcInvalidParams {
		f.t.Fatalf("%s: code %d, want -32602 (%s)", what, rerr.Code, rerr.Message)
	}
}

func (f *skillFixture) mustOK(what string, rerr *rpcError) {
	f.t.Helper()
	if rerr != nil {
		f.t.Fatalf("%s: refused: %d %s", what, rerr.Code, rerr.Message)
	}
}

// bobPath is a path inside the project's .bob folder.
func (f *skillFixture) bobPath(parts ...string) string {
	return filepath.Join(append([]string{f.project, ".bob"}, parts...)...)
}

func (f *skillFixture) writeFile(path, data string) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func entryNames(t *testing.T, dir string) []string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range ents {
		out = append(out, e.Name())
	}
	return out
}

// T-44 and D-087: the name rule. Every refused name is refused with -32602 and writes nothing.
func TestSkillNameRule(t *testing.T) {
	valid := []string{"a", "0", "my-skill", "skill-2-x", strings.Repeat("a", 64)}
	invalid := []string{
		"", "Bad Name", "../x", strings.Repeat("a", 65), "Upper", "-lead", "trail-",
		"double--dash", "under_score", "dot.name", "a/b", "skill\n", "é",
	}
	for _, n := range valid {
		if !validSkillName(n) {
			t.Errorf("valid name refused: %q", n)
		}
	}
	for _, n := range invalid {
		if validSkillName(n) {
			t.Errorf("invalid name accepted: %q", n)
		}
	}

	f := newSkillFixture(t)
	for _, n := range invalid {
		f.mustInvalid("put "+n, f.put(n, "body\n"))
	}
	if _, err := os.Stat(f.bobPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused name created %s", f.bobPath())
	}
	f.mustOK("put a 64-character name", f.put(strings.Repeat("a", 64), "body\n"))
	f.mustOK("put the valid name", f.put("my-skill", "body\n"))
}

// T-44: content over 64 KiB and content that is not UTF-8 are refused; nothing is written.
func TestSkillContentCap(t *testing.T) {
	if rerr := checkSkillContent(strings.Repeat("a", skillMaxContent)); rerr != nil {
		t.Fatalf("content of exactly 65536 bytes refused: %s", rerr.Message)
	}
	for what, content := range map[string]string{
		"65537 bytes":   strings.Repeat("a", skillMaxContent+1),
		"70 KiB":        strings.Repeat("a", 70*1024),
		"invalid UTF-8": "ok \xff bad",
	} {
		if rerr := checkSkillContent(content); rerr == nil || rerr.Code != rpcInvalidParams {
			t.Errorf("%s: not refused with -32602", what)
		}
	}

	f := newSkillFixture(t)
	f.mustInvalid("put 70 KiB", f.put("big-skill", strings.Repeat("a", 70*1024)))
	if _, err := os.Stat(f.bobPath("skills", "big-skill")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("an oversize skill left a folder behind")
	}
	_, rerr, _ := f.call("_acpcode/skills/put", map[string]any{"projectId": f.id, "scope": "project", "name": "no-body"})
	f.mustInvalid("put without content", rerr)
}

// Put writes the content as given, mode 0644, in a 0755 folder, and list shows it with its size.
func TestPutThenListShowsSkill(t *testing.T) {
	f := newSkillFixture(t)
	content := "---\nname: whatever-the-frontmatter-says\n---\n\nBody text.\n"
	f.mustOK("put", f.put("alpha", content))

	data, err := os.ReadFile(f.bobPath("skills", "alpha", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != content {
		t.Fatalf("content on disk differs from what was sent: %q", data)
	}
	info, err := os.Stat(f.bobPath("skills", "alpha", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Errorf("SKILL.md mode %o, want 644", info.Mode().Perm())
	}
	dirInfo, err := os.Stat(f.bobPath("skills", "alpha"))
	if err != nil {
		t.Fatal(err)
	}
	if dirInfo.Mode().Perm() != 0o755 {
		t.Errorf("skill folder mode %o, want 755", dirInfo.Mode().Perm())
	}

	skills, rerr := f.list()
	f.mustOK("list", rerr)
	if len(skills) != 1 || skills[0].Name != "alpha" || skills[0].Bytes != int64(len(content)) {
		t.Fatalf("list = %+v, want one alpha of %d bytes", skills, len(content))
	}
	if names := entryNames(t, f.bobPath("skills", "alpha")); len(names) != 1 || names[0] != "SKILL.md" {
		t.Fatalf("skill folder holds %v after a good write, want only SKILL.md", names)
	}
}

// List skips folders whose name fails the rule, folders with no SKILL.md, stray files, and links.
func TestListSkipsInvalidFolders(t *testing.T) {
	f := newSkillFixture(t)
	f.mustOK("put", f.put("good-one", "body\n"))
	skillsDir := f.bobPath("skills")
	for _, bad := range []string{"Bad Name", "UPPER", "under_score", strings.Repeat("b", 65)} {
		f.writeFile(filepath.Join(skillsDir, bad, "SKILL.md"), "body\n")
	}
	if err := os.Mkdir(filepath.Join(skillsDir, "nofile"), 0o755); err != nil {
		t.Fatal(err)
	}
	f.writeFile(filepath.Join(skillsDir, "stray.md"), "not a folder\n")
	f.writeFile(filepath.Join(f.outside, "SKILL.md"), "outside\n")
	if err := os.Symlink(f.outside, filepath.Join(skillsDir, "linked")); err != nil {
		t.Fatal(err)
	}

	skills, rerr := f.list()
	f.mustOK("list", rerr)
	if len(skills) != 1 || skills[0].Name != "good-one" {
		t.Fatalf("list = %+v, want only good-one", skills)
	}
}

// Delete removes that one folder and its SKILL.md. Other skills and other files stay. A folder with
// other files is refused and nothing is removed.
func TestDeleteRemovesOnlyThatFolder(t *testing.T) {
	f := newSkillFixture(t)
	f.mustOK("put keep", f.put("keep-me", "keep\n"))
	f.mustOK("put drop", f.put("drop-me", "drop\n"))
	f.writeFile(f.bobPath("skills", "stray.md"), "stray\n")

	f.mustOK("delete drop-me", f.del("drop-me"))
	if _, err := os.Stat(f.bobPath("skills", "drop-me")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("drop-me still exists after delete")
	}
	if _, err := os.Stat(f.bobPath("skills", "keep-me", "SKILL.md")); err != nil {
		t.Fatalf("keep-me was touched: %v", err)
	}
	if _, err := os.Stat(f.bobPath("skills", "stray.md")); err != nil {
		t.Fatalf("a stray file was touched: %v", err)
	}
	f.mustInvalid("delete missing", f.del("drop-me"))

	f.writeFile(f.bobPath("skills", "keep-me", "helper.sh"), "echo\n")
	f.mustInvalid("delete a folder with another file", f.del("keep-me"))
	if _, err := os.Stat(f.bobPath("skills", "keep-me", "SKILL.md")); err != nil {
		t.Fatal("a refused delete removed SKILL.md")
	}
	f.mustInvalid("delete a bad name", f.del("../keep-me"))
}

// A skill folder that is a symlink is refused by put and delete and never listed. The target keeps
// its files.
func TestSymlinkedSkillFolderRefused(t *testing.T) {
	f := newSkillFixture(t)
	f.writeFile(f.bobPath("skills", "placeholder", "SKILL.md"), "x\n")
	f.writeFile(filepath.Join(f.outside, "SKILL.md"), "outside keep\n")
	if err := os.Symlink(f.outside, f.bobPath("skills", "evil")); err != nil {
		t.Fatal(err)
	}

	f.mustInvalid("put through a symlinked folder", f.put("evil", "pwned\n"))
	f.mustInvalid("delete through a symlinked folder", f.del("evil"))
	data, err := os.ReadFile(filepath.Join(f.outside, "SKILL.md"))
	if err != nil || string(data) != "outside keep\n" {
		t.Fatalf("the link target changed: %q, %v", data, err)
	}
	if names := entryNames(t, f.outside); len(names) != 1 {
		t.Fatalf("files were written outside the project: %v", names)
	}
	skills, rerr := f.list()
	f.mustOK("list", rerr)
	for _, s := range skills {
		if s.Name == "evil" {
			t.Fatal("a symlinked skill folder was listed")
		}
	}
}

// A SKILL.md that is a symlink is refused, and the link target is not written.
func TestSymlinkedSkillFileRefused(t *testing.T) {
	f := newSkillFixture(t)
	if err := os.MkdirAll(f.bobPath("skills", "linkfile"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(f.outside, "target.md")
	f.writeFile(target, "keep\n")
	if err := os.Symlink(target, f.bobPath("skills", "linkfile", "SKILL.md")); err != nil {
		t.Fatal(err)
	}
	f.mustInvalid("put over a symlinked SKILL.md", f.put("linkfile", "pwned\n"))
	if data, _ := os.ReadFile(target); string(data) != "keep\n" {
		t.Fatalf("the link target was written: %q", data)
	}
}

// A symlinked .bob, or a symlinked skills folder, is refused. Nothing is written outside the project.
func TestSymlinkedBobRefused(t *testing.T) {
	f := newSkillFixture(t)
	if err := os.Symlink(f.outside, f.bobPath()); err != nil {
		t.Fatal(err)
	}
	f.mustInvalid("put with a symlinked .bob", f.put("alpha", "body\n"))
	f.mustInvalid("list with a symlinked .bob", listErr(f))
	if names := entryNames(t, f.outside); len(names) != 0 {
		t.Fatalf("files appeared outside the project through a symlinked .bob: %v", names)
	}
	if err := os.Remove(f.bobPath()); err != nil {
		t.Fatal(err)
	}

	if err := os.Mkdir(f.bobPath(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(f.outside, f.bobPath("skills")); err != nil {
		t.Fatal(err)
	}
	f.mustInvalid("put with a symlinked skills folder", f.put("alpha", "body\n"))
	f.mustInvalid("delete with a symlinked skills folder", f.del("alpha"))
	if names := entryNames(t, f.outside); len(names) != 0 {
		t.Fatalf("files appeared outside the project through a symlinked skills folder: %v", names)
	}
}

func listErr(f *skillFixture) *rpcError {
	_, rerr, _ := f.call("_acpcode/skills/list", map[string]any{"projectId": f.id, "scope": "project"})
	return rerr
}

// A failure after the temp file is written leaves no temp file, and an existing SKILL.md is unchanged.
func TestTempFileAbsentAfterForcedFailure(t *testing.T) {
	f := newSkillFixture(t)
	f.mustOK("put", f.put("stable", "old\n"))

	skillFailHook = func() error { return errors.New("forced failure") }
	defer func() { skillFailHook = nil }()

	_, rerr, _ := f.call("_acpcode/skills/put", map[string]any{"projectId": f.id, "scope": "project", "name": "stable", "content": "new\n"})
	if rerr == nil || rerr.Code != rpcInternal {
		t.Fatalf("forced failure: got %+v, want -32603", rerr)
	}
	if data, _ := os.ReadFile(f.bobPath("skills", "stable", "SKILL.md")); string(data) != "old\n" {
		t.Fatalf("SKILL.md changed after a failed write: %q", data)
	}
	if names := entryNames(t, f.bobPath("skills", "stable")); len(names) != 1 || names[0] != "SKILL.md" {
		t.Fatalf("temp file left behind: %v", names)
	}

	_, rerr, _ = f.call("_acpcode/skills/put", map[string]any{"projectId": f.id, "scope": "project", "name": "fresh", "content": "new\n"})
	if rerr == nil {
		t.Fatal("forced failure on a new skill: accepted")
	}
	if _, err := os.Stat(f.bobPath("skills", "fresh", "SKILL.md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a failed new skill left SKILL.md")
	}
	if _, err := os.Stat(f.bobPath("skills", "fresh")); err == nil {
		if names := entryNames(t, f.bobPath("skills", "fresh")); len(names) != 0 {
			t.Fatalf("temp file left in the new folder: %v", names)
		}
	}
}

// D-087: the scope must be project. Anything else, or none, is -32602 for every method.
func TestScopeOtherThanProjectRefused(t *testing.T) {
	f := newSkillFixture(t)
	for _, scope := range []any{"", "user", "home", "Project", nil, 1} {
		for _, method := range []string{"_acpcode/skills/list", "_acpcode/skills/put", "_acpcode/skills/delete"} {
			params := map[string]any{"projectId": f.id, "name": "alpha", "content": "body\n"}
			if scope != nil {
				params["scope"] = scope
			}
			_, rerr, handled := f.call(method, params)
			if !handled {
				t.Fatalf("%s: not handled", method)
			}
			f.mustInvalid(method+" with scope "+jsonScope(scope), rerr)
		}
	}
	_, rerr, _ := f.call("_acpcode/skills/put", map[string]any{"projectId": f.id, "name": "alpha", "content": "body\n"})
	f.mustInvalid("put without scope", rerr)
	if _, err := os.Stat(f.bobPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a refused scope created .bob")
	}
}

func jsonScope(v any) string {
	if v == nil {
		return "absent"
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// An unknown project is -32602, and the methods outside the skills group are not handled here.
func TestUnknownProjectAndOtherMethods(t *testing.T) {
	f := newSkillFixture(t)
	_, rerr, handled := f.call("_acpcode/skills/list", map[string]any{"projectId": "nope", "scope": "project"})
	if !handled {
		t.Fatal("list not handled")
	}
	f.mustInvalid("unknown project", rerr)
	if _, _, handled := f.call("_acpcode/git/status", map[string]any{"projectId": f.id}); handled {
		t.Fatal("a git method was handled by serveSkills")
	}
}

// D-087: audit lines carry the project, the name and the byte count. The content never appears.
func TestAuditNeverHoldsContent(t *testing.T) {
	f := newSkillFixture(t)
	const secret = "BODY-SECRET-XYZ"
	content := "line one " + secret + "\n"
	f.mustOK("put", f.put("audited", content))
	f.mustOK("delete", f.del("audited"))

	out := f.logs.String()
	for _, want := range []string{
		`"event":"skill_put"`, `"skill":"audited"`, `"bytes":` + itoa(len(content)), `"project":"` + f.id + `"`,
		`"event":"skill_deleted"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("audit lacks %s in:\n%s", want, out)
		}
	}
	if strings.Contains(out, secret) {
		t.Fatalf("audit holds skill content:\n%s", out)
	}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// read sends _acpcode/skills/read and returns the result map, or the refusal.
func (f *skillFixture) read(name string) (map[string]any, *rpcError) {
	f.t.Helper()
	res, rerr, handled := f.call("_acpcode/skills/read", map[string]any{"projectId": f.id, "scope": "project", "name": name})
	if !handled {
		f.t.Fatalf("read %q: not handled", name)
	}
	if rerr != nil {
		return nil, rerr
	}
	return res.(map[string]any), nil
}

// Read returns the name, content and byte count of a skill that put saved, so the phone can edit it.
func TestReadSkill(t *testing.T) {
	f := newSkillFixture(t)
	content := "---\nname: alpha\n---\n\nBody with ünicöde.\n"
	f.mustOK("put", f.put("alpha", content))

	got, rerr := f.read("alpha")
	f.mustOK("read", rerr)
	if got["name"] != "alpha" || got["content"] != content || got["bytes"] != len(content) {
		t.Fatalf("read = %#v, want alpha with %d bytes and the saved content", got, len(content))
	}
}

// A missing skill, and a folder with no SKILL.md, are both "skill not found" with -32602.
func TestReadMissingSkill(t *testing.T) {
	f := newSkillFixture(t)
	_, rerr := f.read("nothing-here")
	f.mustInvalid("read missing", rerr)
	if rerr.Message != "skill not found" {
		t.Fatalf("message %q, want \"skill not found\"", rerr.Message)
	}

	f.writeFile(f.bobPath("skills", "placeholder", "SKILL.md"), "x\n")
	if err := os.Mkdir(f.bobPath("skills", "empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	_, rerr = f.read("empty")
	f.mustInvalid("read a folder with no SKILL.md", rerr)
	if rerr.Message != "skill not found" {
		t.Fatalf("message %q, want \"skill not found\"", rerr.Message)
	}
}

// D-085: a skill folder that is a link, and a SKILL.md that is a link, are refused. Nothing outside
// the project is read.
func TestReadSymlinkedSkillRefused(t *testing.T) {
	f := newSkillFixture(t)
	f.writeFile(f.bobPath("skills", "placeholder", "SKILL.md"), "x\n")
	f.writeFile(filepath.Join(f.outside, "SKILL.md"), "outside\n")
	if err := os.Symlink(f.outside, f.bobPath("skills", "evil")); err != nil {
		t.Fatal(err)
	}
	_, rerr := f.read("evil")
	f.mustInvalid("read through a symlinked folder", rerr)
	if rerr.Message != skillPathRefused().Message {
		t.Fatalf("message %q, want the path refusal", rerr.Message)
	}

	if err := os.MkdirAll(f.bobPath("skills", "linkfile"), 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(f.outside, "target.md")
	f.writeFile(target, "keep\n")
	if err := os.Symlink(target, f.bobPath("skills", "linkfile", "SKILL.md")); err != nil {
		t.Fatal(err)
	}
	_, rerr = f.read("linkfile")
	f.mustInvalid("read a symlinked SKILL.md", rerr)
	if rerr.Message != skillPathRefused().Message {
		t.Fatalf("message %q, want the path refusal", rerr.Message)
	}
}

// A SKILL.md of exactly 65536 bytes is read. One byte more is refused with -32602.
func TestReadOversizeRefused(t *testing.T) {
	f := newSkillFixture(t)
	f.writeFile(f.bobPath("skills", "exact", "SKILL.md"), strings.Repeat("a", skillMaxContent))
	got, rerr := f.read("exact")
	f.mustOK("read 65536 bytes", rerr)
	if got["bytes"] != skillMaxContent {
		t.Fatalf("bytes = %v, want %d", got["bytes"], skillMaxContent)
	}

	f.writeFile(f.bobPath("skills", "big", "SKILL.md"), strings.Repeat("a", skillMaxContent+1))
	_, rerr = f.read("big")
	f.mustInvalid("read 65537 bytes", rerr)
}

// A file that is not UTF-8 is refused, so the phone never saves a mangled copy over it.
func TestReadNonUTF8Refused(t *testing.T) {
	f := newSkillFixture(t)
	f.writeFile(f.bobPath("skills", "binary", "SKILL.md"), "ok \xff bad")
	_, rerr := f.read("binary")
	f.mustInvalid("read non-UTF-8", rerr)
}

// D-087: a name that fails the rule is refused with -32602.
func TestReadBadNameRefused(t *testing.T) {
	f := newSkillFixture(t)
	f.mustOK("put", f.put("alpha", "body\n"))
	for _, n := range []string{"", "Bad Name", "../alpha", "a/b", strings.Repeat("a", 65)} {
		_, rerr := f.read(n)
		f.mustInvalid("read "+n, rerr)
	}
}

// D-087: the scope must be project for read too.
func TestReadScopeOtherThanProjectRefused(t *testing.T) {
	f := newSkillFixture(t)
	f.mustOK("put", f.put("alpha", "body\n"))
	for _, scope := range []any{"", "user", "home", "Project", nil, 1} {
		params := map[string]any{"projectId": f.id, "name": "alpha"}
		if scope != nil {
			params["scope"] = scope
		}
		_, rerr, handled := f.call("_acpcode/skills/read", params)
		if !handled {
			t.Fatal("read: not handled")
		}
		f.mustInvalid("read with scope "+jsonScope(scope), rerr)
	}
}

// D-087: skill_read carries the project, the name and the byte count. The content never appears.
func TestReadAuditHoldsNoContent(t *testing.T) {
	f := newSkillFixture(t)
	const secret = "READ-SECRET-BODY-42"
	content := "line " + secret + "\n"
	f.mustOK("put", f.put("readable", content))
	_, rerr := f.read("readable")
	f.mustOK("read", rerr)

	out := f.logs.String()
	for _, want := range []string{
		`"event":"skill_read"`, `"skill":"readable"`, `"bytes":` + itoa(len(content)), `"project":"` + f.id + `"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("audit lacks %s in:\n%s", want, out)
		}
	}
	if strings.Contains(out, secret) {
		t.Fatalf("audit holds skill content:\n%s", out)
	}
}
