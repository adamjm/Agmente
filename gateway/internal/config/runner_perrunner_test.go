package config

import (
	"strings"
	"testing"
)

// Per-runner secrets files and srt lists (D-126).

const hostRunnerBlock = `"runner": {"kind": "host", "allowHost": true},`

func perRunnerSecrets(path, env string) string {
	return hostRunnerBlock + `"runners": {
	  "bob": {"command": ["bob", "acp"], "envPassthrough": ["PATH"]},
	  "claude": {"command": ["claude-agent-acp"], "envPassthrough": [` + env + `], "secretsFile": "` + path + `"}
	}, "defaultRunner": "bob"`
}

func TestRunnerSecretsFileIsReadPerRunner(t *testing.T) {
	path := writeSecrets(t, 0o600, "ANTHROPIC_AUTH_TOKEN="+testSecretValue+"\nANTHROPIC_MODEL=m\nNOT_LISTED=zzz\n")
	cfg, err := runnersConfig(t, perRunnerSecrets(path, `"PATH", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"`), "")
	if err != nil {
		t.Fatalf("valid runner secrets file refused: %v", err)
	}
	claude, _ := cfg.Agent("claude")
	if claude.SecretsFile != path || strings.Join(claude.SecretNames, ",") != "ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL" {
		t.Fatalf("claude secrets = %q %v", claude.SecretsFile, claude.SecretNames)
	}
	if strings.Join(claude.SecretsIgnored, ",") != "NOT_LISTED" {
		t.Fatalf("ignored = %v, want the unlisted name only", claude.SecretsIgnored)
	}
	bob, _ := cfg.Agent("bob")
	if bob.SecretsFile != "" || len(bob.SecretNames) != 0 {
		t.Fatalf("bob must not get the claude secrets: %+v", bob)
	}
	if cfg.SecretsFile != "" {
		t.Fatalf("Config.SecretsFile is for the single-agent form only: %q", cfg.SecretsFile)
	}
}

func TestRunnerSecretsFileRefusals(t *testing.T) {
	body := "ANTHROPIC_AUTH_TOKEN=" + testSecretValue + "\n"
	cases := []struct{ name, path, want string }{
		{"group readable", writeSecrets(t, 0o640, body), "runners.claude.secretsFile: the secrets file must not be readable or writable by group or others"},
		{"sets HOME", writeSecrets(t, 0o600, "HOME=/evil\n"), "runners.claude.secretsFile must not set HOME"},
		{"sets PATH", writeSecrets(t, 0o600, "PATH=/evil\n"), "runners.claude.secretsFile must not set PATH"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := runnersConfig(t, perRunnerSecrets(c.path, `"PATH", "HOME", "ANTHROPIC_AUTH_TOKEN"`), "")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error = %v, want %q", err, c.want)
			}
			if strings.Contains(err.Error(), testSecretValue) {
				t.Fatal("the error holds a secret value")
			}
		})
	}
}

func TestSingleAgentFormFillsTheDefaultRunnerSecrets(t *testing.T) {
	path := writeSecrets(t, 0o600, "BOB_API_KEY="+testSecretValue+"\nNOT_LISTED=zzz\n")
	cfg, err := validateJSON(t, minimalConfig(t, map[string]any{
		"envPassthrough": []string{"PATH", "BOB_API_KEY"},
		"secretsFile":    path,
	}))
	if err != nil {
		t.Fatal(err)
	}
	def, _ := cfg.Agent("")
	if def.SecretsFile != path || strings.Join(def.SecretNames, ",") != "BOB_API_KEY" || strings.Join(def.SecretsIgnored, ",") != "NOT_LISTED" {
		t.Fatalf("default runner secrets = %+v", def)
	}
	if cfg.SecretsFile != path || len(cfg.SecretNames) != 1 {
		t.Fatalf("Config secrets must stay set: %q %v", cfg.SecretsFile, cfg.SecretNames)
	}
}

const srtShared = `"runner": {"kind": "srt", "srt": "/opt/homebrew/bin/srt", "allowedDomains": ["shared.example.com"], "allowRead": ["/opt/shared"]},`

