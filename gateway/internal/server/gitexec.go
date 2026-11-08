package server

// Git execution (PLAN 3.13, FR-28, D-008, D-034). Every git command the gateway runs goes through
// runner.exec, so with the podman runner it runs inside a short-lived container as the project
// user, never in the gateway process. Callers build the argument list; the client never supplies
// a command, a flag or an environment variable.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"acpcode/gateway/internal/store"
)

const (
	gitOutputCap = 2 << 20 // NFR-8: 2 MiB
	gitStderrCap = 64 << 10
)

// gitTimeout is NFR-8's 5 s; a variable only so a unit test can shorten it.
var gitTimeout = 5 * time.Second

var errGitTimeout = errors.New("git timeout")

// gitResult is the output of one git command.
type gitResult struct {
	Out       []byte
	Truncated bool // the output passed the cap; Out is the first gitOutputCap bytes
}

// gitFlags come before the subcommand (ARCHITECTURE 2.4). They stop git from running programs
// named in repository config (fsmonitor, hooks) and from taking optional locks or paging.
var gitFlags = []string{"--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"}

// gitEnv is the whole environment of a git command. No system config, no global config, no prompts.
func gitEnv(home string, extra []string) []string {
	env := []string{
		"PATH=/usr/local/bin:/usr/bin:/bin",
		"HOME=" + home,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_TERMINAL_PROMPT=0",
		"LC_ALL=C",
	}
	return append(env, extra...)
}

// gitCommand is the argument list for `git <flags> <args...>` in the project folder at path.
// safe.directory names exactly that folder: the project folder belongs to the owner, not to the
// container user, so git would refuse it ("dubious ownership"). The folder is the one the project
// container already works in (D-034).
func gitCommand(path string, args ...string) []string {
	argv := append([]string{"git"}, gitFlags...)
	argv = append(argv, "-c", "safe.directory="+path)
	return append(argv, args...)
}

// runGit runs git for a project with the safe flags. extraEnv holds gateway-built variables such
// as GIT_INDEX_FILE.
func (s *Server) runGit(ctx context.Context, p store.Project, extraEnv []string, stdin []byte, args ...string) (gitResult, error) {
	return s.runner.exec(ctx, p, s.projectHome(p.ID), gitCommand(p.Path, args...), extraEnv, stdin)
}

// runCapped runs cmd with the timeout and output cap. Output past the cap is dropped and the
// process is killed, with Truncated set. A timeout kills the process group and returns errGitTimeout.
// onKill functions run at each kill, before the output is drained: a process that a kill does not
// reach (see runner_apple.go) can keep the output open, so cleanup cannot wait for the return.
func runCapped(ctx context.Context, cmd *exec.Cmd, stdin []byte, onKill ...func()) (gitResult, error) {
	ctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdin = bytes.NewReader(stdin)
	var stderr limitedBuffer
	stderr.cap = gitStderrCap
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return gitResult{}, err
	}
	if err := cmd.Start(); err != nil {
		return gitResult{}, err
	}
	kill := func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		for _, f := range onKill {
			f()
		}
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			kill()
		case <-done:
		}
	}()
	out, readErr := io.ReadAll(io.LimitReader(stdout, gitOutputCap+1))
	res := gitResult{Out: out}
	if len(out) > gitOutputCap {
		res.Out, res.Truncated = out[:gitOutputCap], true
		kill()
		_, _ = io.Copy(io.Discard, stdout)
	}
	waitErr := cmd.Wait()
	close(done)
	if ctx.Err() != nil && !res.Truncated {
		return gitResult{}, errGitTimeout
	}
	if readErr != nil && !res.Truncated {
		return gitResult{}, readErr
	}
	if waitErr != nil && !res.Truncated {
		var exit *exec.ExitError
		if errors.As(waitErr, &exit) {
			return res, &gitExitError{Code: exit.ExitCode(), Stderr: stderr.String()}
		}
		return gitResult{}, waitErr
	}
	return res, nil
}

// gitExitError is a git command that ran and failed. Stderr stays on the gateway: callers log the
// code, not the text, because git messages can contain file names and content.
type gitExitError struct {
	Code   int
	Stderr string
}

func (e *gitExitError) Error() string { return "git exited with a failure" }

// limitedBuffer keeps at most cap bytes and drops the rest.
type limitedBuffer struct {
	buf bytes.Buffer
	cap int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := b.cap - b.buf.Len(); room > 0 {
		b.buf.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

func (b *limitedBuffer) String() string { return b.buf.String() }

// exec on the host runner (tests and development only, D-025): git runs as the gateway user in
// the project folder, with the project home as HOME.
func (r hostRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = p.Path
	cmd.Env = gitEnv(home, extraEnv)
	return runCapped(ctx, cmd, stdin)
}

// gitArgs is the podman command for one git run: a short-lived container with its own name (the
// agent's name is the project lock, D-015, and git never touches the task store), no network, the
// project folder and the project home mounted at their host paths, and the same image.
func (r podmanRunner) gitArgs(name string, p store.Project, home string, argv, extraEnv []string) []string {
	args := []string{"run", "--rm", "-i", "--name", name, "--pull=never", "--init", "--network=none"}
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

// maxContainerStarts is how many times one git command is tried when Podman fails to create its
// container (see containerNeverStarted).
const maxContainerStarts = 3

// containerNeverStarted reports a failure of Podman or the OCI runtime to set the container up:
// exit code 126 with an "OCI runtime error". Git never ran, so running the command again cannot
// repeat any effect. Seen live under Podman 5.6.2 on a Mac (RESULTS 2026-11-07): roughly 1 start in
// 25 failed with "write to /proc/sys/net/ipv4/ping_group_range ... Invalid argument" while several
// git containers started at once with --userns=keep-id.
func containerNeverStarted(err error) bool {
	var ee *gitExitError
	return errors.As(err, &ee) && ee.Code == 126 && strings.Contains(ee.Stderr, "OCI runtime error")
}

func (r podmanRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	var res gitResult
	var err error
	for attempt := 0; attempt < maxContainerStarts; attempt++ {
		res, err = r.execOnce(ctx, p, home, argv, extraEnv, stdin)
		if !containerNeverStarted(err) || ctx.Err() != nil {
			break
		}
	}
	return res, err
}

func (r podmanRunner) execOnce(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	if err := os.MkdirAll(home, 0o700); err != nil {
		return gitResult{}, err
	}
	var suffix [4]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return gitResult{}, err
	}
	name := "acpcode-git-" + p.ID + "-" + hex.EncodeToString(suffix[:])
	cmd := exec.Command(r.cfg.Runner.Podman, r.gitArgs(name, p, home, argv, extraEnv)...)
	cmd.Env = os.Environ()
	res, err := runCapped(ctx, cmd, stdin)
	if errors.Is(err, errGitTimeout) || res.Truncated {
		// Killing podman does not always stop the container: remove it by name.
		stop := exec.Command(r.cfg.Runner.Podman, "rm", "-f", "-t", "0", name)
		stop.Env = os.Environ()
		_ = stop.Run()
	}
	return res, err
}
