package server

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// mcpRig is a gateway server with one registered project whose home exists. It calls the MCP
// handler directly; the wire suite (gateway/test/mcp-config.test.mjs) covers the socket.
type mcpRig struct {
	t       *testing.T
	s       *Server
	logs    *bytes.Buffer
	id      string
	project string // realpath of the project folder
	home    string // <stateDir>/homes/<id>
	state   string
	outside string // a folder beside the project, not inside it
}

const mcpProjectID = "a1b2c3d4e5f6"

func newMCPRig(t *testing.T) *mcpRig {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := &mcpRig{t: t, id: mcpProjectID, state: filepath.Join(base, "state"), outside: filepath.Join(base, "outside")}
	r.project = filepath.Join(base, "root", "project")
	r.home = filepath.Join(r.state, "homes", r.id)
	for _, d := range []string{r.project, r.home, filepath.Join(r.home, ".bob", "settings"), r.outside} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	db, err := store.Open(filepath.Join(r.state, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	cfg := &config.Config{Roots: []string{filepath.Join(base, "root")}, StateDir: r.state, Runner: config.Runner{Kind: "host"}}
	r.logs = &bytes.Buffer{}
	r.s = New(cfg, audit.New(r.logs), db)
	if err := db.CreateProject(context.Background(), store.Project{ID: r.id, Name: "p", Path: r.project, Created: "2026-11-07T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	return r
}

func (r *mcpRig) projectFile() string { return filepath.Join(r.project, ".bob", "mcp.json") }
func (r *mcpRig) homeFile() string    { return filepath.Join(r.home, ".bob", "settings", "mcp.json") }

// writeFile creates the parent folders (0700) and writes data (0600) at path.
func (r *mcpRig) writeFile(path, data string) {
	r.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		r.t.Fatal(err)
	}
}

func (r *mcpRig) call(method, params string) (any, *rpcError, bool) {
	r.t.Helper()
	v, err := jsonv.Parse([]byte(params))
	if err != nil {
		r.t.Fatal(err)
	}
	return r.s.serveMCPConfig(context.Background(), audit.Who{Identity: "owner", Device: "phone"}, method, v)
}

func (r *mcpRig) list(params string) (any, *rpcError, bool) {
	return r.call("_acpcode/mcp/list", params)
}

func (r *mcpRig) set(params string) (any, *rpcError, bool) {
	return r.call("_acpcode/mcp/set", params)
}

func (r *mcpRig) mustRefuse(res any, rerr *rpcError, handled bool) {
	r.t.Helper()
	if !handled {
		r.t.Fatalf("not handled")
	}
	if rerr == nil || rerr.Code != rpcInvalidParams || res != nil {
		r.t.Fatalf("got result %v, error %+v; want -32602", res, rerr)
	}
}

func (r *mcpRig) mustOK(res any, rerr *rpcError, handled bool) map[string]any {
	r.t.Helper()
	if !handled || rerr != nil {
		r.t.Fatalf("handled=%v error %+v", handled, rerr)
	}
	body, _ := json.Marshal(res)
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		r.t.Fatal(err)
	}
	return out
}

func readFileString(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

const mcpFixture = `{
  "theme": "dark",
  "mcpServers": {
    "docs": {"command": "node", "args": ["docs.js"], "custom": {"keep": 1}},
    "web": {"url": "https://secret.example.test/mcp", "headers": {"Authorization": "Bearer SECRET-HEADER-VALUE"}, "alwaysAllow": ["search"]}
  }
}`

func TestMCPUnknownMethodIsNotHandled(t *testing.T) {
	r := newMCPRig(t)
	if _, _, handled := r.call("_acpcode/mcp/other", `{}`); handled {
		t.Fatal("an unknown method was handled")
	}
}

func TestMCPListNeedsAKnownProject(t *testing.T) {
	r := newMCPRig(t)
	res, rerr, handled := r.list(`{}`)
	if !handled || rerr == nil || rerr.Code != rpcInvalidParams || res != nil {
		t.Fatalf("list without projectId: %v %+v %v", res, rerr, handled)
	}
	res, rerr, handled = r.list(`{"projectId":"nope"}`)
	if !handled || rerr == nil || rerr.Code != rpcInvalidParams || res != nil {
		t.Fatalf("list with unknown project: %v %+v %v", res, rerr, handled)
	}
}

func TestMCPListShowsBothSourcesWithoutSecrets(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	r.writeFile(r.homeFile(), `{"mcpServers": {"home-tool": {"command": "uvx", "disabled": true, "alwaysAllow": []}}}`)
	out := r.mustOK(r.list(`{"projectId":"` + r.id + `"}`))
	body, _ := json.Marshal(out)
	for _, leak := range []string{"SECRET-HEADER-VALUE", "secret.example.test", "headers", "Bearer", "docs.js", "keep"} {
		if strings.Contains(string(body), leak) {
			t.Fatalf("list leaks %q: %s", leak, body)
		}
	}
	servers := out["servers"].([]any)
	want := map[string]map[string]any{
		"project/docs":   {"disabled": false, "alwaysAllow": float64(0), "source": "project", "transport": "stdio"},
		"project/web":    {"disabled": false, "alwaysAllow": float64(1), "source": "project", "transport": "http"},
		"home/home-tool": {"disabled": true, "alwaysAllow": float64(0), "source": "home", "transport": "stdio"},
	}
	if len(servers) != len(want) {
		t.Fatalf("servers = %v", servers)
	}
	for _, raw := range servers {
		s := raw.(map[string]any)
		key := s["source"].(string) + "/" + s["name"].(string)
		exp, ok := want[key]
		if !ok {
			t.Fatalf("unexpected server %v", s)
		}
		for k, v := range exp {
			if s[k] != v {
				t.Errorf("%s.%s = %v, want %v", key, k, s[k], v)
			}
		}
		if len(s) != 5 {
			t.Errorf("%s has %d fields, want name, disabled, alwaysAllow, source, transport", key, len(s))
		}
	}
}

func TestMCPListWithNoFilesIsEmpty(t *testing.T) {
	r := newMCPRig(t)
	out := r.mustOK(r.list(`{"projectId":"` + r.id + `"}`))
	if servers := out["servers"].([]any); len(servers) != 0 {
		t.Fatalf("servers = %v", servers)
	}
}

func TestMCPSetDisabledTrueThenFalseKeepsOtherKeys(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"web","disabled":true}`))
	var file map[string]any
	if err := json.Unmarshal([]byte(readFileString(t, r.projectFile())), &file); err != nil {
		t.Fatal(err)
	}
	web := file["mcpServers"].(map[string]any)["web"].(map[string]any)
	if web["disabled"] != true || web["url"] != "https://secret.example.test/mcp" {
		t.Fatalf("web after disable: %v", web)
	}
	if file["theme"] != "dark" {
		t.Fatalf("top-level key changed: %v", file["theme"])
	}
	out := r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"web","disabled":false}`))
	for _, raw := range out["servers"].([]any) {
		sv := raw.(map[string]any)
		if sv["name"] == "web" && sv["disabled"] != false {
			t.Fatalf("result does not show web enabled: %v", sv)
		}
	}
	json.Unmarshal([]byte(readFileString(t, r.projectFile())), &file)
	web = file["mcpServers"].(map[string]any)["web"].(map[string]any)
	if web["disabled"] != false || web["alwaysAllow"] == nil {
		t.Fatalf("web after enable: %v", web)
	}
}

