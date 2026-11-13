package store

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"
)

// D-107: the set of gateway MCP servers each session enables is stored per session, replaced whole,
// read back after a reopen, and removed with the session.
func TestSessionMCPSetIsStoredReplacedAndRemoved(t *testing.T) {
	s, path := open(t)
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "p1", Name: "p", Path: "/p", Created: "2026-11-08T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordSession(ctx, "sess-1", "p1"); err != nil {
		t.Fatal(err)
	}
	if got, err := s.SessionMCP(ctx, "sess-1"); err != nil || len(got) != 0 {
		t.Fatalf("a new session enables none: %v, %v", got, err)
	}
	if err := s.SetSessionMCP(ctx, "sess-1", []string{"bb", "aa"}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSessionMCP(ctx, "sess-1", []string{"cc"}); err != nil {
		t.Fatal(err)
	}
	got, err := s.SessionMCP(ctx, "sess-1")
	if err != nil || !reflect.DeepEqual(got, []string{"cc"}) {
		t.Fatalf("replaced set = %v, %v", got, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}

	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if got, err := again.SessionMCP(ctx, "sess-1"); err != nil || !reflect.DeepEqual(got, []string{"cc"}) {
		t.Fatalf("after reopen = %v, %v", got, err)
	}
	if err := again.DeleteSession(ctx, "sess-1"); err != nil {
		t.Fatal(err)
	}
	if got, _ := again.SessionMCP(ctx, "sess-1"); len(got) != 0 {
		t.Fatalf("deleted session still has a set: %v", got)
	}
}

// A version 7 database (before D-107) gains the table on open, and keeps its sessions.
func TestSchemaV8AddsSessionMCPToAVersion7Database(t *testing.T) {
	s, path := open(t)
	ctx := context.Background()
	if _, err := s.db.Exec(`DROP TABLE session_mcp`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`ALTER TABLE projects DROP COLUMN runner`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`PRAGMA user_version = 7`); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := Open(filepath.Clean(path))
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if err := again.SetSessionMCP(ctx, "sess-9", []string{"aa"}); err != nil {
		t.Fatalf("the table is missing after the migration: %v", err)
	}
	var version int
	if err := again.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != 9 {
		t.Fatalf("version = %d, %v", version, err)
	}
}
