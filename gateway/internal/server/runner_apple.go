package server

// Apple container runner (PLAN 6.x, D-079). Same contract as podmanRunner: one agent per project in
// a container named acpcode-<projectId>, which is the project lock (D-015), and git only inside a
// container (D-008). Differences from Podman, from the spike in RESULTS 2026-11-07:
//   - There is no --userns=keep-id. The container user is set with -u U:G, and the bind-mounted
//     0700 folders are writable by it (ownership checked on the Mac).
//   - Git runs with `container exec` into the running agent container (about 0.2 s a call). When
//     no agent container is up, git gets a one-off container with `run --rm` (about 1.1 s), as
//     the podman runner does, with --network none.
//   - Every `run` passes --progress none, so progress lines never reach the output the gateway reads.
//   - `container inspect` and `container list --format json` print environment values. This runner
//     never calls them. Liveness is checked with `container list --quiet`, which prints IDs only.

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

// appleAgentStartTimeout bounds how long start waits for the agent container to show up in the
// listing. A warm start takes about 1.2 s (RESULTS spike); the first start of an image can take
// longer while the init image is fetched.
const appleAgentStartTimeout = 60 * time.Second

// appleAgent is the agent container of one project. ready closes once the container is listed as
// running; until then exec waits. A start that fails never closes ready.
type appleAgent struct {
	proc  *agentProcess
	ready chan struct{}
}

type appleRunner struct {
	cfg *config.Config

	mu     sync.Mutex
	agents map[string]*appleAgent // project id -> its agent container
}

func newAppleRunner(cfg *config.Config) *appleRunner {
	return &appleRunner{cfg: cfg, agents: map[string]*appleAgent{}}
}

// cli is the container binary. Config validation makes a configured path absolute.
func (r *appleRunner) cli() string {
	if r.cfg.Runner.Container != "" {
		return r.cfg.Runner.Container
	}
	return "container"
}

// userArgs runs the process as the image's user (D-051). Apple container has no user-namespace
// mapping, so the uid and gid are set directly.
func (r *appleRunner) userArgs() []string {
	return []string{"-u", fmt.Sprintf("%d:%d", r.uid(), r.gid())}
}

// dnsArgs sets the container's nameserver when config gives one (runner.dns).
func (r *appleRunner) dnsArgs() []string {
	if r.cfg.Runner.DNS == "" {
		return nil
	}
	return []string{"--dns", r.cfg.Runner.DNS}
}

func appleAgentName(p store.Project) string { return "acpcode-" + p.ID }

// agentArgs is the `container run` command for the agent. Allow-listed variables are passed by
// name only, so their values never appear on the command line.
func (r *appleRunner) agentArgs(p store.Project, home string) []string {
	args := []string{"run", "-i", "--rm", "--progress", "none", "--name", appleAgentName(p), "--init"}
	args = append(args, r.userArgs()...)
	args = append(args, r.dnsArgs()...)
	args = append(args,
		"-e", "HOME="+home,
		"-v", home+":"+home,
		"-v", p.Path+":"+p.Path,
		"-w", p.Path,
	)
	for _, name := range r.cfg.EnvPassthrough {
		if name != "HOME" && name != "PATH" {
			args = append(args, "-e", name)
		}
	}
	return append(args, imageAndCommand(r.cfg.Runner.Image, r.cfg.AgentCommand)...)
}

// listedRunning reports whether a container with this name is in `container list`.
func (r *appleRunner) listedRunning(name string) (bool, error) {
	out, err := exec.Command(r.cli(), "list", "--quiet").Output()
	if err != nil {
		return false, fmt.Errorf("container list: %w", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(line) == name {
			return true, nil
		}
	}
	return false, nil
}

func (r *appleRunner) start(p store.Project, home string) (*agentProcess, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return nil, err
	}
	r.mu.Lock()
	if a := r.agents[p.ID]; a != nil && !a.proc.hasExited() {
		r.mu.Unlock()
		return nil, errProjectLocked
	}
	r.mu.Unlock()
	// The container name is the lock across processes too: refuse before starting when another
	// gateway already runs this project's container.
	if up, err := r.listedRunning(appleAgentName(p)); err != nil {
		return nil, err
	} else if up {
		return nil, errProjectLocked
	}
	secrets, err := secretEnv(r.cfg)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(r.cli(), r.agentArgs(p, home)...)
	cmd.Env = append(os.Environ(), secrets...)
	proc, err := startProcess(cmd, nil)
	if err != nil {
		return nil, fmt.Errorf("container: %w", err)
	}
	a := &appleAgent{proc: proc, ready: make(chan struct{})}
	r.mu.Lock()
	r.agents[p.ID] = a
	r.mu.Unlock()
	go func() {
		<-proc.exited
		r.mu.Lock()
		if r.agents[p.ID] == a {
			delete(r.agents, p.ID)
		}
		r.mu.Unlock()
	}()
	if err := r.waitListed(appleAgentName(p), proc); err != nil {
		proc.terminate(time.Second)
		return nil, err
	}
	close(a.ready)
	return proc, nil
}

