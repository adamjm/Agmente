package store

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
)

// A project keeps its watcher skip list (D-065), and a database made by schema 4 opens, keeps its
// projects (with no skip list) and takes the new column.
func TestProjectWatchSkipRoundTripAndSchema4Migration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	old := Project{ID: "aaaaaaaaaaaa", Name: "Old", Path: "/srv/p/old", Created: "2026-11-06T00:00:00.000Z", DenyPaths: []string{"*.db"}}
	if err := s.CreateProject(ctx, old); err != nil {
		t.Fatal(err)
	}
	// Rebuild the schema 4 shape: no watch_skip column.
	for _, q := range []string{`DROP TABLE session_usage`, `ALTER TABLE projects DROP COLUMN watch_skip`, `PRAGMA user_version = 4`} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	again, err := Open(path)
	if err != nil {
		t.Fatalf("a schema 4 database must open: %v", err)
	}
	defer again.Close()
	got, err := again.ProjectByID(ctx, old.ID)
	if err != nil || got == nil || !reflect.DeepEqual(got.DenyPaths, []string{"*.db"}) || got.WatchSkip != nil {
		t.Fatalf("migrated project = %+v, %v", got, err)
	}
	withSkip := Project{ID: "bbbbbbbbbbbb", Name: "New", Path: "/srv/p/new", Created: "2026-11-06T00:00:01.000Z", WatchSkip: []string{"cache", "out/tmp"}}
	if err := again.CreateProject(ctx, withSkip); err != nil {
		t.Fatal(err)
	}
	byPath, err := again.ProjectByPath(ctx, withSkip.Path)
	if err != nil || byPath == nil || !reflect.DeepEqual(byPath.WatchSkip, withSkip.WatchSkip) || byPath.DenyPaths != nil {
		t.Fatalf("by path = %+v, %v", byPath, err)
	}
	list, err := again.Projects(ctx)
	if err != nil || len(list) != 2 || list[0].WatchSkip != nil || !reflect.DeepEqual(list[1].WatchSkip, withSkip.WatchSkip) {
		t.Fatalf("list = %+v, %v", list, err)
	}
}

// UpdateProjectLists writes what fn sets, writes nothing when fn fails, and reports an unknown id.
func TestUpdateProjectListsIsAllOrNothing(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	if err := s.CreateProject(ctx, Project{ID: "aaaaaaaaaaaa", Name: "P", Path: "/srv/p", Created: "2026-11-06T00:00:00.000Z"}); err != nil {
		t.Fatal(err)
	}
	boom := errors.New("refused")
	if _, err := s.UpdateProjectLists(ctx, "aaaaaaaaaaaa", func(p *Project) error {
		p.DenyPaths = []string{"changed"}
		return boom
	}); !errors.Is(err, boom) {
		t.Fatalf("error = %v", err)
	}
	if got, _ := s.ProjectByID(ctx, "aaaaaaaaaaaa"); got.DenyPaths != nil {
		t.Fatalf("a refused update wrote %v", got.DenyPaths)
	}
	stored, err := s.UpdateProjectLists(ctx, "aaaaaaaaaaaa", func(p *Project) error {
		p.DenyPaths = []string{"*.db"}
		p.WatchSkip = []string{"cache"}
		return nil
	})
	if err != nil || stored == nil || !reflect.DeepEqual(stored.WatchSkip, []string{"cache"}) {
		t.Fatalf("update = %+v, %v", stored, err)
	}
	if got, _ := s.ProjectByID(ctx, "aaaaaaaaaaaa"); !reflect.DeepEqual(got.DenyPaths, []string{"*.db"}) || !reflect.DeepEqual(got.WatchSkip, []string{"cache"}) {
		t.Fatalf("stored = %+v", got)
	}
	none, err := s.UpdateProjectLists(ctx, "missing", func(p *Project) error { t.Fatal("fn must not run"); return nil })
	if err != nil || none != nil {
		t.Fatalf("unknown id = %+v, %v", none, err)
	}
}
