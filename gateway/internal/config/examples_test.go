package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loadExample reads a shipped example config, swaps the placeholder paths for ones under a temp
// folder (the secrets file is made, mode 0600, with a fake value) and validates it.
func loadExample(t *testing.T, name string) (*Config, error) {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", name))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	secrets := filepath.Join(dir, "claude.env")
	if err := os.WriteFile(secrets, []byte("ANTHROPIC_AUTH_TOKEN="+testSecretValue+"\nANTHROPIC_MODEL=m\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	src := strings.NewReplacer(
		"/Users/you/acpcode/claude.env", secrets,
		"/Users/you/acpcode/projects", filepath.Join(dir, "projects"),
		"/Users/you/acpcode/state", filepath.Join(dir, "state"),
	).Replace(string(data))
	return validateJSON(t, src)
}

func TestMacSRTExampleLoadsWithTwoRunners(t *testing.T) {
	cfg, err := loadExample(t, "config.mac-srt.example.json")
	if err != nil {
		t.Fatalf("config.mac-srt.example.json does not load: %v", err)
	}
	if cfg.Runner.Kind != "srt" || cfg.DefaultRunner != "bob" || len(cfg.Runners) != 2 {
		t.Fatalf("runner %q default %q runners %d", cfg.Runner.Kind, cfg.DefaultRunner, len(cfg.Runners))
	}
	bob, _ := cfg.Agent("bob")
	if strings.Join(bob.AllowedDomains, " ") != "api.us-east.bob.ibm.com bob.ibm.com iam.cloud.ibm.com" || bob.SecretsFile != "" {
		t.Fatalf("bob = %+v", bob)
	}
	claude, _ := cfg.Agent("claude")
	if strings.Join(claude.AllowedDomains, " ") != "model-gateway.example.com" || strings.Join(claude.AllowRead, " ") != "/opt/homebrew /usr/local" {
		t.Fatalf("claude lists = %v %v", claude.AllowedDomains, claude.AllowRead)
	}
	if claude.SecretsFile == "" || strings.Join(claude.SecretNames, ",") != "ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL" || len(claude.SecretsIgnored) != 0 {
		t.Fatalf("claude secrets = %q %v %v", claude.SecretsFile, claude.SecretNames, claude.SecretsIgnored)
	}
}

func TestMacAppleExampleStillLoads(t *testing.T) {
	if _, err := loadExample(t, "config.mac.example.json"); err != nil {
		t.Fatalf("config.mac.example.json does not load: %v", err)
	}
}
