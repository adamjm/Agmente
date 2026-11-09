package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

// scopeConfig is a valid config with one token entry (its extra fields and its roots as given).
func scopeConfig(t *testing.T, tokenExtra, roots, stateDir string) (*Config, error) {
	t.Helper()
	raw := fmt.Sprintf(`{
		"listen": {"host": "127.0.0.1", "port": 0},
		"tokens": [{"id": "phone", "identity": "owner", "sha256": %q%s}],
		"agent": {"command": ["/bin/false"]},
		"projects": {"roots": [%s]},
		"stateDir": %q,
		"runner": {"kind": "host", "allowHost": true}
	}`, strings.Repeat("a", 64), tokenExtra, roots, stateDir)
	v, err := jsonv.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	return Validate(v)
}

// homeIn points $HOME at a fresh folder under a test temp dir, and returns its real path.
func homeIn(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(dir, "home")
	if err := os.Mkdir(home, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	return home
}

func TestTokenScopeDefaultsToFull(t *testing.T) {
	home := homeIn(t)
	cfg, err := scopeConfig(t, "", `"`+filepath.Join(home, "acpcode")+`"`, filepath.Join(home, "state"))
	if err != nil {
		t.Fatalf("a token with no scope is refused: %v", err)
	}
	if cfg.Tokens[0].Scope != ScopeFull {
		t.Fatalf("scope = %q, want full (existing tokens keep working)", cfg.Tokens[0].Scope)
	}
}

func TestTokenScopeAcceptsEachKnownValue(t *testing.T) {
	home := homeIn(t)
	for _, scope := range TokenScopes {
		cfg, err := scopeConfig(t, fmt.Sprintf(`, "scope": %q`, scope), `"`+filepath.Join(home, "acpcode")+`"`, filepath.Join(home, "state"))
		if err != nil {
			t.Fatalf("scope %q refused: %v", scope, err)
		}
		if cfg.Tokens[0].Scope != scope {
			t.Fatalf("scope = %q, want %q", cfg.Tokens[0].Scope, scope)
		}
	}
}

func TestTokenScopeRejectsUnknownValue(t *testing.T) {
	home := homeIn(t)
	for _, scope := range []string{`"admin"`, `"Full"`, `""`, `7`, `["full"]`} {
		_, err := scopeConfig(t, `, "scope": `+scope, `"`+filepath.Join(home, "acpcode")+`"`, filepath.Join(home, "state"))
		if err == nil || !strings.Contains(err.Error(), "tokens[0].scope must be") {
			t.Fatalf("scope %s: err = %v, want the scope rule", scope, err)
		}
	}
}

func TestProjectRootAtHomeIsRefused(t *testing.T) {
	home := homeIn(t)
	_, err := scopeConfig(t, "", `"`+home+`"`, filepath.Join(home, "state"))
	if err == nil || !strings.Contains(err.Error(), "Rule: no project root at or above $HOME") {
		t.Fatalf("a root at $HOME: err = %v, want the rule named", err)
	}
	_, err = scopeConfig(t, "", `"`+filepath.Dir(home)+`"`, filepath.Join(home, "state"))
	if err == nil || !strings.Contains(err.Error(), "Rule: no project root at or above $HOME") {
		t.Fatalf("a root above $HOME: err = %v, want the rule named", err)
	}
}

func TestProjectRootUnderHomeIsAllowed(t *testing.T) {
	home := homeIn(t)
	cfg, err := scopeConfig(t, "", `"`+filepath.Join(home, "acpcode", "projects")+`"`, filepath.Join(home, "state"))
	if err != nil {
		t.Fatalf("a root under $HOME was refused: %v", err)
	}
	if len(cfg.Roots) != 1 {
		t.Fatalf("roots = %v", cfg.Roots)
	}
}

func TestAtOrAboveHome(t *testing.T) {
	cases := map[string]bool{
		"/":                 true,
		"/Users":            true,
		"/Users/me":         true,
		"/Users/me/":        true,
		"/Users/me/work":    false,
		"/Users/mexico":     false,
		"/Users/me/../me/x": false,
	}
	for path, want := range cases {
		if got := AtOrAboveHome(path, "/Users/me"); got != want {
			t.Fatalf("AtOrAboveHome(%q) = %v, want %v", path, got, want)
		}
	}
}
