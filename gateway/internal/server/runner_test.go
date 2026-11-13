package server

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

func TestPodmanArgsMountPathsAsIsAndPassSecretsByNameOnly(t *testing.T) {
	cfg := &config.Config{
		Runners:       []config.AgentRunner{{ID: "default", Command: []string{"bob", "acp", "--accept-license"}, EnvPassthrough: []string{"PATH", "HOME", "LANG", "BOB_API_KEY"}, Image: "acpcode-bob:2.0.9"}},
		DefaultRunner: "default",
		Runner:        config.Runner{Kind: "podman", Podman: "podman"},
	}
	t.Setenv("BOB_API_KEY", "must-not-appear")
	args := podmanRunner{cfg: cfg}.args(store.Project{ID: "0123456789ab", Path: "/srv/p/x"}, "/var/lib/acpcode/state/homes/0123456789ab")
	got := strings.Join(args, " ")
	want := "run --rm -i --name acpcode-0123456789ab --pull=never --init --userns=keep-id:uid=10001,gid=10001 --user 10001:10001" +
		" -e HOME=/var/lib/acpcode/state/homes/0123456789ab" +
		" -v /var/lib/acpcode/state/homes/0123456789ab:/var/lib/acpcode/state/homes/0123456789ab" +
		" -v /srv/p/x:/srv/p/x -w /srv/p/x -e LANG -e BOB_API_KEY --entrypoint bob acpcode-bob:2.0.9 acp --accept-license"
	if got != want {
		t.Fatalf("args:\n got  %s\n want %s", got, want)
	}
	if strings.Contains(got, "must-not-appear") {
		t.Fatal("a secret value is on the command line")
	}
}

func TestHostLockIsExclusiveAndInheritedByTheAgent(t *testing.T) {
	home := t.TempDir()
	first, err := lockHome(home)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockHome(home); !errors.Is(err, errProjectLocked) {
		t.Fatalf("second lock: %v", err)
	}
	// A child that inherits the locked file keeps the lock after the gateway closes its copy.
	cmd := exec.Command("/bin/sleep", "1")
	proc, err := startProcess(cmd, []*os.File{first})
	if err != nil {
		t.Fatal(err)
	}
	first.Close()
	if _, err := lockHome(home); !errors.Is(err, errProjectLocked) {
		t.Fatalf("lock while the child runs: %v", err)
	}
	<-proc.exited
	again, err := lockHome(home)
	if err != nil {
		t.Fatalf("lock after the child exited: %v", err)
	}
	again.Close()
	if _, err := os.Stat(filepath.Join(home, ".acpcode.lock")); err != nil {
		t.Fatal(err)
	}
}

func TestAgentEnvReplacesHome(t *testing.T) {
	t.Setenv("HOME", "/Users/gateway")
	t.Setenv("ACPCODE_X", "1")
	env := strings.Join(agentEnv([]string{"PATH", "HOME", "ACPCODE_X"}, "/state/homes/p"), "\n")
	if strings.Contains(env, "/Users/gateway") || !strings.Contains(env, "HOME=/state/homes/p") || !strings.Contains(env, "ACPCODE_X=1") {
		t.Fatalf("env: %s", env)
	}
}
