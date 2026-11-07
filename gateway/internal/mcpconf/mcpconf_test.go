package mcpconf

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

const sample = `{
  "theme": {"name": "dark", "extra": [1, 2.50, "x"]},
  "mcpServers": {
    "docs": {"command": "node", "args": ["server.js"], "env": {"TOKEN": "x"}, "custom": {"keep": true}},
    "web": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer abc"}, "disabled": false, "alwaysAllow": ["search", "fetch"]}
  }
}`

func mustParse(t *testing.T, data string) *File {
	t.Helper()
	f, err := Parse([]byte(data))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return f
}

func decode(t *testing.T, data []byte) map[string]any {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, data)
	}
	return v
}

func TestParseListsServersWithoutSecrets(t *testing.T) {
	f := mustParse(t, sample)
	got := f.Servers()
	want := []Server{
		{Name: "docs", Disabled: false, AlwaysAllow: 0, Transport: "stdio"},
		{Name: "web", Disabled: false, AlwaysAllow: 2, Transport: "http"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Servers() = %+v, want %+v", got, want)
	}
}

func TestParseKeepsUnknownKeys(t *testing.T) {
	f := mustParse(t, sample)
	if err := f.SetDisabled("docs", true); err != nil {
		t.Fatal(err)
	}
	out, err := f.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	v := decode(t, out)
	if !reflect.DeepEqual(v["theme"], map[string]any{"name": "dark", "extra": []any{float64(1), 2.5, "x"}}) {
		t.Errorf("top-level unknown key changed: %v", v["theme"])
	}
	servers := v["mcpServers"].(map[string]any)
	docs := servers["docs"].(map[string]any)
	if !reflect.DeepEqual(docs["custom"], map[string]any{"keep": true}) || docs["command"] != "node" {
		t.Errorf("entry's unknown keys changed: %v", docs)
	}
	if !reflect.DeepEqual(docs["args"], []any{"server.js"}) || !reflect.DeepEqual(docs["env"], map[string]any{"TOKEN": "x"}) {
		t.Errorf("entry's other keys changed: %v", docs)
	}
	web := servers["web"].(map[string]any)
	if web["url"] != "https://example.com/mcp" || !reflect.DeepEqual(web["alwaysAllow"], []any{"search", "fetch"}) {
		t.Errorf("web entry changed: %v", web)
	}
}

func TestSetDisabledTrueAndFalse(t *testing.T) {
	f := mustParse(t, sample)
	if err := f.SetDisabled("web", true); err != nil {
		t.Fatal(err)
	}
	if got := serverNamed(t, f, "web"); !got.Disabled {
		t.Fatalf("web not disabled after SetDisabled(true): %+v", got)
	}
	if err := f.SetDisabled("web", false); err != nil {
		t.Fatal(err)
	}
	if got := serverNamed(t, f, "web"); got.Disabled {
		t.Fatalf("web still disabled after SetDisabled(false): %+v", got)
	}
	// The round trip through Marshal keeps the value.
	out, err := f.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	if got := serverNamed(t, mustParse(t, string(out)), "web"); got.Disabled || got.AlwaysAllow != 2 {
		t.Fatalf("after round trip: %+v", got)
	}
}

func serverNamed(t *testing.T, f *File, name string) Server {
	t.Helper()
	for _, s := range f.Servers() {
		if s.Name == name {
			return s
		}
	}
	t.Fatalf("no server %q", name)
	return Server{}
}

func TestSetDisabledRefusesMissingName(t *testing.T) {
	f := mustParse(t, sample)
	if err := f.SetDisabled("nope", true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing name: err = %v, want ErrNotFound", err)
	}
	if f.Has("nope") {
		t.Fatal("Has reports a missing server")
	}
}

func TestParseRefusesNonObjectsAndBadTypes(t *testing.T) {
	cases := map[string]string{
		"not JSON":             `{"mcpServers": `,
		"two values":           `{} {}`,
		"top level array":      `[]`,
		"top level null":       `null`,
		"servers not object":   `{"mcpServers": []}`,
		"entry not object":     `{"mcpServers": {"a": "x"}}`,
		"disabled not bool":    `{"mcpServers": {"a": {"disabled": "yes"}}}`,
		"alwaysAllow not list": `{"mcpServers": {"a": {"alwaysAllow": true}}}`,
	}
	for name, data := range cases {
		if _, err := Parse([]byte(data)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestParseInvalidJSONIsInvalid(t *testing.T) {
	_, err := Parse([]byte(`{"mcpServers": `))
	if !errors.Is(err, ErrInvalidJSON) {
		t.Fatalf("err = %v, want ErrInvalidJSON", err)
	}
}

func TestParseEmptyFileHasNoServers(t *testing.T) {
	f := mustParse(t, `{}`)
	if len(f.Servers()) != 0 {
		t.Fatalf("servers = %+v", f.Servers())
	}
	f = mustParse(t, `{"mcpServers": null}`)
	if len(f.Servers()) != 0 {
		t.Fatalf("null servers: %+v", f.Servers())
	}
}

func TestReadRefusesOversizeFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	if err := os.WriteFile(path, []byte(strings.Repeat(" ", MaxBytes+1)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(path); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("err = %v, want ErrTooLarge", err)
	}
	ok := filepath.Join(dir, "ok.json")
	if err := os.WriteFile(ok, []byte(strings.Repeat(" ", MaxBytes)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(ok); err != nil {
		t.Fatalf("file of exactly MaxBytes refused: %v", err)
	}
}

func TestReadRefusesSymlink(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "real.json")
	if err := os.WriteFile(target, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "mcp.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(link); !errors.Is(err, ErrSymlink) {
		t.Fatalf("err = %v, want ErrSymlink", err)
	}
}

func TestReadRefusesNonRegular(t *testing.T) {
	dir := t.TempDir()
	if _, err := Read(dir); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("directory: err = %v, want ErrNotRegular", err)
	}
	fifo := filepath.Join(dir, "pipe.json")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(fifo); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("fifo: err = %v, want ErrNotRegular", err)
	}
}

func TestReadMissingFileIsNotExist(t *testing.T) {
	_, err := Read(filepath.Join(t.TempDir(), "mcp.json"))
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("err = %v, want os.ErrNotExist", err)
	}
}

func TestWriteRoundTripMode0600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	if err := Write(path, []byte(`{"mcpServers":{}}`)); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o, want 600", info.Mode().Perm())
	}
	data, err := Read(path)
	if err != nil || string(data) != `{"mcpServers":{}}` {
		t.Fatalf("read back %q, %v", data, err)
	}
	assertNoTemp(t, dir)
}

func TestWriteReplacesExistingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	if err := os.WriteFile(path, []byte(`old`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Write(path, []byte(`new`)); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "new" {
		t.Fatalf("content = %q", data)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode after replace = %o, want 600", info.Mode().Perm())
	}
	assertNoTemp(t, dir)
}

func TestWriteCreatesMissingBobFolderAs0700(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bob", "settings", "mcp.json")
	if err := Write(path, []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, ".bob"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf(".bob mode = %o, want 700", info.Mode().Perm())
	}
}

func TestWriteLeavesNoTempFileWhenRenameFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	if err := os.WriteFile(path, []byte(`original`), 0o600); err != nil {
		t.Fatal(err)
	}
	old := rename
	rename = func(string, string) error { return errors.New("injected rename failure") }
	defer func() { rename = old }()
	if err := Write(path, []byte(`changed`)); err == nil {
		t.Fatal("Write succeeded with a failing rename")
	}
	data, _ := os.ReadFile(path)
	if string(data) != "original" {
		t.Fatalf("original changed to %q", data)
	}
	assertNoTemp(t, dir)
}

func TestWriteLeavesNoTempFileWhenSyncFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "mcp.json")
	old := syncFile
	syncFile = func(*os.File) error { return errors.New("injected sync failure") }
	defer func() { syncFile = old }()
	if err := Write(path, []byte(`x`)); err == nil {
		t.Fatal("Write succeeded with a failing fsync")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("target created after a failed write: %v", err)
	}
	assertNoTemp(t, dir)
}

func TestWriteRefusesSymlinkTarget(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real.json")
	if err := os.WriteFile(real, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "mcp.json")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if err := Write(link, []byte(`{"x":1}`)); !errors.Is(err, ErrSymlink) {
		t.Fatalf("err = %v, want ErrSymlink", err)
	}
	data, _ := os.ReadFile(real)
	if string(data) != `{}` {
		t.Fatalf("link target changed to %q", data)
	}
}

func TestWriteRefusesOversize(t *testing.T) {
	dir := t.TempDir()
	if err := Write(filepath.Join(dir, "mcp.json"), []byte(strings.Repeat(" ", MaxBytes+1))); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("err = %v, want ErrTooLarge", err)
	}
	assertNoTemp(t, dir)
}

func assertNoTemp(t *testing.T, dir string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}
}

// D-089: SetAlwaysAllow replaces the list of a server already in the file and nothing else.
func TestSetAlwaysAllowReplacesOnlyTheList(t *testing.T) {
	f := mustParse(t, sample)
	if err := f.SetAlwaysAllow("docs", []string{"a", "b", "c"}); err != nil {
		t.Fatal(err)
	}
	if got := serverNamed(t, f, "docs"); got.AlwaysAllow != 3 {
		t.Fatalf("docs after set: %+v", got)
	}
	out, err := f.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	docs := decode(t, out)["mcpServers"].(map[string]any)["docs"].(map[string]any)
	if !reflect.DeepEqual(docs["alwaysAllow"], []any{"a", "b", "c"}) || docs["command"] != "node" {
		t.Fatalf("docs entry: %v", docs)
	}
	if err := f.SetAlwaysAllow("web", nil); err != nil {
		t.Fatal(err)
	}
	if got := serverNamed(t, f, "web"); got.AlwaysAllow != 0 {
		t.Fatalf("web after a nil list: %+v", got)
	}
	if err := f.SetAlwaysAllow("nope", []string{"x"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing name: err = %v, want ErrNotFound", err)
	}
	if f.Has("nope") {
		t.Fatal("SetAlwaysAllow added a server")
	}
}
