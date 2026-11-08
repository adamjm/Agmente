package server

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// folderTestServer is a server with one root and a folder outside it. Both paths are realpaths, as
// the gateway resolves them at start.
func folderTestServer(t *testing.T) (s *Server, db *store.Store, root, outside string) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root = filepath.Join(dir, "root")
	outside = filepath.Join(dir, "outside")
	for _, p := range []string{root, outside} {
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	db, err = store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	cfg := &config.Config{Roots: []string{root}, StateDir: filepath.Join(dir, "state"), Runner: config.Runner{Kind: "host"}}
	s = New(cfg, audit.New(&bytes.Buffer{}), db)
	t.Cleanup(s.Shutdown)
	return s, db, root, outside
}

// setFolderHook installs the test hook for one test and removes it afterwards.
func setFolderHook(t *testing.T, hook func(stage, path string)) {
	t.Helper()
	folderHook = hook
	t.Cleanup(func() { folderHook = nil })
}

func createFolderParams(t *testing.T, parent, name string) *jsonv.Value {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"createFolder": true, "name": name, "path": parent})
	if err != nil {
		t.Fatal(err)
	}
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func projectCount(t *testing.T, db *store.Store) int {
	t.Helper()
	projects, err := db.Projects(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return len(projects)
}

// A file that takes the new folder's name in the window is not a folder: the call is refused, the
// file is left alone, and nothing is registered.
func TestFolderModeRefusesAFileThatReplacedTheNewFolder(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	target := filepath.Join(root, "swapped")
	setFolderHook(t, func(stage, path string) {
		if stage != "after-mkdir" {
			return
		}
		if err := os.Remove(path); err != nil {
			t.Errorf("remove the new folder: %v", err)
		}
		if err := os.WriteFile(path, []byte("keep"), 0o600); err != nil {
			t.Errorf("write the file: %v", err)
		}
	})
	_, _, _, rerr := s.createProject(context.Background(), createFolderParams(t, root, "swapped"))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want a -32602 refusal, got %+v", rerr)
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "keep" {
		t.Fatalf("the file that replaced the folder was changed or removed: %v %q", err, data)
	}
	if n := projectCount(t, db); n != 0 {
		t.Fatalf("%d projects registered, want 0", n)
	}
}

// A link that takes the new folder's name in the window must not make the gateway change the mode
// of whatever it points to. chmod follows links, so the mode must be set through a folder that is
// still a folder.
func TestFolderModeNeverChangesAFolderOutsideTheRoots(t *testing.T) {
	s, db, root, outside := folderTestServer(t)
	setFolderHook(t, func(stage, path string) {
		if stage != "after-mkdir" {
			return
		}
		if err := os.Remove(path); err != nil {
			t.Errorf("remove the new folder: %v", err)
		}
		if err := os.Symlink(outside, path); err != nil {
			t.Errorf("link the name to the outside folder: %v", err)
		}
	})
	_, _, _, rerr := s.createProject(context.Background(), createFolderParams(t, root, "linked"))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want a -32602 refusal, got %+v", rerr)
	}
	info, err := os.Stat(outside)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode() & os.ModePerm; got != 0o700 {
		t.Fatalf("the folder outside the roots has mode %o, want 700: it was changed through the link", got)
	}
	if n := projectCount(t, db); n != 0 {
		t.Fatalf("%d projects registered, want 0", n)
	}
}

// The parent is swapped for a link to a folder outside the roots after the check and before the
// mkdir. Nothing may be made outside the roots, even for a moment, and nothing is left behind.
func TestAParentSwappedForALinkMakesNothingOutsideTheRoots(t *testing.T) {
	s, db, root, outside := folderTestServer(t)
	sub := filepath.Join(root, "sub")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	setFolderHook(t, func(stage, path string) {
		switch stage {
		case "before-mkdir":
			if err := os.Rename(sub, sub+".moved"); err != nil {
				t.Errorf("move the parent aside: %v", err)
			}
			if err := os.Symlink(outside, sub); err != nil {
				t.Errorf("link the parent to the outside folder: %v", err)
			}
		case "after-mkdir":
			if _, err := os.Lstat(filepath.Join(outside, "via-swap")); err == nil {
				t.Errorf("a folder was made outside the roots through the swapped parent")
			}
		}
	})
	_, _, _, rerr := s.createProject(context.Background(), createFolderParams(t, sub, "via-swap"))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want a -32602 refusal, got %+v", rerr)
	}
	if _, err := os.Lstat(filepath.Join(outside, "via-swap")); err == nil {
		t.Fatalf("a folder was left outside the roots")
	}
	if _, err := os.Lstat(filepath.Join(sub+".moved", "via-swap")); err == nil {
		t.Fatalf("the refused folder was left behind")
	}
	if n := projectCount(t, db); n != 0 {
		t.Fatalf("%d projects registered, want 0", n)
	}
}

// When registration is refused after the folder is made, the folder this call made is removed,
// and only that: a file at the name is never removed.
func TestRegistrationRefusalRemovesTheFolderItMadeAndNothingElse(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	target := filepath.Join(root, "race")
	setFolderHook(t, func(stage, path string) {
		if stage != "after-mkdir" {
			return
		}
		// Another request registers the same path between the check and the registration.
		if err := db.CreateProject(context.Background(), store.Project{ID: "racer00000001", Name: "race", Path: path, Created: time.Now().UTC().Format(time.RFC3339)}); err != nil {
			t.Errorf("register the racing project: %v", err)
		}
	})
	_, _, _, rerr := s.createProject(context.Background(), createFolderParams(t, root, "race"))
	if rerr == nil || rerr.Code != rpcInvalidParams {
		t.Fatalf("want a -32602 refusal, got %+v", rerr)
	}
	if _, err := os.Lstat(target); err == nil {
		t.Fatalf("the folder this call made was left behind")
	}
	if n := projectCount(t, db); n != 1 {
		t.Fatalf("%d projects registered, want only the racing one", n)
	}
}

func TestRegistrationRefusalKeepsAFileAtTheName(t *testing.T) {
	s, db, root, _ := folderTestServer(t)
	target := filepath.Join(root, "race-file")
	setFolderHook(t, func(stage, path string) {
		if stage != "after-mkdir" {
			return
		}
		if err := os.Remove(path); err != nil {
			t.Errorf("remove the new folder: %v", err)
		}
		if err := os.WriteFile(path, []byte("keep"), 0o600); err != nil {
			t.Errorf("write the file: %v", err)
		}
		if err := db.CreateProject(context.Background(), store.Project{ID: "racer00000002", Name: "race-file", Path: path, Created: time.Now().UTC().Format(time.RFC3339)}); err != nil {
			t.Errorf("register the racing project: %v", err)
		}
	})
	if _, _, _, rerr := s.createProject(context.Background(), createFolderParams(t, root, "race-file")); rerr == nil {
		t.Fatal("want a refusal")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "keep" {
		t.Fatalf("the file at the name was changed or removed: %v %q", err, data)
	}
}

// Only a root that still exists, once, is listed: a root removed after start is not offered.
func TestProjectRootsListsOnlyRootsThatStillExist(t *testing.T) {
	s, _, root, _ := folderTestServer(t)
	gone := filepath.Join(filepath.Dir(root), "gone")
	if err := os.Mkdir(gone, 0o700); err != nil {
		t.Fatal(err)
	}
	s.roots = []string{root, root, gone}
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	got := s.projectRoots()["roots"].([]string)
	if len(got) != 1 || got[0] != root {
		t.Fatalf("roots = %v, want [%s]", got, root)
	}
}
