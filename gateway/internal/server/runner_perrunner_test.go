package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

// Per-runner secrets, srt lists, lock and container names (D-126).

const claudeSecretValue = "fake-claude-token-3c9e"

// twoRunnerFixture is an srt fixture with a bob and a claude runner, each with its own domains,
// read paths and secrets file. The values are fake.
func twoRunnerFixture(t *testing.T) (srtFixture, config.AgentRunner, config.AgentRunner) {
	t.Helper()
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	bob := config.AgentRunner{
		ID: "bob", Command: []string{"bob", "acp"}, EnvPassthrough: []string{"PATH", "BOB_API_KEY"},
		SecretsFile: write("bob.env", "BOB_API_KEY="+secretValue+"\n"), SecretNames: []string{"BOB_API_KEY"},
		AllowedDomains: []string{"bob.example.com"},
	}
	claude := config.AgentRunner{
		ID: "claude", Command: []string{"claude-agent-acp"}, EnvPassthrough: []string{"PATH", "ANTHROPIC_AUTH_TOKEN"},
		SecretsFile: write("claude.env", "ANTHROPIC_AUTH_TOKEN="+claudeSecretValue+"\nBOB_API_KEY=not-listed\n"), SecretNames: []string{"ANTHROPIC_AUTH_TOKEN"},
		AllowedDomains: []string{"claude.example.com"}, AllowRead: []string{"/opt/claude-tools"},
	}
	f.cfg.Runners = []config.AgentRunner{bob, claude}
	f.cfg.DefaultRunner = "bob"
	return f, bob, claude
}

func TestSRTSettingsUseTheProjectsRunnerLists(t *testing.T) {
	f, _, _ := twoRunnerFixture(t)
	bobProject, claudeProject := f.project, f.project
	bobProject.Runner, claudeProject.Runner = "bob", "claude"

	cs := f.runner.settings(claudeProject, f.home, srtSpec{agent: true})
	if got := strings.Join(cs.Network.AllowedDomains, " "); got != "claude.example.com" {
		t.Fatalf("claude domains = %q, want its own only", got)
	}
	if !strings.Contains(strings.Join(cs.Filesystem.AllowRead, " "), "/opt/claude-tools") {
		t.Fatalf("claude allowRead lacks its own path: %v", cs.Filesystem.AllowRead)
	}
	bs := f.runner.settings(bobProject, f.home, srtSpec{agent: true})
	if got := strings.Join(bs.Network.AllowedDomains, " "); got != "bob.example.com" {
		t.Fatalf("bob domains = %q", got)
	}
	if strings.Contains(strings.Join(bs.Filesystem.AllowRead, " "), "/opt/claude-tools") {
		t.Fatalf("bob can read claude's extra path: %v", bs.Filesystem.AllowRead)
	}
	// git and push commands do not take the runner's domains.
	if g := f.runner.settings(claudeProject, f.home, srtSpec{gitConfig: true}); len(g.Network.AllowedDomains) != 0 {
		t.Fatalf("git has network: %v", g.Network.AllowedDomains)
	}
	if p := f.runner.settings(claudeProject, f.home, srtSpec{gitConfig: true, domains: []string{"github.com"}}); strings.Join(p.Network.AllowedDomains, " ") != "github.com" {
		t.Fatalf("push domains = %v", p.Network.AllowedDomains)
	}
}

func TestSecretEnvIsPerRunner(t *testing.T) {
	_, bob, claude := twoRunnerFixture(t)
	cenv, err := secretEnv(claude)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(cenv, "\n") != "ANTHROPIC_AUTH_TOKEN="+claudeSecretValue {
		t.Fatalf("claude env = %d entries, want the one listed name only", len(cenv))
	}
	benv, err := secretEnv(bob)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(benv, "\n") != "BOB_API_KEY="+secretValue {
		t.Fatalf("bob env = %d entries", len(benv))
	}
	for _, kv := range cenv {
		if strings.Contains(kv, secretValue) || strings.HasPrefix(kv, "BOB_API_KEY=") {
			t.Fatal("bob's secret reached claude's environment")
		}
	}
}

