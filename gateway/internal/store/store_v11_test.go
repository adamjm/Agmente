package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

// dropV11Columns takes the schema 11 columns off a database, so a test can rebuild the shape of
// an older schema and then reopen it.
func dropV11Columns(t *testing.T, db *sql.DB) {
	t.Helper()
	for _, q := range []string{
		`ALTER TABLE sessions DROP COLUMN runner`,
		`ALTER TABLE projects DROP COLUMN parent_id`,
		`ALTER TABLE projects DROP COLUMN branch`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
}

// A session keeps the runner it was made on, and a session with none recorded reports "" (it runs
// on its project's runner, D-125).
func TestSessionRunnerRoundTrip(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "aaaaaaaaaaaa", Name: "p", Path: "/r/p", Created: time.Now().UTC().Format(time.RFC3339), Runner: "bob"}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"s1", "s2"} {
		if err := s.RecordSession(ctx, id, "aaaaaaaaaaaa"); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := s.SessionRunner(ctx, "s1"); err != nil || got != "" {
		t.Fatalf("a new session's runner = %q, %v; want none", got, err)
	}
	if err := s.SetSessionRunner(ctx, "s1", "claude"); err != nil {
		t.Fatal(err)
	}
	if got, err := s.SessionRunner(ctx, "s1"); err != nil || got != "claude" {
		t.Fatalf("s1 runner = %q, %v; want claude", got, err)
	}
	if got, err := s.SessionRunner(ctx, "s2"); err != nil || got != "" {
		t.Fatalf("s2 runner = %q, %v; want none", got, err)
	}
	if got, err := s.SessionRunner(ctx, "unknown"); err != nil || got != "" {
		t.Fatalf("an unknown session's runner = %q, %v; want none", got, err)
	}
}

// A worktree project keeps its parent and branch; an ordinary project has neither.
func TestWorktreeProjectRoundTrip(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	now := time.Now().UTC().Format(time.RFC3339)
	if err := s.CreateProject(ctx, Project{ID: "aaaaaaaaaaaa", Name: "site", Path: "/r/site", Created: now, Runner: "bob"}); err != nil {
		t.Fatal(err)
	}
	child := Project{ID: "bbbbbbbbbbbb", Name: "site (claude)", Path: "/r/site-claude", Created: now, Runner: "claude", ParentID: "aaaaaaaaaaaa", Branch: "acpcode/claude/abc"}
	if err := s.CreateProject(ctx, child); err != nil {
		t.Fatal(err)
	}
	parent, err := s.ProjectByID(ctx, "aaaaaaaaaaaa")
	if err != nil || parent == nil || parent.ParentID != "" || parent.Branch != "" {
		t.Fatalf("parent = %+v, %v", parent, err)
	}
	got, err := s.ProjectByID(ctx, child.ID)
	if err != nil || got == nil || got.ParentID != child.ParentID || got.Branch != child.Branch || got.Runner != "claude" {
		t.Fatalf("child = %+v, %v", got, err)
	}
}
