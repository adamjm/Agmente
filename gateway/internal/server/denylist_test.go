package server

import (
	"reflect"
	"slices"
	"strings"
	"testing"
)

func TestValidateDenyPaths(t *testing.T) {
	good, err := validateDenyPaths([]string{"*.db", "config/prod.yml", "Private Notes", "*.DB", "vault/*"})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"*.db", "config/prod.yml", "Private Notes", "vault/*"}; !reflect.DeepEqual(good, want) { // "*.DB" is a duplicate
		t.Fatalf("got %v", good)
	}
	bad := map[string][]string{
		"absolute":       {"/etc/passwd"},
		"dot dot":        {"../x"},
		"dot dot inside": {"a/../b"},
		"dot":            {"./a"},
		"empty":          {""},
		"trailing slash": {"a/"},
		"empty part":     {"a//b"},
		"double star":    {"**/x"},
		"negation":       {"!.env"},
		"class":          {"[a]"},
		"question":       {"a?"},
		"backslash":      {`a\b`},
		"colon":          {":(top)x"},
		"newline":        {"a\nb"},
		"non ascii":      {"café"},
		"edge space":     {" a"},
		"too long":       {strings.Repeat("a", maxDenyPathLen+1)},
	}
	many := make([]string, maxDenyPaths+1)
	for i := range many {
		many[i] = "f" + strings.Repeat("a", i)
	}
	bad["too many"] = many
	for name, in := range bad {
		if _, err := validateDenyPaths(in); err == nil {
			t.Errorf("%s: %q was accepted", name, in)
		}
	}
	if _, err := validateDenyPaths(many[:maxDenyPaths]); err != nil {
		t.Errorf("exactly the maximum count must pass: %v", err)
	}
	if _, err := validateDenyPaths([]string{strings.Repeat("a", maxDenyPathLen)}); err != nil {
		t.Errorf("exactly the maximum length must pass: %v", err)
	}
}

func TestIsSecretForAddsToTheBuiltInsAndNeverRemovesThem(t *testing.T) {
	extra := []string{"*.db", "config/prod.yml", "vault/*", "Ledger"}
	for path, want := range map[string]bool{
		"data.db": true, "sub/dir/Data.DB": true, "config/prod.yml": true, "CONFIG/Prod.yml": true,
		"other/config/prod.yml": false, "config/dev.yml": false, "vault/a": true, "vault/a/b/c": true,
		"vault": false, "a/ledger/x": true, "notes.txt": false,
		// built-ins still apply with additions present
		".env": true, "a/b/.env.local": true, "k.pem": true, "my-Secret.txt": true, "id_rsa.pub": true,
	} {
		if got := isSecretFor(extra, path); got != want {
			t.Errorf("%q: got %v, want %v", path, got, want)
		}
	}
	// With no additions it is the built-in list exactly.
	for _, path := range []string{".env", "x/secrets/y", "a.txt", "data.db"} {
		if isSecretFor(nil, path) != isSecretPath(path) {
			t.Errorf("%q differs from the built-in list", path)
		}
	}
	// Whatever a project lists, every built-in pattern stays in the git excludes.
	ex := secretExcludesFor([]string{".env", "x"})
	have := map[string]bool{}
	for _, e := range ex {
		have[e] = true
	}
	for _, pat := range secretPatterns {
		if !have[":(exclude,glob,icase)**/"+pat] {
			t.Errorf("built-in %q is missing from the excludes", pat)
		}
	}
	if !have[":(exclude,glob,icase)**/x"] || !have[":(exclude,glob,icase)**/x/**"] {
		t.Error("a project entry is missing from the excludes")
	}
	anchored := secretExcludesFor([]string{"config/prod.yml"})
	if !slices.Contains(anchored, ":(exclude,glob,icase)config/prod.yml") {
		t.Error("an entry with a slash must be anchored at the project root")
	}
}
