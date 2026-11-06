package server

// Runners start a project's agent (D-025, FR-45). Both hold the project's lock for as long as the
// agent runs, so a second gateway, or a second start by this one, cannot run two agents on one
// task store (F-21, D-015).

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"agmente/gateway/internal/config"
	"agmente/gateway/internal/store"
)

// errProjectLocked means another process holds the project's lock.
var errProjectLocked = errors.New("the project's agent is already running (another gateway or a leftover agent holds its lock)")

// runner starts one agent for a project, with its HOME, and returns the process.
type runner interface {
	start(p store.Project, home string) (*agentProcess, error)
	// exec runs one command for the project (git, D-034) and returns its capped output.
	exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error)
}

func newRunner(cfg *config.Config) runner {
	if cfg.Runner.Kind == "podman" {
		return podmanRunner{cfg: cfg}
	}
	return hostRunner{cfg: cfg}
}

// agentEnv is the allow-listed environment with HOME set to the project's home. The gateway's own
// HOME never reaches an agent.
func agentEnv(names []string, home string) []string {
	env := []string{}
	for _, kv := range buildAgentEnv(names) {
		if len(kv) >= 5 && kv[:5] == "HOME=" {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "HOME="+home)
}

// hostRunner runs the agent on the gateway host, as the gateway user, with its working directory
// set to the project (D-013) and HOME set to the project home. For tests and development only:
// config refuses it unless runner.allowHost is true.
//
// Lock: an exclusive flock on <home>/.agmente.lock, taken without waiting. The agent inherits the
// locked file (fd 3), so the lock lasts while the agent runs, even if the gateway dies first.
type hostRunner struct{ cfg *config.Config }

func (r hostRunner) start(p store.Project, home string) (*agentProcess, error) {
	lock, err := lockHome(home)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(r.cfg.AgentCommand[0], r.cfg.AgentCommand[1:]...)
	cmd.Dir = p.Path
	cmd.Env = agentEnv(r.cfg.EnvPassthrough, home)
	proc, err := startProcess(cmd, []*os.File{lock})
	if err != nil {
		lock.Close()
		return nil, err
	}
	proc.lock = lock
	return proc, nil
}

func lockHome(home string) (*os.File, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(home, ".agmente.lock"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errProjectLocked
		}
		return nil, err
	}
	return f, nil
}

// podmanRunner runs the agent in a container named agmente-<projectId>; Podman refuses a second
// container with that name, which is the lock (D-015). The project folder and the project home are
// mounted at their host paths, so paths in ACP messages mean the same thing on both sides and need
// no translation. Allow-listed variables are passed by name only (-e NAME): their values never
// appear in the podman command line. The podman CLI itself gets the gateway's environment, which
// rootless podman needs (XDG_RUNTIME_DIR); only the names listed reach the container.
// Status: built and unit-tested; not yet run live (verify in PLAN 4.1).
type podmanRunner struct{ cfg *config.Config }

func (r podmanRunner) args(p store.Project, home string) []string {
	args := []string{"run", "--rm", "-i", "--name", "agmente-" + p.ID, "--pull=never", "--init",
		"-e", "HOME=" + home,
		"-v", home + ":" + home,
		"-v", p.Path + ":" + p.Path,
		"-w", p.Path,
	}
	for _, name := range r.cfg.EnvPassthrough {
		if name != "HOME" && name != "PATH" { // PATH and HOME come from the image and the line above
			args = append(args, "-e", name)
		}
	}
	args = append(args, r.cfg.Runner.Image)
	return append(args, r.cfg.AgentCommand...)
}

func (r podmanRunner) start(p store.Project, home string) (*agentProcess, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	cmd := exec.Command(r.cfg.Runner.Podman, r.args(p, home)...)
	cmd.Env = os.Environ()
	proc, err := startProcess(cmd, nil)
	if err != nil {
		return nil, fmt.Errorf("podman: %w", err)
	}
	return proc, nil
}