// waitListed polls the listing until the container shows up, the agent process exits, or the
// start timeout passes.
func (r *appleRunner) waitListed(name string, proc *agentProcess) error {
	deadline := time.Now().Add(appleAgentStartTimeout)
	for {
		up, err := r.listedRunning(name)
		if err != nil {
			return err
		}
		if up {
			return nil
		}
		if proc.hasExited() {
			return errors.New("container: the agent container exited before it was listed as running")
		}
		if time.Now().After(deadline) {
			return errors.New("container: the agent container did not start in time")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// agentFor returns the project's agent container, or nil.
func (r *appleRunner) agentFor(projectID string) *appleAgent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.agents[projectID]
}

// execArgs is `container exec` into the running agent container. The environment is the git
// environment only, never the agent's allow-list.
func (r *appleRunner) execArgs(name string, p store.Project, home string, argv, extraEnv []string) []string {
	args := []string{"exec", "-i"}
	args = append(args, r.userArgs()...)
	args = append(args, "-w", p.Path)
	for _, kv := range gitEnv(home, extraEnv) {
		args = append(args, "-e", kv)
	}
	args = append(args, name)
	return append(args, argv...)
}

// gitRunArgs is a one-off container for git when no agent container is up. --network none keeps
// it off the network; the project folder and home are mounted at their host paths.
func (r *appleRunner) gitRunArgs(name string, p store.Project, home string, argv, extraEnv []string) []string {
	args := []string{"run", "--rm", "-i", "--progress", "none", "--name", name, "--init", "--network", "none"}
	args = append(args, r.userArgs()...)
	args = append(args,
		"-v", home+":"+home,
		"-v", p.Path+":"+p.Path,
		"-w", p.Path,
	)
	for _, kv := range gitEnv(home, extraEnv) {
		args = append(args, "-e", kv)
	}
	args = append(args, "--entrypoint", argv[0], r.cfg.Runner.Image)
	return append(args, argv[1:]...)
}

func (r *appleRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	if a := r.agentFor(p.ID); a != nil {
		select {
		case <-a.ready:
		case <-a.proc.exited:
		case <-ctx.Done():
			return gitResult{}, errGitTimeout
		}
		if !a.proc.hasExited() {
			// A marker in the git process's environment finds it again if the CLI is killed:
			// killing the CLI does not stop a process inside the container.
			var suffix [8]byte
			if _, err := rand.Read(suffix[:]); err != nil {
				return gitResult{}, err
			}
			marker := hex.EncodeToString(suffix[:])
			cmd := exec.Command(r.cli(), r.execArgs(appleAgentName(p), p, home, argv, append(extraEnv, execMarkerPrefix+marker))...)
			cmd.Env = os.Environ()
			return runCapped(ctx, cmd, stdin, func() { r.killExec(appleAgentName(p), marker) })
		}
	}
	var suffix [4]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return gitResult{}, err
	}
	name := "acpcode-git-" + p.ID + "-" + hex.EncodeToString(suffix[:])
	cmd := exec.Command(r.cli(), r.gitRunArgs(name, p, home, argv, extraEnv)...)
	cmd.Env = os.Environ()
	res, err := runCapped(ctx, cmd, stdin)
	if errors.Is(err, errGitTimeout) || res.Truncated {
		// Killing the CLI does not always stop the container: remove it by name.
		rm := exec.Command(r.cli(), "delete", "--force", name)
		rm.Env = os.Environ()
		_ = rm.Run()
	}
	return res, err
}

// execMarkerPrefix names the environment variable that marks an exec'd git process.
const execMarkerPrefix = "ACPCODE_EXEC="

// killExec kills the exec'd git process that carries marker in its environment, inside the agent
// container. It reads /proc only (procps is not in the image), and it is started without the
// marker, so it never matches itself. Best effort: a process that has already exited is no error.
func (r *appleRunner) killExec(name, marker string) {
	script := `for p in /proc/[0-9]*; do if grep -aq "ACPCODE_EXEC=$0" "$p/environ" 2>/dev/null; then kill -KILL "${p#/proc/}" 2>/dev/null; fi; done`
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, r.cli(), "exec", "-u", fmt.Sprintf("%d:%d", r.uid(), r.gid()), name, "sh", "-c", script, marker)
	cmd.Env = os.Environ()
	_ = cmd.Run()
}

func (r *appleRunner) uid() int {
	if r.cfg.Runner.ContainerUID == 0 {
		return config.DefaultContainerID
	}
	return r.cfg.Runner.ContainerUID
}

func (r *appleRunner) gid() int {
	if r.cfg.Runner.ContainerGID == 0 {
		return config.DefaultContainerID
	}
	return r.cfg.Runner.ContainerGID
}
