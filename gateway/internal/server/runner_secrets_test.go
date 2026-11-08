package server

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

const secretValue = "secret-value-never-in-argv-5d1e"

// secretsRunnerConfig is a config whose agent gets BOB_API_KEY from a secrets file.
func secretsRunnerConfig(t *testing.T, mode os.FileMode, agentCommand []string) *config.Config {
	t.Helper()
	path := filepath.Join(t.TempDir(), "agent.env")
	if err := os.WriteFile(path, []byte("BOB_API_KEY="+secretValue+"\n"), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return &config.Config{
		AgentCommand:   agentCommand,
		EnvPassthrough: []string{"PATH", "BOB_API_KEY"},
		SecretsFile:    path,
		SecretNames:    []string{"BOB_API_KEY"},
		Runner:         config.Runner{Kind: "host"},
	}
}

// lastEnv is the value a child process would see for name: the last entry wins (exec's rule).
func lastEnv(env []string, name string) (string, bool) {
	value, found := "", false
	for _, kv := range env {
		if strings.HasPrefix(kv, name+"=") {
			value, found = kv[len(name)+1:], true
		}
	}
	return value, found
}

func argvHasValue(args []string) bool {
	for _, a := range args {
		if strings.Contains(a, secretValue) {
			return true
		}
	}
	return false
}

func TestHostAgentGetsSecretInEnvironmentNotArgv(t *testing.T) {
	cfg := secretsRunnerConfig(t, 0o600, []string{"/bin/sh", "-c", "sleep 5", "bob", "acp", "--accept-license"})
	t.Setenv("BOB_API_KEY", "gateway-env-value-must-lose")
	proc, err := hostRunner{cfg: cfg}.start(store.Project{ID: "0123456789ab", Path: t.TempDir()}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer proc.terminate(0)
	if argvHasValue(proc.cmd.Args) {
		t.Fatalf("the secret value is in argv: %q", proc.cmd.Args)
	}
	if v, ok := lastEnv(proc.cmd.Env, "BOB_API_KEY"); !ok || v != secretValue {
		t.Fatalf("the agent environment holds %q, want the file's value", v)
	}
}

func TestContainerRunnersPassSecretByNameOnly(t *testing.T) {
	// A stub podman that sleeps: the test reads the command the gateway built, it runs nothing real.
	stub := filepath.Join(t.TempDir(), "podman")
	if err := os.WriteFile(stub, []byte("#!/bin/sh\nsleep 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := secretsRunnerConfig(t, 0o600, []string{"bob", "acp", "--accept-license"})
	cfg.Runner = config.Runner{Kind: "podman", Image: "acpcode-bob:2.0.9", Podman: stub}
	t.Setenv("BOB_API_KEY", "gateway-env-value-must-lose")
	home := filepath.Join(t.TempDir(), "home")
	project := store.Project{ID: "0123456789ab", Path: t.TempDir()}

	args := podmanRunner{cfg: cfg}.args(project, home)
	if argvHasValue(args) {
		t.Fatalf("podman argv holds the value: %q", args)
	}
	if !containsPair(args, "-e", "BOB_API_KEY") {
		t.Fatalf("podman args do not pass the name: %q", args)
	}
	proc, err := podmanRunner{cfg: cfg}.start(project, home)
	if err != nil {
		t.Fatal(err)
	}
	defer proc.terminate(0)
	if argvHasValue(proc.cmd.Args) {
		t.Fatalf("the started podman command holds the value: %q", proc.cmd.Args)
	}
	if v, ok := lastEnv(proc.cmd.Env, "BOB_API_KEY"); !ok || v != secretValue {
		t.Fatalf("the podman CLI environment holds %q, want the file's value", v)
	}

	// The Apple runner builds the same kind of command: the name only.
	apple := cfg
	apple.Runner = config.Runner{Kind: "apple", Image: "localhost/acpcode-bob:2.0.9", Container: "/opt/homebrew/bin/container"}
	if aargs := newAppleRunner(apple).agentArgs(project, home); argvHasValue(aargs) || !containsPair(aargs, "-e", "BOB_API_KEY") {
		t.Fatalf("apple args: %q", aargs)
	}
}

func TestAgentRefusesAnUnreadableSecretsFile(t *testing.T) {
	cfg := secretsRunnerConfig(t, 0o644, []string{"/bin/sh", "-c", "sleep 5"})
	home := t.TempDir()
	_, err := hostRunner{cfg: cfg}.start(store.Project{ID: "0123456789ab", Path: t.TempDir()}, home)
	if !errors.Is(err, errSecrets) {
		t.Fatalf("start with a 0644 secrets file: %v", err)
	}
	if strings.Contains(err.Error(), secretValue) {
		t.Fatal("the error holds the value")
	}
	// Nothing was locked or started: the lock file can be taken now.
	lock, lerr := lockHome(home)
	if lerr != nil {
		t.Fatalf("the home is locked after a refused start: %v", lerr)
	}
	lock.Close()
}

func TestSecretEnvWithoutFileIsEmpty(t *testing.T) {
	env, err := secretEnv(&config.Config{})
	if err != nil || env != nil {
		t.Fatalf("no file: %v %v", env, err)
	}
}

// TestAgentArgvNeverHasTrust checks the argv the gateway builds for each runner: the gateway adds no
// --trust (FR-32, D-013). The command is the one the example config uses.
func TestAgentArgvNeverHasTrust(t *testing.T) {
	command := []string{"bob", "acp", "--accept-license", "--log-level", "warn"}
	project := store.Project{ID: "0123456789ab", Path: t.TempDir()}
	home := "/var/lib/acpcode/state/homes/0123456789ab"
	cfg := &config.Config{AgentCommand: command, EnvPassthrough: []string{"PATH", "HOME", "BOB_API_KEY"},
		Runner: config.Runner{Kind: "podman", Image: "acpcode-bob:2.0.9", Podman: "podman"}}
	argvs := map[string][]string{
		"podman": podmanRunner{cfg: cfg}.args(project, home),
		"apple":  newAppleRunner(&config.Config{AgentCommand: command, EnvPassthrough: []string{"PATH", "HOME"}, Runner: config.Runner{Kind: "apple", Image: "localhost/acpcode-bob:2.0.9"}}).agentArgs(project, home),
	}
	// Host runner: its command is built inline by start, so run a real command with the same argv.
	hostCfg := &config.Config{AgentCommand: []string{"/bin/sh", "-c", "sleep 5", "bob", "acp", "--accept-license", "--log-level", "warn"}, EnvPassthrough: []string{"PATH"}, Runner: config.Runner{Kind: "host"}}
	proc, err := hostRunner{cfg: hostCfg}.start(project, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer proc.terminate(0)
	argvs["host"] = proc.cmd.Args
	for name, args := range argvs {
		for _, a := range args {
			if strings.Contains(a, "--trust") {
				t.Errorf("%s argv holds %q: %q", name, a, args)
			}
		}
	}
}

func containsPair(args []string, flag, value string) bool {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}
