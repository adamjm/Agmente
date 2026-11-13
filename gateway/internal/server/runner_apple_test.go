package server

import (
	"strings"
	"testing"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

func appleTestConfig() *config.Config {
	return &config.Config{
		Runners:       []config.AgentRunner{{ID: "default", Command: []string{"bob", "acp", "--accept-license"}, EnvPassthrough: []string{"PATH", "HOME", "LANG", "BOB_API_KEY"}, Image: "acpcode-bob:2.0.9"}},
		DefaultRunner: "default",
		Runner:        config.Runner{Kind: "apple", Container: "/opt/homebrew/bin/container"},
	}
}

func TestAppleAgentArgsPassSecretsByNameOnly(t *testing.T) {
	t.Setenv("BOB_API_KEY", "must-not-appear")
	r := newAppleRunner(appleTestConfig())
	args := r.agentArgs(store.Project{ID: "0123456789ab", Path: "/srv/p/x"}, "/var/lib/acpcode/state/homes/0123456789ab")
	got := strings.Join(args, " ")
	want := "run -i --rm --progress none --name acpcode-0123456789ab --init -u 10001:10001" +
		" -e HOME=/var/lib/acpcode/state/homes/0123456789ab" +
		" -v /var/lib/acpcode/state/homes/0123456789ab:/var/lib/acpcode/state/homes/0123456789ab" +
		" -v /srv/p/x:/srv/p/x -w /srv/p/x -e LANG -e BOB_API_KEY --entrypoint bob acpcode-bob:2.0.9 acp --accept-license"
	if got != want {
		t.Fatalf("args:\n got  %s\n want %s", got, want)
	}
	if strings.Contains(got, "must-not-appear") {
		t.Fatal("a secret value is on the command line")
	}
	if strings.Contains(got, "keep-id") {
		t.Fatal("apple container has no keep-id option; it must not be passed")
	}
}

func TestAppleUserDefaultsAndOverrides(t *testing.T) {
	cfg := appleTestConfig()
	if got := strings.Join(newAppleRunner(cfg).userArgs(), " "); got != "-u 10001:10001" {
		t.Fatalf("default user: %s", got)
	}
	cfg.Runner.ContainerUID, cfg.Runner.ContainerGID = 2000, 3000
	if got := strings.Join(newAppleRunner(cfg).userArgs(), " "); got != "-u 2000:3000" {
		t.Fatalf("override user: %s", got)
	}
}

func TestAppleExecRunsGitInTheAgentContainerWithTheGitEnvironmentOnly(t *testing.T) {
	t.Setenv("BOB_API_KEY", "must-not-appear")
	r := newAppleRunner(appleTestConfig())
	p := store.Project{ID: "0123456789ab", Path: "/srv/p/x"}
	home := "/var/lib/acpcode/state/homes/0123456789ab"
	argv := gitCommand(p.Path, "status", "--porcelain=v2")
	got := strings.Join(r.execArgs("acpcode-0123456789ab", p, home, argv, []string{"GIT_INDEX_FILE=/tmp/i"}), " ")
	if !strings.HasPrefix(got, "exec -i -u 10001:10001 -w /srv/p/x ") {
		t.Fatalf("exec prefix: %s", got)
	}
	if !strings.Contains(got, " acpcode-0123456789ab git --no-pager ") {
		t.Fatalf("exec must target the agent container and run git: %s", got)
	}
	if strings.Contains(got, "BOB_API_KEY") || strings.Contains(got, "must-not-appear") {
		t.Fatalf("git exec must not get the agent's allow-list: %s", got)
	}
	if !strings.Contains(got, "-e GIT_INDEX_FILE=/tmp/i") {
		t.Fatalf("extra git env missing: %s", got)
	}
}

func TestAppleGitFallbackHasNoNetwork(t *testing.T) {
	r := newAppleRunner(appleTestConfig())
	p := store.Project{ID: "0123456789ab", Path: "/srv/p/x"}
	home := "/var/lib/acpcode/state/homes/0123456789ab"
	got := strings.Join(r.gitRunArgs("acpcode-git-x", p, home, gitCommand(p.Path, "log"), nil), " ")
	if !strings.Contains(got, "--network none") {
		t.Fatalf("fallback git container must be off the network: %s", got)
	}
	if !strings.Contains(got, "--rm") || !strings.Contains(got, "--entrypoint git acpcode-bob:2.0.9") {
		t.Fatalf("fallback git container shape: %s", got)
	}
}

func TestNewRunnerPicksAppleByKind(t *testing.T) {
	if _, ok := newRunner(appleTestConfig()).(*appleRunner); !ok {
		t.Fatal("kind apple must select the apple runner")
	}
}

func TestAppleAgentArgsSetTheNameserverOnlyWhenConfigured(t *testing.T) {
	cfg := appleTestConfig()
	p := store.Project{ID: "0123456789ab", Path: "/srv/p/x"}
	if got := strings.Join(newAppleRunner(cfg).agentArgs(p, "/h"), " "); strings.Contains(got, "--dns") {
		t.Fatalf("no dns configured, none passed: %s", got)
	}
	cfg.Runner.DNS = "1.1.1.1"
	if got := strings.Join(newAppleRunner(cfg).agentArgs(p, "/h"), " "); !strings.Contains(got, " --dns 1.1.1.1 ") {
		t.Fatalf("configured dns missing: %s", got)
	}
}
