package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/config"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *syncBuffer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

func (w *syncBuffer) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.String()
}

// D-033: a panic while handling one phone message answers that request with -32603, closes that
// socket with 1011, and leaves the gateway serving other sockets.
func TestPanicInAMessageAnswersAndClosesOnlyThatSocket(t *testing.T) {
	dir := t.TempDir()
	token := "panic-test-token-abcdefgh"
	sum := sha256.Sum256([]byte(token))
	raw, _ := json.Marshal(map[string]any{
		"listen":   map[string]any{"host": "127.0.0.1", "port": 0},
		"tokens":   []any{map[string]any{"id": "phone", "identity": "owner", "sha256": hex.EncodeToString(sum[:])}},
		"agent":    map[string]any{"command": []string{"/bin/false"}},
		"projects": map[string]any{"roots": []string{dir}},
		"stateDir": filepath.Join(dir, "state"),
		"runner":   map[string]any{"kind": "host", "allowHost": true},
	})
	v, err := jsonv.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Validate(v)
	if err != nil {
		t.Fatal(err)
	}
	db, err := store.Open(filepath.Join(dir, "gateway.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	logs := &syncBuffer{}
	srv := New(cfg, audit.New(logs), db)
	ln, err := srv.Listen()
	if err != nil {
		t.Fatal(err)
	}
	go srv.Serve(ln)
	defer srv.Shutdown()

	panicHook = func(method string) {
		if method == "_test/boom" {
			panic("boom")
		}
	}
	defer func() { panicHook = nil }()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dial := func() *websocket.Conn {
		ws, _, err := websocket.Dial(ctx, "ws://"+ln.Addr().String()+"/", &websocket.DialOptions{
			HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return ws
	}
	a, b := dial(), dial()
	defer b.CloseNow()

	if err := a.Write(ctx, websocket.MessageText, []byte(`{"jsonrpc":"2.0","id":7,"method":"_test/boom","params":{"secret":"do-not-log"}}`)); err != nil {
		t.Fatal(err)
	}
	_, got, err := a.Read(ctx)
	if err != nil {
		t.Fatalf("no answer before the close: %v", err)
	}
	if want := `{"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"internal error"}}`; string(got) != want {
		t.Fatalf("answer: got %s, want %s", got, want)
	}
	if _, _, err := a.Read(ctx); websocket.CloseStatus(err) != closeInternalError {
		t.Fatalf("close: got %v, want 1011", err)
	}

	// The gateway still serves the other socket.
	if err := b.Write(ctx, websocket.MessageText, []byte(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	_, got, err = b.Read(ctx)
	if err != nil || !strings.Contains(string(got), `"id":1,"result"`) {
		t.Fatalf("other socket: %s %v", got, err)
	}

	out := logs.String()
	if !strings.Contains(out, `"event":"panic"`) || !strings.Contains(out, `"method":"_test/boom"`) {
		t.Fatalf("no panic audit line: %s", out)
	}
	if strings.Contains(out, "do-not-log") {
		t.Fatal("message content reached the audit log")
	}
}