func TestClaudeProcessEnvHasNoBobSecret(t *testing.T) {
	bin, _ := fakeSRT(t)
	f, _, _ := twoRunnerFixture(t)
	f.cfg.Runner.SRT = bin
	f.cfg.Runners[1].Command = []string{"sleep", "30"}
	t.Setenv("BOB_API_KEY", "gateway-env-value-must-not-pass")
	p := f.project
	p.Runner, p.Secondary = "claude", true
	proc, err := f.runner.start(p, f.home)
	if err != nil {
		t.Fatal(err)
	}
	defer proc.terminate(0)
	if v, ok := lastEnv(proc.cmd.Env, "ANTHROPIC_AUTH_TOKEN"); !ok || v != claudeSecretValue {
		t.Fatalf("claude does not get its own token: %q", v)
	}
	for _, kv := range proc.cmd.Env {
		if strings.Contains(kv, secretValue) || strings.HasPrefix(kv, "BOB_API_KEY=") {
			t.Fatal("bob's secret is in claude's process environment")
		}
	}
	if argvHasValue(proc.cmd.Args) || strings.Contains(strings.Join(proc.cmd.Args, " "), claudeSecretValue) {
		t.Fatal("a secret is in argv")
	}
	// The settings file of this agent is named for the runner and holds only claude's domain.
	data, err := os.ReadFile(filepath.Join(f.state, "srt", p.ID+"-claude-agent.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "claude.example.com") || strings.Contains(string(data), "bob.example.com") {
		t.Fatalf("settings = %s", data)
	}
}

func TestLockAndContainerNamesFollowTheRunner(t *testing.T) {
	if got := lockFileName(""); got != ".acpcode.lock" {
		t.Fatalf("lock for no runner = %q", got)
	}
	if got := lockFileName("claude"); got != ".acpcode-claude.lock" {
		t.Fatalf("lock for claude = %q", got)
	}
	if got := agentContainerName(store.Project{ID: "0123456789ab"}); got != "acpcode-0123456789ab" {
		t.Fatalf("container name = %q", got)
	}
	if got := agentContainerName(store.Project{ID: "0123456789ab", Runner: "bob"}); got != "acpcode-0123456789ab" {
		t.Fatalf("the own agent's container name = %q", got)
	}
	if got := agentContainerName(store.Project{ID: "0123456789ab", Runner: "claude", Secondary: true}); got != "acpcode-0123456789ab-claude" {
		t.Fatalf("container name = %q", got)
	}
	// Two runners of one project hold different locks; one runner cannot take its own twice.
	home := t.TempDir()
	a, err := lockHome(home, "bob")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := lockHome(home, "claude")
	if err != nil {
		t.Fatalf("a second runner's lock collides: %v", err)
	}
	defer b.Close()
	if _, err := lockHome(home, "bob"); err == nil {
		t.Fatal("the same runner locked twice")
	}
}

func TestPodmanAndAppleNameTheContainerPerRunner(t *testing.T) {
	cfg := withRunner(&config.Config{Runner: config.Runner{Kind: "podman", Podman: "podman"}}, []string{"bob", "acp"}, []string{"PATH"}, "img:1")
	cfg.Runners[0].ID = "claude"
	cfg.DefaultRunner = "claude"
	p := store.Project{ID: "0123456789ab", Path: "/srv/p/x", Runner: "claude", Secondary: true}
	pr := podmanRunner{cfg: cfg}
	if args := pr.args(p, "/h"); !containsPair(args, "--name", "acpcode-0123456789ab-claude") {
		t.Fatalf("podman args: %q", args)
	}
	if args := newAppleRunner(cfg).agentArgs(p, "/h"); !containsPair(args, "--name", "acpcode-0123456789ab-claude") {
		t.Fatalf("apple args: %q", args)
	}
}