func TestRunnerOwnSRTListsWinAndOthersFallBack(t *testing.T) {
	cfg, err := runnersConfig(t, srtShared+`"runners": {
	  "bob": {"command": ["bob", "acp"]},
	  "claude": {"command": ["claude-agent-acp"], "allowedDomains": ["api.claude.example.com", "api.claude.example.com", "*.x.example.com:443"], "allowRead": ["/opt/homebrew", "/usr/local/"]}
	}, "defaultRunner": "bob"`, "")
	if err != nil {
		t.Fatalf("valid per-runner srt lists refused: %v", err)
	}
	bob, _ := cfg.Agent("bob")
	if strings.Join(bob.AllowedDomains, " ") != "shared.example.com" || strings.Join(bob.AllowRead, " ") != "/opt/shared" {
		t.Fatalf("bob must take the shared lists: %+v", bob)
	}
	claude, _ := cfg.Agent("claude")
	if strings.Join(claude.AllowedDomains, " ") != "api.claude.example.com *.x.example.com:443" {
		t.Fatalf("claude domains = %v: its own list, duplicate dropped", claude.AllowedDomains)
	}
	if strings.Join(claude.AllowRead, " ") != "/opt/homebrew /usr/local" {
		t.Fatalf("claude allowRead = %v", claude.AllowRead)
	}
	// The shared lists must not be altered by a runner's own.
	if strings.Join(cfg.Runner.AllowedDomains, " ") != "shared.example.com" {
		t.Fatalf("shared domains = %v", cfg.Runner.AllowedDomains)
	}
}

func TestRunnerOwnDomainsNeedNoSharedList(t *testing.T) {
	cfg, err := runnersConfig(t, `"runner": {"kind": "srt", "srt": "/opt/homebrew/bin/srt"},
	  "runners": {
	    "bob": {"command": ["bob", "acp"], "allowedDomains": ["bob.example.com"]},
	    "claude": {"command": ["claude-agent-acp"], "allowedDomains": ["claude.example.com"]}
	  }, "defaultRunner": "bob"`, "")
	if err != nil {
		t.Fatalf("every runner has its own domains: %v", err)
	}
	if bob, _ := cfg.Agent("bob"); strings.Join(bob.AllowedDomains, " ") != "bob.example.com" || len(bob.AllowRead) != 0 {
		t.Fatalf("bob = %+v", bob)
	}
}

func TestRunnerSRTListsRefusals(t *testing.T) {
	cases := []struct{ name, members, want string }{
		{"one runner has none and no shared list",
			`"runner": {"kind": "srt", "srt": "/opt/homebrew/bin/srt"},
			 "runners": {"bob": {"command": ["bob", "acp"], "allowedDomains": ["bob.example.com"]}, "claude": {"command": ["c"]}}, "defaultRunner": "bob"`,
			"runner.allowedDomains must list"},
		{"empty own list",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowedDomains": []}}`,
			"runners.bob.allowedDomains must list"},
		{"invalid own domain",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowedDomains": ["Bad.example.com"]}}`,
			"runners.bob.allowedDomains[0]"},
		{"ip literal",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowedDomains": ["10.0.0.1"]}}`,
			"runners.bob.allowedDomains[0]"},
		{"bare star",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowedDomains": ["*"]}}`,
			"runners.bob.allowedDomains[0]"},
		{"relative allowRead",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowRead": ["lib"]}}`,
			"runners.bob.allowRead[0]"},
		{"root allowRead",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowRead": ["/"]}}`,
			"runners.bob.allowRead[0]"},
		{"glob allowRead",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowRead": ["/opt/*"]}}`,
			"runners.bob.allowRead[0]"},
		{"allowRead not a list",
			srtShared + `"runners": {"bob": {"command": ["bob", "acp"], "allowRead": "/opt"}}`,
			"runners.bob.allowRead must be a list"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := runnersConfig(t, c.members, "")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("error = %v, want %q", err, c.want)
			}
		})
	}
}

func TestSingleAgentFormGivesTheDefaultRunnerTheSharedSRTLists(t *testing.T) {
	cfg, err := runnersConfig(t, srtRunnerBlock(`"srt": "/opt/homebrew/bin/srt", "allowedDomains": ["example.com"], "allowRead": ["/opt/homebrew"]`), "")
	if err != nil {
		t.Fatal(err)
	}
	def, _ := cfg.Agent("")
	if strings.Join(def.AllowedDomains, " ") != "example.com" || strings.Join(def.AllowRead, " ") != "/opt/homebrew" {
		t.Fatalf("default runner lists = %+v", def)
	}
}
