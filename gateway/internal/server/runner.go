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

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
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
	switch cfg.Runner.Kind {
	case "podman":
		return podmanRunner{cfg: cfg}
	case "apple":
		return newAppleRunner(cfg)
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

// errSecrets means the agent secrets file could not be read at start. Its text names the problem,
// never a value.
var errSecrets = errors.New("the agent secrets file cannot be read")

// secretEnv reads the agent secrets file now and returns NAME=value for each entry the agent may
// receive (PLAN 4.2). The values go only into the runner CLI's environment (cmd.Env). They never go
// in argv: the container runners pass the name with `-e NAME`, and the host runner sets the variable
// directly. Nothing here logs a value.
func secretEnv(cfg *config.Config) ([]string, error) {
	if cfg.SecretsFile == "" {
		return nil, nil
	}
	secrets, err := config.ReadSecretsFile(cfg.SecretsFile)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errSecrets, err)
	}
	allowed := make(map[string]bool, len(cfg.SecretNames))
	for _, name := range cfg.SecretNames {
		allowed[name] = true
	}
	var env []string
	for _, s := range secrets {
		if allowed[s.Name] {
			env = append(env, s.Name+"="+s.Value)
		}
	}
	return env, nil
}

// hostRunner runs the agent on the gateway host, as the gateway user, with its working directory
// set to the project (D-013) and HOME set to the project home. For tests and development only:
// config refuses it unless runner.allowHost is true.
//
// Lock: an exclusive flock on <home>/.acpcode.lock, taken without waiting. The agent inherits the
// locked file (fd 3), so the lock lasts while the agent runs, even if the gateway dies first.
type hostRunner struct{ cfg *config.Config }

func (r hostRunner) start(p store.Project, home string) (*agentProcess, error) {
	secrets, err := secretEnv(r.cfg)
	if err != nil {
		return nil, err
	}
	lock, err := lockHome(home)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(r.cfg.AgentCommand[0], r.cfg.AgentCommand[1:]...)
	cmd.Dir = p.Path
	// Later entries win for a duplicate name, so a secret overrides the same name from the gateway's env.
	cmd.Env = append(agentEnv(r.cfg.EnvPassthrough, home), secrets...)
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
	f, err := os.OpenFile(filepath.Join(home, ".acpcode.lock"), os.O_RDWR|os.O_CREATE, 0o600)
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

// podmanRunner runs the agent in a container named acpcode-<projectId>; Podman refuses a second
// container with that name, which is the lock (D-015). The project folder and the project home are
// mounted at their host paths, so paths in ACP messages mean the same thing on both sides and need
// no translation. Allow-listed variables are passed by name only (-e NAME): their values never
// appear in the podman command line. The podman CLI itself gets the gateway's environment, which
// rootless podman needs (XDG_RUNTIME_DIR); only the names listed reach the container.
// Status: built and unit-tested; not yet run live (verify in PLAN 4.1).
type podmanRunner struct{ cfg *config.Config }

// userArgs makes the container user the owner of what the gateway user owns (D-051). Rootless
// Podman maps the user who runs it to root in the container by default, and every other uid to a
// sub-uid that owns nothing on the host; so the image's user could not write the project home
// (0700), the snapshot folder (0700) or the project folder. `--userns=keep-id:uid=U,gid=G` maps
// the gateway's own uid and gid to U and G inside, `--user U:G` runs as them, and the 0700 folders
// stay 0700: no folder is made world-writable, and nobody else on the host can use them.
func (r podmanRunner) userArgs() []string {
	uid, gid := r.cfg.Runner.ContainerUID, r.cfg.Runner.ContainerGID
	if uid == 0 {
		uid = config.DefaultContainerID
	}
	if gid == 0 {
		gid = config.DefaultContainerID
	}
	return []string{fmt.Sprintf("--userns=keep-id:uid=%d,gid=%d", uid, gid), "--user", fmt.Sprintf("%d:%d", uid, gid)}
}

func (r podmanRunner) args(p store.Project, home string) []string {
	args := []string{"run", "--rm", "-i", "--name", "acpcode-" + p.ID, "--pull=never", "--init"}
	args = append(args, r.userArgs()...)
	args = append(args,
		"-e", "HOME="+home,
		"-v", home+":"+home,
		"-v", p.Path+":"+p.Path,
		"-w", p.Path,
	)
	for _, name := range r.cfg.EnvPassthrough {
		if name != "HOME" && name != "PATH" { // PATH and HOME come from the image and the line above
			args = append(args, "-e", name)
		}
	}
	return append(args, imageAndCommand(r.cfg.Runner.Image, r.cfg.AgentCommand)...)
}

func (r podmanRunner) start(p store.Project, home string) (*agentProcess, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	secrets, err := secretEnv(r.cfg)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(r.cfg.Runner.Podman, r.args(p, home)...)
	cmd.Env = append(os.Environ(), secrets...)
	proc, err := startProcess(cmd, nil)
	if err != nil {
		return nil, fmt.Errorf("podman: %w", err)
	}
	return proc, nil
}

// imageAndCommand is the image and the agent command for `run`. The image's own entrypoint is
// replaced by the command's first word, because the project image declares `bob` as its
// entrypoint (deploy/bob-project.Containerfile). Without the override, `bob` runs as an argument
// of `bob` and never starts the agent. The git runner already does the same with `--entrypoint`.
func imageAndCommand(image string, argv []string) []string {
	if len(argv) == 0 {
		return []string{image}
	}
	out := []string{"--entrypoint", argv[0], image}
	return append(out, argv[1:]...)
}
