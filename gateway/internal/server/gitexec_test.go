package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

func gitTestServer(t *testing.T) (*Server, store.Project) {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	proj := filepath.Join(dir, "repo")
	if err := os.Mkdir(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{StateDir: filepath.Join(dir, "state")}
	return &Server{runner: hostRunner{cfg: cfg}, cfg: cfg}, store.Project{ID: "0123456789ab", Path: proj}
}

func mustGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func writeScript(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

// hostileRepo has a committed file that is then modified, and config that would run a program
// from fsmonitor, an external diff driver and a textconv driver (T-26). Each program creates its
// own marker file in markers.
func hostileRepo(t *testing.T, proj string) (markers string) {
	t.Helper()
	markers = t.TempDir()
	mustGit(t, proj, "init", "-q")
	if err := os.WriteFile(filepath.Join(proj, "a.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".gitattributes"), []byte("*.txt diff=evil\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, proj, "add", ".")
	mustGit(t, proj, "commit", "-q", "-m", "one")
	if err := os.WriteFile(filepath.Join(proj, "a.txt"), []byte("two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"fsmonitor": "touch " + markers + "/fsmonitor; printf '\\0'",
		"external":  "touch " + markers + "/external",
		"textconv":  "touch " + markers + "/textconv; cat \"$1\"",
	} {
		writeScript(t, filepath.Join(markers, name+".sh"), body)
	}
	mustGit(t, proj, "config", "core.fsmonitor", markers+"/fsmonitor.sh")
	mustGit(t, proj, "config", "diff.external", markers+"/external.sh")
	mustGit(t, proj, "config", "diff.evil.textconv", markers+"/textconv.sh")
	return markers
}

func markerNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, _ := os.ReadDir(dir)
	var out []string
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".sh") {
			out = append(out, e.Name())
		}
	}
	return out
}

// T-26: the same hostile repo runs all three programs under plain git (so the repo really is
// hostile), and none of them under the gateway's flags.
func TestHostileRepoRunsNothingUnderTheSafeFlags(t *testing.T) {
	s, p := gitTestServer(t)
	markers := hostileRepo(t, p.Path)

	for _, args := range [][]string{{"status", "--porcelain=v2", "--branch", "-z"}, {"diff", "--no-ext-diff", "--no-textconv", "--", "a.txt"}} {
		res, err := s.runGit(context.Background(), p, nil, nil, args...)
		if err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
		if args[0] == "diff" && !strings.Contains(string(res.Out), "+two") {
			t.Fatalf("diff output: %q", res.Out)
		}
	}
	if got := markerNames(t, markers); len(got) != 0 {
		t.Fatalf("a repository program ran: %v", got)
	}

	// Control: plain git, same repo.
	for _, args := range [][]string{{"status"}, {"diff", "--ext-diff", "a.txt"}, {"diff", "--no-ext-diff", "--textconv", "a.txt"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = p.Path
		_ = cmd.Run()
	}
	if got := markerNames(t, markers); len(got) != 3 {
		t.Fatalf("control: expected all three markers from plain git, got %v", got)
	}
}

func TestGitEnvironmentIsExactlyTheAllowList(t *testing.T) {
	s, p := gitTestServer(t)
	t.Setenv("BOB_API_KEY", "must-not-appear")
	res, err := s.runner.exec(context.Background(), p, s.projectHome(p.ID), []string{"env"}, []string{"GIT_INDEX_FILE=/x"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(res.Out), "must-not-appear") {
		t.Fatal("a gateway secret reached git")
	}
	var names []string
	for _, l := range strings.Split(strings.TrimSpace(string(res.Out)), "\n") {
		names = append(names, strings.SplitN(l, "=", 2)[0])
	}
	want := "PATH HOME GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT LC_ALL GIT_INDEX_FILE"
	if strings.Join(names, " ") != want {
		t.Fatalf("env names: %v", names)
	}
}

func TestGitTimeoutKillsTheProcessGroup(t *testing.T) {
	s, p := gitTestServer(t)
	old := gitTimeout
	gitTimeout = 300 * time.Millisecond
	defer func() { gitTimeout = old }()
	pidFile := filepath.Join(t.TempDir(), "pid")
	t0 := time.Now()
	_, err := s.runner.exec(context.Background(), p, s.projectHome(p.ID), []string{"sh", "-c", "sleep 30 & echo $! > " + pidFile + "; wait"}, nil, nil)
	if !errors.Is(err, errGitTimeout) {
		t.Fatalf("err: %v", err)
	}
	if time.Since(t0) > 3*time.Second {
		t.Fatalf("took %v", time.Since(t0))
	}
	pid, _ := os.ReadFile(pidFile)
	time.Sleep(100 * time.Millisecond)
	if err := exec.Command("kill", "-0", strings.TrimSpace(string(pid))).Run(); err == nil {
		t.Fatal("the child of the killed command is still running")
	}
}

func TestGitOutputIsCappedAndTheProcessStops(t *testing.T) {
	s, p := gitTestServer(t)
	t0 := time.Now()
	res, err := s.runner.exec(context.Background(), p, s.projectHome(p.ID), []string{"yes"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Truncated || len(res.Out) != gitOutputCap {
		t.Fatalf("truncated=%v len=%d", res.Truncated, len(res.Out))
	}
	if time.Since(t0) > 3*time.Second {
		t.Fatalf("took %v", time.Since(t0))
	}
	res, err = s.runner.exec(context.Background(), p, s.projectHome(p.ID), []string{"head", "-c", "100", "/dev/zero"}, nil, nil)
	if err != nil || res.Truncated || len(res.Out) != 100 {
		t.Fatalf("small output: %v %v %d", err, res.Truncated, len(res.Out))
	}
}

func TestGitFailureKeepsStderrOffTheError(t *testing.T) {
	s, p := gitTestServer(t) // not a repository
	_, err := s.runGit(context.Background(), p, nil, nil, "status")
	var ee *gitExitError
	if !errors.As(err, &ee) || ee.Code == 0 {
		t.Fatalf("err: %v", err)
	}
	if ee.Stderr == "" || strings.Contains(err.Error(), ee.Stderr) {
		t.Fatalf("stderr %q, message %q", ee.Stderr, err.Error())
	}
}

func TestPodmanGitArgs(t *testing.T) {
	cfg := withRunner(&config.Config{Runner: config.Runner{Kind: "podman", Podman: "podman"}}, nil, nil, "img:1")
	t.Setenv("BOB_API_KEY", "must-not-appear")
	args := strings.Join(podmanRunner{cfg: cfg}.gitArgs("acpcode-git-x", store.Project{ID: "p", Path: "/srv/p"}, "/h", gitCommand("/srv/p", "status"), []string{"GIT_INDEX_FILE=/h/i"}), " ")
	for _, want := range []string{"run --rm -i --name acpcode-git-x --pull=never --init --network=none --userns=keep-id:uid=10001,gid=10001 --user 10001:10001", "-v /h:/h -v /srv/p:/srv/p -w /srv/p", "-e GIT_CONFIG_NOSYSTEM=1", "-e GIT_INDEX_FILE=/h/i", "--entrypoint git img:1 --no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.directory=/srv/p status"} {
		if !strings.Contains(args, want) {
			t.Errorf("missing %q in:\n%s", want, args)
		}
	}
	if strings.Contains(args, "must-not-appear") || strings.Contains(args, "BOB_API_KEY") {
		t.Fatal("a secret reached the git container")
	}
	if strings.Contains(args, "--name acpcode-0") {
		t.Fatal("git must not take the agent's lock name")
	}
}

// T-27: a repository with a clean filter. The filter runs when git status compares a changed file,
// so a git that ran on the host would create the marker on the host. Needs Podman and the image;
// it is skipped, with the reason, where either is missing.
func TestCleanFilterRunsOnlyInsideTheContainer(t *testing.T) {
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skip("T-27 skipped: podman is not installed")
	}
	image := os.Getenv("ACPCODE_TEST_IMAGE")
	if image == "" {
		image = "localhost/acpcode-bob:2.0.9"
	}
	if exec.Command(podman, "image", "exists", image).Run() != nil {
		t.Skipf("T-27 skipped: image %s is not available (set ACPCODE_TEST_IMAGE)", image)
	}
	s, p := gitTestServer(t)
	s.cfg.Runner = config.Runner{Kind: "podman", Podman: podman}
	withRunner(s.cfg, nil, nil, image)
	s.runner = podmanRunner{cfg: s.cfg}
	if err := os.Chmod(p.Path, 0o777); err != nil {
		t.Fatal(err)
	}
	markers := t.TempDir()
	hostMarker := filepath.Join(markers, "ran")
	mustGit(t, p.Path, "init", "-q")
	file := filepath.Join(p.Path, "a.txt")
	_ = os.WriteFile(file, []byte("one\n"), 0o644)
	_ = os.WriteFile(filepath.Join(p.Path, ".gitattributes"), []byte("*.txt filter=evil\n"), 0o644)
	mustGit(t, p.Path, "add", ".")
	mustGit(t, p.Path, "commit", "-q", "-m", "one")
	// Same size as "one\n", so git cannot tell from the size alone and must run the clean filter.
	_ = os.WriteFile(file, []byte("two\n"), 0o644)
	// The filter fails (required) after touching a marker at a fixed path; inside the container
	// that path is the container's own, so the host path below never appears.
	filter := "touch " + hostMarker + " /tmp/acpcode-marker; false"
	mustGit(t, p.Path, "config", "filter.evil.clean", filter)
	mustGit(t, p.Path, "config", "filter.evil.required", "true")

	_, err = s.runGit(context.Background(), p, nil, nil, "status", "--porcelain=v2", "-z")
	var ee *gitExitError
	if !errors.As(err, &ee) {
		t.Fatalf("the filter did not run in the container (status err: %v)", err)
	}
	if strings.Contains(ee.Stderr, "dubious ownership") {
		t.Fatalf("git refused the repository instead of running the filter: %s", ee.Stderr)
	}
	if _, err := os.Stat(hostMarker); err == nil {
		t.Fatal("the marker appeared on the host")
	}

	// Control: the same repo under the host runner runs the filter on the host.
	h := &Server{runner: hostRunner{cfg: s.cfg}, cfg: s.cfg}
	_, herr := h.runGit(context.Background(), p, nil, nil, "status", "--porcelain=v2", "-z")
	if !errors.As(herr, new(*gitExitError)) {
		t.Fatalf("control: the host run should fail on the required filter: %v", herr)
	}
	if _, err := os.Stat(hostMarker); err != nil {
		t.Fatalf("control: the host runner did not run the filter: %v", err)
	}
}

// fakePodman writes a podman stand-in that fails the first `failures` calls like a container that
// could not be created, then prints "ok". It counts its calls in a file.
func fakePodman(t *testing.T, failures int, stderr string, code int) (path, counter string) {
	t.Helper()
	dir := t.TempDir()
	counter = filepath.Join(dir, "calls")
	path = filepath.Join(dir, "podman")
	script := fmt.Sprintf("#!/bin/sh\necho x >> %q\nn=$(wc -l < %q)\nif [ \"$n\" -le %d ]; then echo %q >&2; exit %d; fi\necho ok\n", counter, counter, failures, stderr, code)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path, counter
}

func podmanGitRun(t *testing.T, failures int, stderr string, code int) (gitResult, error, int) {
	t.Helper()
	bin, counter := fakePodman(t, failures, stderr, code)
	r := podmanRunner{cfg: withRunner(&config.Config{Runner: config.Runner{Kind: "podman", Podman: bin}}, nil, nil, "img:1")}
	proj := t.TempDir()
	res, err := r.exec(context.Background(), store.Project{ID: "p", Path: proj}, filepath.Join(t.TempDir(), "home"), gitCommand(proj, "status"), nil, nil)
	data, _ := os.ReadFile(counter)
	return res, err, strings.Count(string(data), "x")
}

const ociFailure = "Error: preparing container abc for attach: crun: write to `/proc/sys/net/ipv4/ping_group_range`: Invalid argument: OCI runtime error"

func TestAContainerThatNeverStartedIsTriedAgain(t *testing.T) {
	res, err, calls := podmanGitRun(t, 2, ociFailure, 126)
	if err != nil || strings.TrimSpace(string(res.Out)) != "ok" || calls != 3 {
		t.Fatalf("res %q, err %v, calls %d", res.Out, err, calls)
	}
}

func TestStartRetriesStopAfterThreeTries(t *testing.T) {
	_, err, calls := podmanGitRun(t, 99, ociFailure, 126)
	if !containerNeverStarted(err) || calls != maxContainerStarts {
		t.Fatalf("err %v, calls %d", err, calls)
	}
}

func TestOtherFailuresAreNeverRetried(t *testing.T) {
	for name, c := range map[string]struct {
		stderr string
		code   int
	}{
		"git failed":                 {"fatal: not a git repository", 128},
		"126 without the OCI text":   {"permission denied", 126},
		"OCI text with another code": {ociFailure, 1},
	} {
		_, err, calls := podmanGitRun(t, 99, c.stderr, c.code)
		if err == nil || calls != 1 {
			t.Errorf("%s: err %v, calls %d (want one call)", name, err, calls)
		}
	}
}
