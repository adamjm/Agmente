package store

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func open(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, path
}

func TestOpenUsesWALAndCreatesTheSchemaOnce(t *testing.T) {
	s, path := open(t)
	if mode, err := s.JournalMode(); err != nil || mode != "wal" {
		t.Fatalf("journal_mode = %q, %v", mode, err)
	}
	var tables int
	if err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type = 'table'`).Scan(&tables); err != nil || tables != 10 { // projects, sessions, events, reads, approvals, snapshots, push_tokens, session_usage, git_credentials (D-105), session_mcp (D-107)
		t.Fatalf("tables = %d, %v", tables, err)
	}
	s.Close()
	again, err := Open(path) // reopen: no second migration
	if err != nil {
		t.Fatal(err)
	}
	again.Close()
	info, err := os.Stat(filepath.Dir(path))
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("state dir mode = %v, %v", info.Mode().Perm(), err)
	}
}

func TestANewerSchemaIsRefused(t *testing.T) {
	s, path := open(t)
	if _, err := s.db.Exec(`PRAGMA user_version = 99`); err != nil {
		t.Fatal(err)
	}
	s.Close()
	if _, err := Open(path); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Fatalf("expected a refusal, got %v", err)
	}
}

func TestSeqStartsAt1AndIncreasesBy1PerSession(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	for i := 1; i <= 3; i++ {
		for _, id := range []string{"a", "b"} {
			seq, err := s.AppendEvent(ctx, id, "update", []byte(fmt.Sprintf(`{"n":%d}`, i)))
			if err != nil || seq != int64(i) {
				t.Fatalf("%s: seq = %d, %v; want %d", id, seq, err, i)
			}
		}
	}
	var got []string
	if err := s.EventsAfter(ctx, "a", 1, 0, func(e Event) error { got = append(got, fmt.Sprintf("%d:%s", e.Seq, e.Message)); return nil }); err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, " ") != `2:{"n":2} 3:{"n":3}` {
		t.Fatalf("got %v", got)
	}
	got = nil
	_ = s.EventsAfter(ctx, "a", 0, 2, func(e Event) error { got = append(got, strconv.FormatInt(e.Seq, 10)); return nil })
	if strings.Join(got, ",") != "1,2" {
		t.Fatalf("upTo: got %v", got)
	}
	if head, _ := s.HeadSeq(ctx, "a"); head != 3 {
		t.Fatalf("head = %d", head)
	}
	if head, _ := s.HeadSeq(ctx, "none"); head != 0 {
		t.Fatalf("empty head = %d", head)
	}
}

// Informational timing for NFR-6 (T-19 is the gateway-level check in task 3.6).
func TestTenThousandEventsWriteAndReplay(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	msg := []byte(`{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"` + strings.Repeat("x", 200) + `"}}}}`)
	start := time.Now()
	for i := 0; i < 10_000; i++ {
		if _, err := s.AppendEvent(ctx, "s", "update", msg); err != nil {
			t.Fatal(err)
		}
	}
	write := time.Since(start)
	start = time.Now()
	n := 0
	if err := s.EventsAfter(ctx, "s", 0, 0, func(Event) error { n++; return nil }); err != nil {
		t.Fatal(err)
	}
	read := time.Since(start)
	if n != 10_000 {
		t.Fatalf("read %d events", n)
	}
	t.Logf("10000 events (%d bytes each): write %v (one commit each), read %v", len(msg), write, read)
	if read > time.Second {
		t.Fatalf("replay read took %v, NFR-6 allows 1 s", read)
	}
}

// A committed event survives SIGKILL of the writing process (NFR-7, store level; T-20 is the
// gateway-level check in task 3.5). The child prints each seq after AppendEvent returns.
func TestCommittedEventsSurviveSIGKILL(t *testing.T) {
	if os.Getenv("ACPCODE_STORE_CHILD") != "" {
		s, err := Open(os.Getenv("ACPCODE_STORE_CHILD"))
		if err != nil {
			fmt.Println("ERR", err)
			os.Exit(1)
		}
		for {
			seq, err := s.AppendEvent(context.Background(), "s", "update", []byte(`{"x":1}`))
			if err != nil {
				fmt.Println("ERR", err)
				os.Exit(1)
			}
			fmt.Println(seq)
		}
	}
	path := filepath.Join(t.TempDir(), "gateway.db")
	cmd := exec.Command(os.Args[0], "-test.run=^TestCommittedEventsSurviveSIGKILL$")
	cmd.Env = append(os.Environ(), "ACPCODE_STORE_CHILD="+path)
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	sc := bufio.NewScanner(out)
	var acked int64
	for sc.Scan() {
		if strings.HasPrefix(sc.Text(), "ERR") {
			t.Fatal(sc.Text())
		}
		if n, err := strconv.ParseInt(sc.Text(), 10, 64); err == nil {
			acked = n
		}
		if acked >= 500 {
			break
		}
	}
	_ = cmd.Process.Signal(syscall.SIGKILL)
	_ = cmd.Wait()

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	head, err := s.HeadSeq(context.Background(), "s")
	if err != nil {
		t.Fatal(err)
	}
	if head < acked {
		t.Fatalf("acknowledged %d events, %d after SIGKILL", acked, head)
	}
	n := int64(0)
	_ = s.EventsAfter(context.Background(), "s", 0, 0, func(e Event) error {
		n++
		if e.Seq != n {
			return fmt.Errorf("gap at %d", n)
		}
		return nil
	})
	if n != head {
		t.Fatalf("read %d of %d events", n, head)
	}
	t.Logf("acknowledged %d, present after SIGKILL %d", acked, head)
}

func TestProjectsCreateListAndUniquePath(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	a := Project{ID: "aaaaaaaaaaaa", Name: "A", Path: "/srv/p/a", Created: "2026-11-06T00:00:00.000Z"}
	b := Project{ID: "bbbbbbbbbbbb", Name: "B", Path: "/srv/p/b", DefaultMode: "plan", Created: "2026-11-06T00:00:01.000Z"}
	for _, p := range []Project{a, b} {
		if err := s.CreateProject(ctx, p); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.CreateProject(ctx, Project{ID: "cccccccccccc", Name: "C", Path: a.Path, Created: a.Created}); err != ErrDuplicatePath {
		t.Fatalf("duplicate path: %v", err)
	}
	list, err := s.Projects(ctx)
	if err != nil || len(list) != 2 || !reflect.DeepEqual(list[0], a) || !reflect.DeepEqual(list[1], b) {
		t.Fatalf("list = %+v, %v", list, err)
	}
	if got, _ := s.ProjectByPath(ctx, b.Path); got == nil || !reflect.DeepEqual(*got, b) {
		t.Fatalf("by path = %+v", got)
	}
	if got, _ := s.ProjectByPath(ctx, "/nope"); got != nil {
		t.Fatalf("missing path = %+v", got)
	}
}

func TestSessionsBelongToOneProject(t *testing.T) {
	s, _ := open(t)
	ctx := context.Background()
	for _, id := range []string{"p1", "p2"} {
		if err := s.CreateProject(ctx, Project{ID: id, Name: id, Path: "/srv/" + id, Created: "2026-11-06T00:00:00.000Z"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.RecordSession(ctx, "sess-1", "p1"); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordSession(ctx, "sess-1", "p1"); err != nil {
		t.Fatalf("again for the same project: %v", err)
	}
	if err := s.RecordSession(ctx, "sess-1", "p2"); err != ErrSessionElsewhere {
		t.Fatalf("for another project: %v", err)
	}
	if err := s.RecordSession(ctx, "sess-2", "nope"); err == nil {
		t.Fatal("an unknown project must be refused (foreign key)")
	}
	if id, _ := s.SessionProject(ctx, "sess-1"); id != "p1" {
		t.Fatalf("project = %q", id)
	}
	if id, _ := s.SessionProject(ctx, "sess-x"); id != "" {
		t.Fatalf("unknown session project = %q", id)
	}
	if p, _ := s.ProjectByID(ctx, "p2"); p == nil || p.Path != "/srv/p2" {
		t.Fatalf("by id = %+v", p)
	}
}

// A database made by schema 1 (before turn snapshots, D-036) opens, keeps its data and gains the table.
func TestASchema1DatabaseIsMigratedAndKeepsItsData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "gateway.db")
	s, _ := Open(path)
	ctx := context.Background()
	if _, err := s.AppendEvent(ctx, "sess-1", "update", []byte(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{`DROP TABLE session_mcp`, `DROP TABLE git_credentials`, `DROP TABLE session_usage`, `DROP TABLE push_tokens`, `DROP TABLE snapshots`, `ALTER TABLE projects DROP COLUMN deny_paths`, `ALTER TABLE projects DROP COLUMN watch_skip`, `PRAGMA user_version = 1`} {
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
		t.Fatalf("event after migration: head %d, %v", head, err)
	}
	if err := again.SetStartTree(ctx, "sess-1", 1, "aaaa"); err != nil {
		t.Fatal(err)
	}
	if err := again.SetEndTree(ctx, "sess-1", 1, "bbbb"); err != nil {
		t.Fatal(err)
	}
	if a, b, found, err := again.Snapshot(ctx, "sess-1", 1); err != nil || !found || a != "aaaa" || b != "bbbb" {
		t.Fatalf("snapshot = %q %q %v %v", a, b, found, err)
	}
}
