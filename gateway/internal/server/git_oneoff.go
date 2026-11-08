package server

// One-off commands for the git push path (D-105). Every command runs in its own container, never
// in the agent's, so the push can never reach the agent's process tree. Only the push container
// has network access. A token is never in argv: it is a value in the runner CLI's environment,
// passed to the container with `-e NAME`.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"

	"acpcode/gateway/internal/store"
)

// pushTimeout bounds one push-path command. A push waits on the network, so it is longer than
// the 5 s of a git call (NFR-8 does not cover the push).
var pushTimeout = 120 * time.Second

// oneOffCmd is one command for a one-off container.
type oneOffCmd struct {
	argv    []string // argv[0] is the container entrypoint; the rest are its arguments
	vars    []string // K=V given to the container with -e K=V (never a secret)
	secrets []string // K=V given to the runner CLI's environment only; each name goes in with -e NAME
	mounts  []string // host paths mounted read-only at the same path
	network bool     // true: the default network; false: --network none
}

// secretNames returns the names of the secrets, for `-e NAME`.
func (c oneOffCmd) secretNames() []string {
	names := make([]string, 0, len(c.secrets))
	for _, kv := range c.secrets {
		name, _, _ := strings.Cut(kv, "=")
		names = append(names, name)
	}
	return names
}

// oneOffName is a container name for one push-path run: unique, and never the agent's name.
func oneOffName(p store.Project) (string, error) {
	var suffix [4]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", err
	}
	return "acpcode-push-" + p.ID + "-" + hex.EncodeToString(suffix[:]), nil
}

// oneOff on the host runner (tests and development only): the command runs as the gateway user in
// the project folder, with exactly the given environment.
func (r hostRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	cmd := exec.Command(c.argv[0], c.argv[1:]...)
	cmd.Dir = p.Path
	cmd.Env = append(append([]string{}, c.vars...), c.secrets...)
	return runCappedFor(ctx, pushTimeout, cmd, stdin)
}

// oneOffArgs is the podman command for one push-path command. The project folder and the home
// are mounted at their host paths, as for git (D-034). The network is off unless c.network is set.
func (r podmanRunner) oneOffArgs(name string, p store.Project, home string, c oneOffCmd) []string {
	args := []string{"run", "--rm", "-i", "--name", name, "--pull=never", "--init"}
	if !c.network {
		args = append(args, "--network=none")
	}
	args = append(args, r.userArgs()...)
	args = append(args, "-v", home+":"+home, "-v", p.Path+":"+p.Path, "-w", p.Path)
	for _, m := range c.mounts {
		args = append(args, "-v", m+":"+m+":ro")
	}
	for _, kv := range c.vars {
		args = append(args, "-e", kv)
	}
	for _, n := range c.secretNames() {
		args = append(args, "-e", n) // the value comes from the CLI's environment, not argv
	}
	args = append(args, "--entrypoint", c.argv[0], r.cfg.Runner.Image)
	return append(args, c.argv[1:]...)
}

// oneOff runs a push-path command in a new podman container. A timeout or an output overrun
// removes the container by name, as for git.
func (r podmanRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	name, err := oneOffName(p)
	if err != nil {
		return gitResult{}, err
	}
	cmd := exec.Command(r.cfg.Runner.Podman, r.oneOffArgs(name, p, home, c)...)
	cmd.Env = append(os.Environ(), c.secrets...)
	res, err := runCappedFor(ctx, pushTimeout, cmd, stdin)
	if errors.Is(err, errGitTimeout) || res.Truncated {
		rm := exec.Command(r.cfg.Runner.Podman, "rm", "-f", "-t", "0", name)
		rm.Env = os.Environ()
		_ = rm.Run()
	}
	return res, err
}

// oneOffArgs is the Apple `container run` command for one push-path command. Apple container
// has no user-namespace mapping (D-079), so the user is set with -u. Without --network the
// command gets the default network; with the flag off it gets --network none.
func (r *appleRunner) oneOffArgs(name string, p store.Project, home string, c oneOffCmd) []string {
	args := []string{"run", "--rm", "-i", "--progress", "none", "--name", name, "--init"}
	if !c.network {
		args = append(args, "--network", "none")
	}
	args = append(args, r.userArgs()...)
	args = append(args, "-v", home+":"+home, "-v", p.Path+":"+p.Path, "-w", p.Path)
	for _, m := range c.mounts {
		args = append(args, "-v", m+":"+m+":ro")
	}
	for _, kv := range c.vars {
		args = append(args, "-e", kv)
	}
	for _, n := range c.secretNames() {
		args = append(args, "-e", n)
	}
	args = append(args, "--entrypoint", c.argv[0], r.cfg.Runner.Image)
	return append(args, c.argv[1:]...)
}

// oneOff runs a push-path command in a new Apple container. It never uses `container exec`, so it
// never runs in the agent's container.
func (r *appleRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	name, err := oneOffName(p)
	if err != nil {
		return gitResult{}, err
	}
	cmd := exec.Command(r.cli(), r.oneOffArgs(name, p, home, c)...)
	cmd.Env = append(os.Environ(), c.secrets...)
	res, err := runCappedFor(ctx, pushTimeout, cmd, stdin)
	if errors.Is(err, errGitTimeout) || res.Truncated {
		rm := exec.Command(r.cli(), "delete", "--force", name)
		rm.Env = os.Environ()
		_ = rm.Run()
	}
	return res, err
}
