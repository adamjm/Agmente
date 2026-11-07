package store

import (
	"context"
	"testing"
)

// Usage is stored per session, replaced by each update, read on the index, and removed with the
// session (C1, D-092).
func TestSetUsageReplacesAndShowsOnTheIndex(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "p1", Name: "p", Path: "/p", Created: "2026-11-07T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordSession(ctx, "sess-1", "p1"); err != nil {
		t.Fatal(err)
	}
	cost, cur := 1.25, "USD"
	if err := s.SetUsage(ctx, "sess-1", Usage{Used: 100, Size: 1000, CostAmount: &cost, CostCurrency: &cur}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.SessionIndex(ctx, "owner", "")
	if err != nil || len(rows) != 1 || rows[0].Usage == nil {
		t.Fatalf("index = %+v, %v", rows, err)
	}
	u := rows[0].Usage
	if u.Used != 100 || u.Size != 1000 || *u.CostAmount != 1.25 || *u.CostCurrency != "USD" || len(u.Updated) != 24 {
		t.Fatalf("usage = %+v", u)
	}

	// The next update replaces the whole value: no cost in it means no cost stored.
	if err := s.SetUsage(ctx, "sess-1", Usage{Used: 200, Size: 1000}); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.SessionIndex(ctx, "owner", "")
	if u := rows[0].Usage; u.Used != 200 || u.CostAmount != nil || u.CostCurrency != nil {
		t.Fatalf("after replace: %+v", u)
	}

	// A usage update for an unknown session writes nothing (no row, so nothing to show or to leak).
	if err := s.SetUsage(ctx, "nobody", Usage{Used: 1, Size: 2}); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM session_usage WHERE session_id = 'nobody'`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("unknown session stored %d rows, %v", n, err)
	}

	// Deleting the session deletes its usage.
	if err := s.DeleteSession(ctx, "sess-1"); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM session_usage`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("usage left after delete: %d, %v", n, err)
	}
}

// A database at schema 5 gets the session_usage table when it is opened (migration 6).
func TestMigrationFromV5AddsSessionUsage(t *testing.T) {
	s, path := open(t)
	if _, err := s.db.Exec(`DROP TABLE session_usage`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`PRAGMA user_version = 5`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	var version int
	if err := again.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil || version != SchemaVersion || SchemaVersion != 6 {
		t.Fatalf("version = %d, %v", version, err)
	}
	var n int
	if err := again.db.QueryRow(`SELECT COUNT(*) FROM session_usage`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("session_usage after migration: %d, %v", n, err)
	}
}
