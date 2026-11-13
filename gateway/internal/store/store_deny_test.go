package store

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"
)

// A project keeps its deny-list additions (D-050), and a database made by schema 2 opens, keeps its
// projects (with no additions) and takes the new column.
func TestProjectDenyPathsRoundTripAndSchema2Migration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	old := Project{ID: "aaaaaaaaaaaa", Name: "Old", Path: "/srv/p/old", Created: "2026-11-06T00:00:00.000Z"}
	if err := s.CreateProject(ctx, old); err != nil {
		t.Fatal(err)
	}
	// Rebuild the schema 2 shape: no deny_paths column.
	for _, q := range []string{`DROP TABLE session_mcp`, `DROP TABLE git_credentials`, `DROP TABLE session_usage`, `DROP TABLE push_tokens`, `ALTER TABLE projects DROP COLUMN watch_skip`, `ALTER TABLE projects DROP COLUMN deny_paths`, `ALTER TABLE projects DROP COLUMN runner`, `PRAGMA user_version = 2`} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	again, err := Open(path)
	if err != nil {
		t.Fatalf("a schema 2 database must open: %v", err)
	}
	defer again.Close()
	got, err := again.ProjectByID(ctx, old.ID)
	if err != nil || got == nil || got.Name != "Old" || got.DenyPaths != nil {
		t.Fatalf("migrated project = %+v, %v", got, err)
	}
	withDeny := Project{ID: "bbbbbbbbbbbb", Name: "New", Path: "/srv/p/new", Created: "2026-11-06T00:00:01.000Z", DenyPaths: []string{"*.db", "config/prod.yml"}}
	if err := again.CreateProject(ctx, withDeny); err != nil {
		t.Fatal(err)
	}
	byID, err := again.ProjectByID(ctx, withDeny.ID)
	if err != nil || byID == nil || !reflect.DeepEqual(byID.DenyPaths, withDeny.DenyPaths) {
		t.Fatalf("by id = %+v, %v", byID, err)
	}
	byPath, err := again.ProjectByPath(ctx, withDeny.Path)
	if err != nil || byPath == nil || !reflect.DeepEqual(byPath.DenyPaths, withDeny.DenyPaths) {
		t.Fatalf("by path = %+v, %v", byPath, err)
	}
	list, err := again.Projects(ctx)
	if err != nil || len(list) != 2 || !reflect.DeepEqual(list[1].DenyPaths, withDeny.DenyPaths) || list[0].DenyPaths != nil {
		t.Fatalf("list = %+v, %v", list, err)
	}
}
