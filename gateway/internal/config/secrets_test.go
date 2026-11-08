package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

const testSecretValue = "unit-test-value-7f3a"

func writeSecrets(t *testing.T, mode os.FileMode, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "agent.env")
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestParseSecretsReadsNameValueLines(t *testing.T) {
	src := "\n# a comment\n   # indented comment\nBOB_API_KEY=" + testSecretValue + "\r\n\nOTHER_1=a=b=c\n  SPACED  =  x  \n"
	got, err := ParseSecrets([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	want := []Secret{{"BOB_API_KEY", testSecretValue}, {"OTHER_1", "a=b=c"}, {"SPACED", "x"}}
	if len(got) != len(want) {
		t.Fatalf("got %d entries, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("entry %d: got %+v want %+v", i, got[i], want[i])
		}
	}
}

func TestParseSecretsRefusesBadInput(t *testing.T) {
	cases := map[string]string{
		"no equals sign":    "BOB_API_KEY " + testSecretValue,
		"lower case name":   "bob_api_key=x",
		"name with a dash":  "BOB-KEY=x",
		"name starts digit": "1KEY=x",
		"empty value":       "BOB_API_KEY=",
		"blank value":       "BOB_API_KEY=   ",
		"duplicate name":    "BOB_API_KEY=a\nBOB_API_KEY=b",
		"no entries":        "# only a comment\n\n",
		"empty file":        "",
	}
	for name, src := range cases {
		_, err := ParseSecrets([]byte(src))
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if strings.Contains(err.Error(), testSecretValue) {
			t.Errorf("%s: the error holds a value: %v", name, err)
		}
	}
}

func TestReadSecretsFileRefusesGroupOrOtherAccess(t *testing.T) {
	body := "BOB_API_KEY=" + testSecretValue + "\n"
	for _, mode := range []os.FileMode{0o644, 0o640, 0o604, 0o660, 0o777} {
		path := writeSecrets(t, mode, body)
		_, err := ReadSecretsFile(path)
		if err == nil || !strings.Contains(err.Error(), "group or others") {
			t.Errorf("mode %o: got %v", mode, err)
		}
	}
	for _, mode := range []os.FileMode{0o600, 0o400} {
		path := writeSecrets(t, mode, body)
		if _, err := ReadSecretsFile(path); err != nil {
			t.Errorf("mode %o refused: %v", mode, err)
		}
	}
}

func TestReadSecretsFileRefusesRelativeAndMissingPaths(t *testing.T) {
	if _, err := ReadSecretsFile("agent.env"); err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Errorf("relative path: %v", err)
	}
	if _, err := ReadSecretsFile(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Error("missing file accepted")
	}
	if _, err := ReadSecretsFile(t.TempDir()); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Errorf("a folder: %v", err)
	}
}

// minimalConfig is a valid host-runner config with the given agent block fields.
func minimalConfig(t *testing.T, agent map[string]any) string {
	t.Helper()
	sum := strings.Repeat("0", 64)
	agent["command"] = []string{"bob", "acp"}
	cfg := map[string]any{
		"listen":   map[string]any{"host": "127.0.0.1", "port": 0},
		"tokens":   []any{map[string]any{"id": "phone", "identity": "owner", "sha256": sum}},
		"agent":    agent,
		"projects": map[string]any{"roots": []string{"/srv/projects"}},
		"stateDir": "/var/lib/acpcode",
		"runner":   map[string]any{"kind": "host", "allowHost": true},
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func validateJSON(t *testing.T, src string) (*Config, error) {
	t.Helper()
	v, err := jsonv.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	return Validate(v)
}

func TestValidateSecretsFileSortsNamesByPassthrough(t *testing.T) {
	path := writeSecrets(t, 0o600, "BOB_API_KEY="+testSecretValue+"\nNOT_LISTED=zzz\n")
	cfg, err := validateJSON(t, minimalConfig(t, map[string]any{
		"envPassthrough": []string{"PATH", "BOB_API_KEY"},
		"secretsFile":    path,
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.SecretsFile != path {
		t.Errorf("SecretsFile = %q", cfg.SecretsFile)
	}
	if len(cfg.SecretNames) != 1 || cfg.SecretNames[0] != "BOB_API_KEY" {
		t.Errorf("SecretNames = %v", cfg.SecretNames)
	}
	if len(cfg.SecretsIgnored) != 1 || cfg.SecretsIgnored[0] != "NOT_LISTED" {
		t.Errorf("SecretsIgnored = %v (names only, never values)", cfg.SecretsIgnored)
	}
}

func TestValidateSecretsFileErrors(t *testing.T) {
	bad := writeSecrets(t, 0o644, "BOB_API_KEY="+testSecretValue+"\n")
	cases := map[string]struct {
		path string
		want string
	}{
		"relative path": {"agent.env", "must be an absolute path"},
		"bad mode":      {bad, "group or others"},
		"missing file":  {filepath.Join(t.TempDir(), "nope"), "cannot read the secrets file"},
		"HOME in file":  {writeSecrets(t, 0o600, "HOME=/evil\n"), "must not set HOME"},
		"PATH in file":  {writeSecrets(t, 0o600, "PATH=/evil\n"), "must not set PATH"},
		"empty file":    {writeSecrets(t, 0o600, "# nothing\n"), "no NAME=value entries"},
	}
	for name, c := range cases {
		_, err := validateJSON(t, minimalConfig(t, map[string]any{
			"envPassthrough": []string{"PATH", "BOB_API_KEY", "HOME"},
			"secretsFile":    c.path,
		}))
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %q does not contain %q", name, err.Error(), c.want)
		}
		if strings.Contains(err.Error(), testSecretValue) {
			t.Errorf("%s: the config error holds a value", name)
		}
	}
	// The key is optional, and absent means no secrets.
	cfg, err := validateJSON(t, minimalConfig(t, map[string]any{"envPassthrough": []string{"PATH"}}))
	if err != nil || cfg.SecretsFile != "" || len(cfg.SecretNames) != 0 {
		t.Errorf("absent key: %v %+v", err, cfg)
	}
}