func TestMCPSetWritesMode0600AndNoTempFile(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	if err := os.Chmod(r.projectFile(), 0o644); err != nil {
		t.Fatal(err)
	}
	r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
	info, err := os.Stat(r.projectFile())
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
	entries, _ := os.ReadDir(filepath.Dir(r.projectFile()))
	for _, e := range entries {
		if e.Name() != "mcp.json" {
			t.Fatalf("extra file in .bob: %s", e.Name())
		}
	}
}

func TestMCPSetOnHomeSourceWritesTheHomeFile(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.homeFile(), `{"mcpServers": {"home-tool": {"command": "uvx"}}}`)
	r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"home-tool","disabled":true,"source":"home"}`))
	if !strings.Contains(readFileString(t, r.homeFile()), `"disabled": true`) {
		t.Fatalf("home file not updated: %s", readFileString(t, r.homeFile()))
	}
	if _, err := os.Stat(r.projectFile()); err == nil {
		t.Fatal("a project file was created")
	}
}

func TestMCPSetRefusesMissingName(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	before := readFileString(t, r.projectFile())
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"absent","disabled":true}`))
	if readFileString(t, r.projectFile()) != before {
		t.Fatal("file changed on a refused set")
	}
	// No file at all is also a refusal: the gateway never adds a server (D-084).
	os.Remove(r.projectFile())
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
	if _, err := os.Stat(r.projectFile()); err == nil {
		t.Fatal("a file was created by a refused set")
	}
}

