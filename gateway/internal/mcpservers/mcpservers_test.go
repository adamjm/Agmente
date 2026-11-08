package mcpservers

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const secretHeader = "SECRET-HEADER-7731"

func httpInput(name string) Input {
	return Input{Name: name, Transport: "http", URL: "https://mcp.example.test/mcp", Headers: []Pair{{Name: "X-Api-Key", Value: secretHeader}}, DefaultEnabled: true}
}

func stdioInput(name string) Input {
	return Input{Name: name, Transport: "stdio", Command: "/opt/acp/SECRET-CMD-4410", Args: []string{"--token", "SECRET-ARG-5520"}, Env: []Pair{{Name: "API_KEY", Value: "SECRET-ENV-6631"}}}
}

// The list a phone gets never holds a secret, a command or a header name (D-107, NFR-14).
func TestListHoldsNoSecretAndNoCommand(t *testing.T) {
	lib := Open(t.TempDir())
	if _, err := lib.Put(httpInput("docs")); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.Put(stdioInput("local")); err != nil {
		t.Fatal(err)
	}
	listed, err := lib.List()
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(listed)
	for _, banned := range []string{"SECRET-", "/opt/acp", "X-Api-Key", "headers", "command", "args", "env"} {
		if strings.Contains(string(data), banned) {
			t.Fatalf("the list holds %q: %s", banned, data)
		}
	}
	if len(listed) != 2 || listed[0].Name != "docs" || listed[1].Transport != "stdio" {
		t.Fatalf("list = %+v", listed)
	}
}

// URLs with a query or credentials are shown as scheme and host only.
func TestRedactURLKeepsOnlyTheHostWhenThereIsAQueryOrCredentials(t *testing.T) {
	cases := map[string]string{
		"https://mcp.example.test/mcp":              "https://mcp.example.test/mcp",
		"https://mcp.example.test/mcp?token=SECRET": "https://mcp.example.test",
		"https://user:SECRET@mcp.example.test/mcp":  "https://mcp.example.test",
		"https://mcp.example.test/mcp#SECRET":       "https://mcp.example.test",
		"http://127.0.0.1:8941/mcp":                 "http://127.0.0.1:8941/mcp",
	}
	for raw, want := range cases {
		if got := redactURL(raw); got != want {
			t.Errorf("redactURL(%q) = %q, want %q", raw, got, want)
		}
	}
}

// The put refuses what the list must not hold: credentials or a query in a URL, a plain http URL to
// a remote host, a header with a line break, a stdio entry with a URL, a duplicate name.
func TestPutRefusesBadEntriesAndNamesTheField(t *testing.T) {
	lib := Open(t.TempDir())
	bad := map[string]Input{
		"userinfo": {Name: "a", Transport: "http", URL: "https://u:p@mcp.example.test/mcp"},
		"query":    {Name: "b", Transport: "http", URL: "https://mcp.example.test/mcp?k=v"},
		"plain":    {Name: "c", Transport: "http", URL: "http://mcp.example.test/mcp"},
		"crlf":     {Name: "d", Transport: "http", URL: "https://mcp.example.test/mcp", Headers: []Pair{{Name: "X", Value: "a\r\nb"}}},
		"mixed":    {Name: "e", Transport: "stdio", Command: "/bin/x", URL: "https://mcp.example.test/mcp"},
		"name":     {Name: " padded", Transport: "http", URL: "https://mcp.example.test/mcp"},
		"kind":     {Name: "f", Transport: "sse", URL: "https://mcp.example.test/mcp"},
		"command":  {Name: "g", Transport: "stdio", Command: ""},
	}
	for label, in := range bad {
		if _, err := lib.Put(in); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: err = %v, want ErrInvalid", label, err)
		}
	}
	if _, err := lib.Put(httpInput("docs")); err != nil {
		t.Fatal(err)
	}
	if _, err := lib.Put(httpInput("docs")); !errors.Is(err, ErrInvalid) {
		t.Fatalf("a duplicate name: %v", err)
	}
	if _, err := lib.Put(Input{Name: "loop", Transport: "http", URL: "http://localhost:9/mcp"}); err != nil {
		t.Fatalf("loopback http is allowed: %v", err)
	}
}

// Resolve gives back the entries asked for, with their secrets, and reports a removed id as missing.
func TestResolveReportsRemovedIDsAndKeepsOrder(t *testing.T) {
	lib := Open(t.TempDir())
	a, _ := lib.Put(httpInput("docs"))
	b, _ := lib.Put(stdioInput("local"))
	found, missing, err := lib.Resolve([]string{b.ID, "00000000000000000000000000000000", a.ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 2 || found[0].Entry.ID != b.ID || found[1].Entry.ID != a.ID {
		t.Fatalf("found = %+v", found)
	}
	if len(missing) != 1 || missing[0] != "00000000000000000000000000000000" {
		t.Fatalf("missing = %v", missing)
	}
	if found[1].Secrets.Headers[0].Value != secretHeader {
		t.Fatal("the secret is not resolved for the agent")
	}
}

// Delete removes the entry and its secrets, and the other entry is untouched.
func TestDeleteRemovesTheEntryAndItsSecrets(t *testing.T) {
	dir := t.TempDir()
	lib := Open(dir)
	a, _ := lib.Put(httpInput("docs"))
	b, _ := lib.Put(stdioInput("local"))
	if ok, err := lib.Delete(a.ID); err != nil || !ok {
		t.Fatalf("delete = %v, %v", ok, err)
	}
	if ok, _ := lib.Delete(a.ID); ok {
		t.Fatal("a second delete found the entry")
	}
	raw, _ := os.ReadFile(filepath.Join(dir, secretsFile))
	if strings.Contains(string(raw), secretHeader) || strings.Contains(string(raw), a.ID) {
		t.Fatal("the removed entry's secret is still on disk")
	}
	found, missing, _ := lib.Resolve([]string{a.ID, b.ID})
	if len(found) != 1 || found[0].Entry.ID != b.ID || len(missing) != 1 {
		t.Fatalf("after delete: found %d, missing %v", len(found), missing)
	}
}

// Both files are mode 0600, the secrets are in their own file, and a new Library reads what an
// earlier one wrote (no state in memory).
func TestFilesAreOwnerOnlyAndSecretsAreSeparate(t *testing.T) {
	dir := t.TempDir()
	if _, err := Open(dir).Put(httpInput("docs")); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{listFile, secretsFile} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %v", name, info.Mode().Perm())
		}
	}
	list, _ := os.ReadFile(filepath.Join(dir, listFile))
	if strings.Contains(string(list), secretHeader) {
		t.Fatal("the list file holds a secret")
	}
	entries, err := Open(dir).Entries()
	if err != nil || len(entries) != 1 || !entries[0].DefaultEnabled {
		t.Fatalf("a new reader sees %+v, %v", entries, err)
	}
}

func TestListHasAtMostMaxEntries(t *testing.T) {
	lib := Open(t.TempDir())
	for i := 0; i < MaxEntries; i++ {
		if _, err := lib.Put(Input{Name: "s" + strings.Repeat("x", i%3) + string(rune('a'+i%26)) + string(rune('a'+i/26)), Transport: "http", URL: "https://mcp.example.test/mcp"}); err != nil {
			t.Fatalf("entry %d: %v", i, err)
		}
	}
	if _, err := lib.Put(Input{Name: "one-more", Transport: "http", URL: "https://mcp.example.test/mcp"}); !errors.Is(err, ErrInvalid) {
		t.Fatalf("entry %d: %v", MaxEntries+1, err)
	}
}
