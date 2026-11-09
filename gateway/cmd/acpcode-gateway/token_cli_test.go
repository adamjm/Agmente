package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/server"
)

// new-token takes --scope full|intent|connector, full by default, and writes the scope into the entry.
func TestNewTokenWritesScopeIntoEntry(t *testing.T) {
	for _, tc := range []struct{ args, scope string }{
		{"shortcut owner --scope intent", "intent"},
		{"--scope=connector shortcut owner", "connector"},
		{"phone owner", "full"},
	} {
		var out, errOut bytes.Buffer
		if code := newToken(strings.Fields(tc.args), &out, &errOut); code != 0 {
			t.Fatalf("%q: exit %d: %s", tc.args, code, errOut.String())
		}
		line := strings.TrimPrefix(strings.SplitN(out.String(), "\n", 3)[1], "config entry: ")
		var entry struct {
			Scope  string `json:"scope"`
			SHA256 string `json:"sha256"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("%q: entry %q: %v", tc.args, line, err)
		}
		if entry.Scope != tc.scope {
			t.Fatalf("%q: scope %q, want %q", tc.args, entry.Scope, tc.scope)
		}
		if len(entry.SHA256) != 64 {
			t.Fatalf("%q: entry holds no hash", tc.args)
		}
	}
	var out, errOut bytes.Buffer
	if code := newToken([]string{"phone", "owner", "--scope", "admin"}, &out, &errOut); code != 2 || out.Len() != 0 {
		t.Fatalf("an unknown scope: exit %d, stdout %q; want exit 2 and no token", code, out.String())
	}
}

// revoke-token adds the id to the list in the state directory, and refuses an id the config does not hold.
func TestRevokeTokenWritesListAndRefusesUnknownID(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	cfgPath := filepath.Join(dir, "config.json")
	cfg := `{
		"listen": {"host": "127.0.0.1", "port": 8787},
		"tokens": [{"id": "phone", "identity": "owner", "sha256": "` + strings.Repeat("a", 64) + `"}],
		"agent": {"command": ["/bin/false"]},
		"projects": {"roots": ["` + filepath.Join(dir, "root") + `"]},
		"stateDir": "` + state + `",
		"runner": {"kind": "host", "allowHost": true}
	}`
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	var out, errOut bytes.Buffer
	if code := revokeTokenCommand(cfgPath, []string{"nobody"}, &out, &errOut); code == 0 {
		t.Fatal("an id the config does not hold was revoked")
	}
	if _, err := os.Stat(server.RevokedPath(state)); err == nil {
		t.Fatal("a refused revoke wrote the list")
	}
	if code := revokeTokenCommand(cfgPath, []string{"phone"}, &out, &errOut); code != 0 {
		t.Fatalf("revoke exit %d: %s", code, errOut.String())
	}
	ids, err := server.ReadRevokedTokens(state)
	if err != nil || len(ids) != 1 || ids[0] != "phone" {
		t.Fatalf("list = %v (%v), want [phone]", ids, err)
	}
	// Revoking again is harmless: the id is listed once.
	if code := revokeTokenCommand(cfgPath, []string{"phone"}, &out, &errOut); code != 0 {
		t.Fatalf("second revoke exit %d", code)
	}
	if ids, _ := server.ReadRevokedTokens(state); len(ids) != 1 {
		t.Fatalf("list after a second revoke = %v", ids)
	}
}
