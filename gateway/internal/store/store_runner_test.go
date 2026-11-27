package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"
)

// Schema 9 (multi-runner): a project keeps the runner it was made with, and the startup backfill only
// fills projects that have none.
func TestProjectRunnerRoundTripAndBackfillOnlyFillsUnsetRunners(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	created := time.Now().UTC().Format(time.RFC3339)
	for _, p := range []Project{
		{ID: "aaaaaaaaaaaa", Name: "kept-bob", Path: "/r/a", Created: created, Runner: "bob"},
		{ID: "bbbbbbbbbbbb", Name: "kept-omp", Path: "/r/b", Created: created, Runner: "omp"},
		{ID: "cccccccccccc", Name: "unset", Path: "/r/c", Created: created},
	} {
		if err := s.CreateProject(ctx, p); err != nil {
			t.Fatal(err)
		}
	}
	n, err := s.AssignUnsetRunners(ctx, "bob")
	if err != nil || n != 1 {
		t.Fatalf("AssignUnsetRunners = %d, %v; want 1 project changed", n, err)
	}
	again, err := s.AssignUnsetRunners(ctx, "omp")
	if err != nil || again != 0 {
		t.Fatalf("a second backfill changed %d projects; it must change none", again)
	}
	got, err := s.Projects(ctx)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"kept-bob": "bob", "kept-omp": "omp", "unset": "bob"}
	for _, p := range got {
		if want[p.Name] != p.Runner {
			t.Fatalf("project %s runner = %q, want %q", p.Name, p.Runner, want[p.Name])
		}
	}
}

// A schema 8 database has no runner column. Opening it migrates it, and its projects get NULL until
// the backfill assigns them.
func TestSchema8ProjectsGetNoRunnerUntilTheBackfill(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "dddddddddddd", Name: "old", Path: "/r/d", Created: time.Now().UTC().Format(time.RFC3339)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`ALTER TABLE projects DROP COLUMN auto_approve`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`ALTER TABLE projects DROP COLUMN runner`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`PRAGMA user_version = 8`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatalf("a schema 8 database must open: %v", err)
	}
	defer s.Close()
	var version int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != 10 {
		t.Fatalf("schema version = %d, %v; want 10", version, err)
	}
	if n, err := s.AssignUnsetRunners(ctx, "bob"); err != nil || n != 1 {
		t.Fatalf("backfill = %d, %v; want the one old project", n, err)
	}
	p, err := s.ProjectByID(ctx, "dddddddddddd")
	if err != nil || p == nil || p.Runner != "bob" {
		t.Fatalf("old project after backfill = %+v, %v", p, err)
	}
}

// Schema 10 (D-124): auto-approve is off by default, per project, and survives a read.
func TestProjectAutoApproveDefaultsOffAndIsPerProject(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	created := time.Now().UTC().Format(time.RFC3339)
	for _, p := range []Project{
		{ID: "aaaaaaaaaaaa", Name: "one", Path: "/r/a", Created: created, Runner: "bob"},
		{ID: "bbbbbbbbbbbb", Name: "two", Path: "/r/b", Created: created, Runner: "omp"},
	} {
		if err := s.CreateProject(ctx, p); err != nil {
			t.Fatal(err)
		}
	}
	if p, _ := s.ProjectByID(ctx, "aaaaaaaaaaaa"); p == nil || p.AutoApprove {
		t.Fatalf("a new project must not auto-approve: %+v", p)
	}
	p, err := s.SetAutoApprove(ctx, "aaaaaaaaaaaa", true)
	if err != nil || p == nil || !p.AutoApprove {
		t.Fatalf("SetAutoApprove(on) = %+v, %v", p, err)
	}
	if other, _ := s.ProjectByID(ctx, "bbbbbbbbbbbb"); other == nil || other.AutoApprove {
		t.Fatalf("the other project changed: %+v", other)
	}
	if p, err := s.SetAutoApprove(ctx, "aaaaaaaaaaaa", false); err != nil || p == nil || p.AutoApprove {
		t.Fatalf("SetAutoApprove(off) = %+v, %v", p, err)
	}
	if p, err := s.SetAutoApprove(ctx, "nope", true); err != nil || p != nil {
		t.Fatalf("an unknown project = %+v, %v; want nil, nil", p, err)
	}
}