// D-089: the phone may set a server's alwaysAllow. The file holds the names; the list reports
// only the count, and the audit line holds no name.
func TestMCPSetWritesAlwaysAllow(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	out := r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"web","disabled":false,"alwaysAllow":["tool-alpha","tool-beta"]}`))
	webInFile := func() map[string]any {
		t.Helper()
		var file map[string]any
		if err := json.Unmarshal([]byte(readFileString(t, r.projectFile())), &file); err != nil {
			t.Fatal(err)
		}
		return file["mcpServers"].(map[string]any)["web"].(map[string]any)
	}
	web := webInFile()
	if !reflect.DeepEqual(web["alwaysAllow"], []any{"tool-alpha", "tool-beta"}) || web["disabled"] != false {
		t.Fatalf("web after set: %v", web)
	}
	if web["url"] != "https://secret.example.test/mcp" {
		t.Fatalf("the url changed: %v", web)
	}
	body, _ := json.Marshal(out)
	if strings.Contains(string(body), "tool-alpha") {
		t.Fatalf("a tool name is in the set result: %s", body)
	}
	found := false
	for _, raw := range out["servers"].([]any) {
		if sv := raw.(map[string]any); sv["name"] == "web" && sv["source"] == "project" {
			found = true
			if sv["alwaysAllow"] != float64(2) {
				t.Fatalf("list reports %v, want 2", sv["alwaysAllow"])
			}
		}
	}
	if !found {
		t.Fatalf("web not listed: %v", out)
	}
	logs := r.logs.String()
	if !strings.Contains(logs, "alwaysAllow=2") || strings.Contains(logs, "tool-alpha") {
		t.Fatalf("the audit line must hold the count only: %s", logs)
	}
	// An empty list clears the names.
	r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"web","disabled":false,"alwaysAllow":[]}`))
	if got := webInFile()["alwaysAllow"]; !reflect.DeepEqual(got, []any{}) {
		t.Fatalf("alwaysAllow after an empty set: %v", got)
	}
}

// D-089: a bad alwaysAllow is refused before anything is written.
func TestMCPSetRefusesBadAlwaysAllow(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	before := readFileString(t, r.projectFile())
	for _, list := range []string{
		`"search"`,
		`["search",1]`,
		`[""]`,
		`["   "]`,
		`["` + strings.Repeat("x", 129) + `"]`,
		toolNames(65, 4),
	} {
		r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"web","disabled":true,"alwaysAllow":` + list + `}`))
	}
	if readFileString(t, r.projectFile()) != before {
		t.Fatal("file changed by a refused alwaysAllow")
	}
}

func TestMCPSetNeedsDisabledAndAName(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":"yes"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","disabled":true}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"","disabled":true}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"bad\nname","disabled":true}`))
}

func TestMCPSetWithoutProjectIDIsRefused(t *testing.T) {
	r := newMCPRig(t)
	r.mustRefuse(r.set(`{"name":"docs","disabled":true}`))
}

func TestMCPSymlinkComponentRefused(t *testing.T) {
	r := newMCPRig(t)
	// <project>/.bob is a link to a folder outside the project that holds a valid config.
	outsideBob := filepath.Join(r.outside, "bob")
	r.writeFile(filepath.Join(outsideBob, "mcp.json"), mcpFixture)
	if err := os.Symlink(outsideBob, filepath.Join(r.project, ".bob")); err != nil {
		t.Fatal(err)
	}
	before := readFileString(t, filepath.Join(outsideBob, "mcp.json"))
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
	if readFileString(t, filepath.Join(outsideBob, "mcp.json")) != before {
		t.Fatal("a file outside the project was written through a symlinked folder")
	}
}

