package store

import (
	"context"
	"path/filepath"
	"testing"
)

func TestPushTokensReplaceAndDelete(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state", "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	a := PushToken{Identity: "owner", Device: "phone", Token: "aa", Environment: "sandbox", Updated: "t1"}
	if err := s.SetPushToken(ctx, a); err != nil {
		t.Fatal(err)
	}
	a.Token, a.Environment = "bb", "production"
	if err := s.SetPushToken(ctx, a); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPushToken(ctx, PushToken{Identity: "owner", Device: "ipad", Token: "cc", Environment: "sandbox", Updated: "t2"}); err != nil {
		t.Fatal(err)
	}
	got, err := s.PushTokens(ctx, "owner")
	if err != nil || len(got) != 2 || got[1].Device != "phone" || got[1].Token != "bb" || got[1].Environment != "production" {
		t.Fatalf("tokens = %+v, %v", got, err)
	}
	if other, _ := s.PushTokens(ctx, "guest"); len(other) != 0 {
		t.Fatalf("another identity sees %+v", other)
	}
	if ok, err := s.DeletePushToken(ctx, "owner", "phone"); err != nil || !ok {
		t.Fatalf("delete = %v, %v", ok, err)
	}
	if ok, _ := s.DeletePushToken(ctx, "owner", "phone"); ok {
		t.Fatal("second delete reported a removal")
	}
}

// A schema 3 database opens, keeps its data and gains the push table.
func TestASchema3DatabaseGainsThePushTable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, _ := Open(path)
	ctx := context.Background()
	if _, err := s.AppendEvent(ctx, "sess-1", "update", []byte(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{`DROP TABLE session_usage`, `DROP TABLE push_tokens`, `ALTER TABLE projects DROP COLUMN watch_skip`, `PRAGMA user_version = 3`} {
		if _, err := s.db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	again, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	if head, err := again.HeadSeq(ctx, "sess-1"); err != nil || head != 1 {
		t.Fatalf("head %d, %v", head, err)
	}
	if err := again.SetPushToken(ctx, PushToken{Identity: "o", Device: "d", Token: "aa", Environment: "sandbox", Updated: "t"}); err != nil {
		t.Fatal(err)
	}
}
