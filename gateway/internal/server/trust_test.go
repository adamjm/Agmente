package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readTrust(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("trust file is not JSON: %v", err)
	}
	return doc
}

func TestPrepareHomeTrustsTheProjectPath(t *testing.T) {
	home := filepath.Join(t.TempDir(), "homes", "0123456789ab")
	if err := prepareHome(home, "/srv/projects/p"); err != nil {
		t.Fatal(err)
	}
	trust := filepath.Join(home, ".bob", "trustedFolders.json")
	doc := readTrust(t, trust)
	folders, _ := doc["folders"].(map[string]any)
	if len(doc) != 2 || doc["version"] != float64(1) || len(folders) != 1 || folders["/srv/projects/p"] != "TRUST_FOLDER" {
		t.Fatalf("trust file: %v", doc)
	}
	assertMode(t, trust, 0o600)
	assertMode(t, filepath.Join(home, ".bob"), 0o700)
	assertMode(t, home, 0o700)
	entries, err := os.ReadDir(filepath.Join(home, ".bob"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("a temporary file was left behind: %v", names)
	}
}

func TestTrustFileKeepsOtherEntriesAndKeys(t *testing.T) {
	home := t.TempDir()
	bob := filepath.Join(home, ".bob")
	if err := os.MkdirAll(bob, 0o700); err != nil {
		t.Fatal(err)
	}
	trust := filepath.Join(bob, "trustedFolders.json")
	existing := `{"version":1,"extra":{"kept":true},"folders":{"/other/one":"TRUST_FOLDER","/deny/me":"DONT_TRUST"}}`
	if err := os.WriteFile(trust, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := addTrustEntry(trust, "/srv/projects/p"); err != nil {
		t.Fatal(err)
	}
	doc := readTrust(t, trust)
	folders := doc["folders"].(map[string]any)
	want := map[string]any{"/other/one": "TRUST_FOLDER", "/deny/me": "DONT_TRUST", "/srv/projects/p": "TRUST_FOLDER"}
	if len(folders) != len(want) {
		t.Fatalf("folders: %v", folders)
	}
	for k, v := range want {
		if folders[k] != v {
			t.Errorf("folders[%s] = %v, want %v", k, folders[k], v)
		}
	}
	if extra, _ := doc["extra"].(map[string]any); extra["kept"] != true {
		t.Errorf("an unrelated key was lost: %v", doc)
	}
	assertMode(t, trust, 0o600)
}

func TestTrustFileRefusesAShapeItCannotKeep(t *testing.T) {
	for name, body := range map[string]string{
		"array":          `[1,2]`,
		"not JSON":       `{"folders":`,
		"folders array":  `{"version":1,"folders":[1]}`,
		"folders string": `{"folders":"x"}`,
	} {
		trust := filepath.Join(t.TempDir(), "trustedFolders.json")
		if err := os.WriteFile(trust, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		err := addTrustEntry(trust, "/srv/p")
		if err == nil {
			t.Errorf("%s: accepted", name)
		}
		got, _ := os.ReadFile(trust)
		if string(got) != body {
			t.Errorf("%s: the file was rewritten: %s", name, got)
		}
		if err != nil && strings.Contains(err.Error(), "/srv/p") {
			t.Errorf("%s: error text names the folder: %v", name, err)
		}
	}
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Errorf("%s mode %o, want %o", path, got, want)
	}
}