func TestMCPHomeSymlinkComponentRefused(t *testing.T) {
	r := newMCPRig(t)
	outsideSettings := filepath.Join(r.outside, "settings")
	r.writeFile(filepath.Join(outsideSettings, "mcp.json"), mcpFixture)
	settings := filepath.Join(r.home, ".bob", "settings")
	if err := os.RemoveAll(settings); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideSettings, settings); err != nil {
		t.Fatal(err)
	}
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true,"source":"home"}`))
	if !strings.Contains(readFileString(t, filepath.Join(outsideSettings, "mcp.json")), `"command": "node"`) {
		t.Fatal("outside file changed")
	}
}

func TestMCPSymlinkFileRefused(t *testing.T) {
	r := newMCPRig(t)
	target := filepath.Join(r.outside, "mcp.json")
	r.writeFile(target, mcpFixture)
	if err := os.MkdirAll(filepath.Join(r.project, ".bob"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, r.projectFile()); err != nil {
		t.Fatal(err)
	}
	before := readFileString(t, target)
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
	if readFileString(t, target) != before {
		t.Fatal("a symlink target outside the project was written")
	}
}

func TestMCPSymlinkFileInsideProjectRefused(t *testing.T) {
	r := newMCPRig(t)
	// A link inside the project to another file inside the project is refused too: the file is not
	// the one the path names (D-063 applies the same rule to every path).
	inner := filepath.Join(r.project, "other.json")
	if err := os.WriteFile(inner, []byte(mcpFixture), 0o600); err != nil {
		t.Fatal(err)
	}
	r.writeFile(filepath.Join(r.project, "placeholder"), "x")
	if err := os.MkdirAll(filepath.Join(r.project, ".bob"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(inner, r.projectFile()); err != nil {
		t.Fatal(err)
	}
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
}

func TestMCPOversizeRefused(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), strings.Repeat(" ", 256*1024)+mcpFixture)
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
}

func TestMCPInvalidJSONRefused(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), `{"mcpServers": {"docs": `)
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
	r.mustRefuse(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
}

func TestMCPNonRegularFileRefused(t *testing.T) {
	r := newMCPRig(t)
	if err := os.MkdirAll(filepath.Join(r.project, ".bob"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(r.projectFile(), 0o600); err != nil {
		t.Fatal(err)
	}
	r.mustRefuse(r.list(`{"projectId":"` + r.id + `"}`))
}

func TestMCPAuditHasNoFileContents(t *testing.T) {
	r := newMCPRig(t)
	r.writeFile(r.projectFile(), mcpFixture)
	r.mustOK(r.set(`{"projectId":"` + r.id + `","name":"docs","disabled":true}`))
	logs := r.logs.String()
	if !strings.Contains(logs, `"event":"mcp_set"`) || !strings.Contains(logs, `"project":"`+r.id+`"`) {
		t.Fatalf("no mcp_set line with the project: %s", logs)
	}
	if !strings.Contains(logs, "name=docs") || !strings.Contains(logs, "disabled=true") {
		t.Fatalf("mcp_set line lacks the name or the value: %s", logs)
	}
	for _, leak := range []string{"SECRET-HEADER-VALUE", "secret.example.test", "theme", "node"} {
		if strings.Contains(logs, leak) {
			t.Fatalf("audit holds file content %q: %s", leak, logs)
		}
	}
}

// A link in the path must be refused as a link, not only as "not a folder": the reason is what
// the audit log records (D-085), and a folder that is a link is the case the rule exists for.
func TestMCPRefusalNamesTheSymlink(t *testing.T) {
	r := newMCPRig(t)
	outsideBob := filepath.Join(r.outside, "bob")
	r.writeFile(filepath.Join(outsideBob, "mcp.json"), mcpFixture)
	if err := os.Symlink(outsideBob, filepath.Join(r.project, ".bob")); err != nil {
		t.Fatal(err)
	}
	p := &store.Project{ID: r.id, Path: r.project}
	if _, err := mcpPath(r.s.mcpFiles(p)[0]); refusalReason(err) != "symlink" {
		t.Fatalf("symlinked folder: reason %q (err %v), want symlink", refusalReason(err), err)
	}
	if err := os.Remove(filepath.Join(r.project, ".bob")); err != nil {
		t.Fatal(err)
	}
	r.writeFile(filepath.Join(r.outside, "mcp.json"), mcpFixture)
	if err := os.MkdirAll(filepath.Join(r.project, ".bob"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(r.outside, "mcp.json"), r.projectFile()); err != nil {
		t.Fatal(err)
	}
	if _, err := mcpPath(r.s.mcpFiles(p)[0]); refusalReason(err) != "symlink" {
		t.Fatalf("symlinked file: reason %q (err %v), want symlink", refusalReason(err), err)
	}
}
