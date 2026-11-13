package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

// workingDirTestServer is folderTestServer with the state folder made, as main makes it before the
// gateway starts. The default folder is <stateDir>/working_dir.
func workingDirTestServer(t *testing.T) (s *Server, stateDir string) {
	t.Helper()
	s, _, _, _ = folderTestServer(t)
	stateDir = s.cfg.StateDir
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	return s, stateDir
}

// The default folder is made at start with mode 0700 and registered as the project "working_dir".
func TestWorkingDirProjectIsMadeInStateDirAt0700(t *testing.T) {
	s, stateDir := workingDirTestServer(t)
	if err := s.EnsureWorkingDir(context.Background()); err != nil {
		t.Fatalf("EnsureWorkingDir: %v", err)
	}
	dir := filepath.Join(stateDir, "working_dir")
	info, err := os.Lstat(dir)
	if err != nil {
		t.Fatalf("working_dir folder not made: %v", err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("working_dir: want a folder with mode 0700, got %v %v", info.Mode().IsDir(), info.Mode().Perm())
	}
	projects, err := s.store.Projects(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 {
		t.Fatalf("want one project, got %d", len(projects))
	}
	p := projects[0]
	real, err := realpath(dir)
	if err != nil {
		t.Fatal(err)
	}
	if p.Name != "working_dir" || p.Path != real {
		t.Fatalf("project: want name working_dir at %s, got name %q at %s", real, p.Name, p.Path)
	}
}

// A second start finds the project and the folder and adds nothing.
func TestWorkingDirEnsureIsIdempotent(t *testing.T) {
	s, _ := workingDirTestServer(t)
	ctx := context.Background()
	for i := 0; i < 2; i++ {
		if err := s.EnsureWorkingDir(ctx); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
	}
	projects, err := s.store.Projects(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 {
		t.Fatalf("want one project after two starts, got %d", len(projects))
	}
}

// A session may start in the default folder: its cwd is allowed. The state folder itself is not.
func TestWorkingDirIsAnAllowedSessionCwd(t *testing.T) {
	s, stateDir := workingDirTestServer(t)
	ctx := context.Background()
	if err := s.EnsureWorkingDir(ctx); err != nil {
		t.Fatal(err)
	}
	inside := mustRaw(t, `{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"`+filepath.Join(stateDir, "working_dir")+`"}}`)
	if !cwdAllowed(inside, s.allowedCwdRoots()) {
		t.Fatal("cwd in the default folder was refused")
	}
	outside := mustRaw(t, `{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"`+stateDir+`"}}`)
	if cwdAllowed(outside, s.allowedCwdRoots()) {
		t.Fatal("cwd at the state folder was allowed")
	}
}

// The phone cannot register a folder over the default folder or in the state folder, and the default
// folder is not offered as a root for new projects.
func TestWorkingDirCannotBeRegisteredOrMadeByPath(t *testing.T) {
	s, stateDir := workingDirTestServer(t)
	ctx := context.Background()
	if err := s.EnsureWorkingDir(ctx); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(stateDir, "working_dir")
	reg := mustRaw(t, `{"name":"again","path":"`+dir+`"}`)
	if _, _, _, rerr := s.createProject(ctx, reg); rerr == nil {
		t.Fatal("registering the default folder again was accepted")
	}
	if _, _, _, rerr := s.createProject(ctx, createFolderParams(t, stateDir, "sub")); rerr == nil {
		t.Fatal("making a folder in the state folder was accepted")
	}
	if _, _, _, rerr := s.createProject(ctx, createFolderParams(t, dir, "sub")); rerr == nil {
		t.Fatal("making a folder in the default folder was accepted")
	}
	for _, root := range s.projectRoots()["roots"].([]string) {
		if root == dir || root == stateDir {
			t.Fatalf("default folder or state folder offered as a root: %s", root)
		}
	}
	projects, err := s.store.Projects(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 || projects[0].Name != "working_dir" {
		t.Fatalf("project list changed by refused requests: %+v", projects)
	}
}

// A file or a link at the default folder's path is not replaced or followed: start is refused and
// the entry is left alone.
func TestWorkingDirRefusesAFileOrLinkAtItsPath(t *testing.T) {
	s, stateDir := workingDirTestServer(t)
	dir := filepath.Join(stateDir, "working_dir")
	if err := os.WriteFile(dir, []byte("not a folder"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureWorkingDir(context.Background()); err == nil {
		t.Fatal("a file at the default folder's path was accepted")
	}
	data, err := os.ReadFile(dir)
	if err != nil || string(data) != "not a folder" {
		t.Fatalf("the file was changed: %q %v", data, err)
	}

	other := t.TempDir()
	if err := os.Remove(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(other, dir); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureWorkingDir(context.Background()); err == nil {
		t.Fatal("a link at the default folder's path was accepted")
	}
}

func mustRaw(t *testing.T, s string) *jsonv.Value {
	t.Helper()
	v, err := jsonv.Parse([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return v
}
