package server

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestValidateWatchSkipAllowsPlainPathsOnly(t *testing.T) {
	good, err := validateWatchSkip([]string{"cache", "out/tmp", "Big Folder", "cache"})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"cache", "out/tmp", "Big Folder"}; !reflect.DeepEqual(good, want) {
		t.Fatalf("got %v", good)
	}
	for name, in := range map[string][]string{
		"glob star":   {"*.db"},
		"double star": {"**/x"},
		"absolute":    {"/etc"},
		"dot dot":     {"../x"},
		"trailing /":  {"a/"},
		"negation":    {"!cache"},
		"class":       {"[a]"},
		"backslash":   {`a\b`},
		"non ascii":   {"café"},
		"too long":    {strings.Repeat("a", maxDenyPathLen+1)},
		"too many":    make([]string, maxDenyPaths+1),
	} {
		if _, err := validateWatchSkip(in); err == nil {
			t.Errorf("%s: %q was accepted", name, in)
		} else if !strings.Contains(err.Error(), "watchSkip") && !strings.Contains(err.Error(), "entries") {
			t.Errorf("%s: the error does not name the list: %v", name, err)
		}
	}
}

func TestMergeEntriesAddsCaseInsensitivelyAndCapsTheTotal(t *testing.T) {
	got, err := mergeEntries("denyPaths", []string{"*.db"}, []string{"*.DB", "config/prod.yml"})
	if err != nil || !reflect.DeepEqual(got, []string{"*.db", "config/prod.yml"}) {
		t.Fatalf("merge = %v, %v", got, err)
	}
	full := make([]string, maxDenyPaths)
	for i := range full {
		full[i] = "f" + strings.Repeat("a", i)
	}
	if _, err := mergeEntries("denyPaths", full, []string{"new"}); err == nil {
		t.Fatal("33 entries in total must be refused")
	}
	if got, err := mergeEntries("denyPaths", full, []string{full[0]}); err != nil || len(got) != maxDenyPaths {
		t.Fatalf("a duplicate at the cap must pass: %d, %v", len(got), err)
	}
	if got, err := mergeEntries("denyPaths", []string{"a"}, nil); err != nil || !reflect.DeepEqual(got, []string{"a"}) {
		t.Fatalf("an empty add changes nothing: %v, %v", got, err)
	}
}

// The watcher leaves out the built-in names, a project's bare names at any depth, and its anchored
// paths from the root only (D-065).
func TestFingerprintSkipsTheProjectsWatchSkip(t *testing.T) {
	root := t.TempDir()
	write := func(rel string) {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, rel)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, rel), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.txt")
	base := fingerprint(root, newWatchSkipper(nil))
	for _, rel := range []string{"cache/x", "deep/cache/y", "out/tmp/z", "node_modules/p/i.js"} {
		write(rel)
	}
	skip := newWatchSkipper([]string{"cache", "out/tmp"})
	if got := fingerprint(root, skip); got != base {
		t.Fatal("skipped folders changed the fingerprint")
	}
	write("other/out/tmp/w") // the anchored entry does not match below another folder
	if got := fingerprint(root, skip); got == base {
		t.Fatal("a folder that is not skipped must change the fingerprint")
	}
	if fingerprint(root, newWatchSkipper(nil)) == base {
		t.Fatal("without the project list, cache must count")
	}
}
