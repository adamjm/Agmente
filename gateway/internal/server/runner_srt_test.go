package server

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

// srtFixture is a project folder, a home and a state folder under one real temp dir.
type srtFixture struct {
	cfg     *config.Config
	runner  *srtRunner
	project store.Project
	home    string
	state   string
}

func newSRTFixture(t *testing.T, srt string) srtFixture {
	t.Helper()
	base, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(base, "projects")
	state := filepath.Join(base, "state")
	proj := filepath.Join(root, "alpha")
	for _, d := range []string{proj, filepath.Join(root, "beta"), state} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cfg := withRunner(&config.Config{
		Roots:    []string{root},
		StateDir: state,
		Runner:   config.Runner{Kind: "srt", SRT: srt},
	}, []string{"bob", "acp", "--accept-license"}, []string{"PATH", "HOME", "BOB_API_KEY"}, "")
	cfg.Runners[0].AllowedDomains = []string{"api.example.com", "*.cdn.example.com:443"}
	p := store.Project{ID: "0123456789ab", Path: proj}
	return srtFixture{cfg: cfg, runner: &srtRunner{cfg: cfg}, project: p, home: filepath.Join(state, "homes", p.ID), state: state}
}

func TestSRTRunnerIsChosenByKind(t *testing.T) {
	if _, ok := newRunner(&config.Config{Runner: config.Runner{Kind: "srt"}}).(*srtRunner); !ok {
		t.Fatal("kind srt did not give the srt runner")
	}
}

func TestSRTSettingsConfineTheProjectAndNothingElse(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	f.cfg.Runners[0].AllowRead = []string{"/opt/homebrew"}
	s := f.runner.settings(f.project, f.home, srtSpec{agent: true})

	if got := strings.Join(s.Network.AllowedDomains, " "); got != "*.cdn.example.com:443 api.example.com" {
		t.Errorf("allowedDomains = %q", got)
	}
	if s.Network.DeniedDomains == nil || s.Filesystem.DenyWrite == nil {
		t.Error("srt refuses a file with a missing key: deniedDomains and denyWrite must be present, even empty")
	}
	if got := strings.Join(s.Filesystem.AllowWrite, " "); got != strings.Join(uniq([]string{f.project.Path, f.home}), " ") {
		t.Errorf("allowWrite = %q: only this project and its home may be written", got)
	}
	for _, w := range s.Filesystem.AllowWrite {
		if strings.HasPrefix(w, filepath.Join(f.cfg.Roots[0], "beta")) {
			t.Errorf("a sibling project is writable: %q", w)
		}
	}
	deny := strings.Join(s.Filesystem.DenyRead, "\n")
	for _, want := range []string{f.cfg.Roots[0], f.state} {
		if !strings.Contains(deny, want) {
			t.Errorf("denyRead %q does not hold %s: another project's folder or the gateway state would be readable", deny, want)
		}
	}
	if home, err := os.UserHomeDir(); err == nil && !strings.Contains(deny, home) {
		t.Errorf("denyRead does not hold the user's home %s", home)
	}
	allow := strings.Join(s.Filesystem.AllowRead, " ")
	for _, want := range []string{f.project.Path, f.home, "/opt/homebrew"} {
		if !strings.Contains(allow, want) {
			t.Errorf("allowRead %q does not hold %s", allow, want)
		}
	}
	if s.Filesystem.AllowGitConfig {
		t.Error("the agent must not be able to write .git/config")
	}
	if s.EnableWeakerNetworkIsolation {
		t.Error("weaker network isolation is opt-in")
	}
}

func TestSRTGitAndPushSettings(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	f.cfg.GitHosts = []string{"github.com"}

	git := f.runner.settings(f.project, f.home, srtSpec{gitConfig: true})
	if len(git.Network.AllowedDomains) != 0 {
		t.Errorf("git has network: %v", git.Network.AllowedDomains)
	}
	if !git.Filesystem.AllowGitConfig {
		t.Error("the gateway's own git commands need .git/config (git remote add)")
	}

	push := f.runner.settings(f.project, f.home, srtSpec{gitConfig: true, domains: f.cfg.GitHosts, readOnly: []string{"/state/push-tmp/push-1"}})
	if strings.Join(push.Network.AllowedDomains, " ") != "github.com" {
		t.Errorf("push domains = %v, want the git hosts only", push.Network.AllowedDomains)
	}
	for _, w := range push.Filesystem.AllowWrite {
		if strings.Contains(w, "push-tmp") {
			t.Errorf("the push scratch folder is writable: %q", w)
		}
	}
	if !strings.Contains(strings.Join(push.Filesystem.AllowRead, " "), "/state/push-tmp/push-1") {
		t.Error("the askpass scratch folder is not readable")
	}
}

func TestSRTWeakerNetworkIsolationFollowsConfig(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	f.cfg.Runner.WeakerNetworkIsolation = true
	if !f.runner.settings(f.project, f.home, srtSpec{}).EnableWeakerNetworkIsolation {
		t.Fatal("the config option is ignored")
	}
}

func TestSRTLocalBindingIsForTheAgentOnly(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	agent := srtSpec{agent: true, localhost: true}
	if f.runner.settings(f.project, f.home, agent).Network.AllowLocalBinding {
		t.Fatal("local binding is on without the config key")
	}
	f.cfg.Runner.AllowLocalBinding = true
	if !f.runner.settings(f.project, f.home, agent).Network.AllowLocalBinding {
		t.Fatal("the config key is ignored for the agent")
	}
	if got := f.runner.settings(f.project, f.home, agent).Network.AllowedDomains; !strings.Contains(strings.Join(got, " "), "localhost") {
		t.Errorf("localhost is not allowed with local binding: %v", got)
	}
	f.cfg.Runner.AllowLocalBinding = false
	if got := f.runner.settings(f.project, f.home, agent).Network.AllowedDomains; strings.Contains(strings.Join(got, " "), "localhost") {
		t.Errorf("localhost is allowed without local binding: %v", got)
	}
	f.cfg.Runner.AllowLocalBinding = true
	for name, spec := range map[string]srtSpec{"git": {gitConfig: true}, "push": {gitConfig: true, domains: []string{"github.com"}}} {
		if f.runner.settings(f.project, f.home, spec).Network.AllowLocalBinding {
			t.Errorf("%s has local binding", name)
		}
	}
}

func TestSRTSettingsFileIsPrivateAndValidJSON(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	path, err := f.runner.writeSettings("x-agent", f.runner.settings(f.project, f.home, srtSpec{}))
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(path) != filepath.Join(f.state, "srt") {
		t.Fatalf("settings at %s: they belong in the state folder, which the agent cannot read", path)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("settings mode %v (%v), want 0600", st.Mode().Perm(), err)
	}
	dir, _ := os.Stat(filepath.Dir(path))
	if dir.Mode().Perm() != 0o700 {
		t.Fatalf("settings folder mode %v, want 0700", dir.Mode().Perm())
	}
	var back map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("settings are not JSON: %v", err)
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("a temp file was left behind: %s", e.Name())
		}
	}
}

func TestSRTCommandKeepsSecretsOutOfArgvAndSettings(t *testing.T) {
	f := newSRTFixture(t, "/opt/homebrew/bin/srt")
	cmd, path, err := f.runner.command(f.project, f.home, "x-agent", srtSpec{}, []string{"bob", "acp"},
		[]string{"PATH=/usr/bin:/bin", "HOME=" + f.home, "BOB_API_KEY=" + secretValue})
	if err != nil {
		t.Fatal(err)
	}
	if argvHasValue(cmd.Args) {
		t.Fatalf("a secret is in argv: %q", cmd.Args)
	}
	if v, ok := lastEnv(cmd.Env, "BOB_API_KEY"); !ok || v != secretValue {
		t.Fatalf("the secret does not reach the process through the environment: %q", v)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), secretValue) {
		t.Fatal("a secret is in the settings file")
	}
	got := strings.Join(cmd.Args, " ")
	want := " -- /usr/bin/env TMPDIR=" + filepath.Join(f.home, "tmp") + " CLAUDE_CODE_TMPDIR=" + filepath.Join(f.home, "tmp") + " NODE_USE_ENV_PROXY=1 PATH=/usr/bin:/bin /bin/sh -c cd \"$0\" && exec \"$@\" " + f.project.Path + " bob acp"
	if !strings.HasSuffix(got, want) {
		t.Fatalf("argv:\n %s\nwant it to contain\n %s", got, want)
	}
	if strings.Contains(got, "--trust") {
		t.Fatalf("the gateway adds no --trust (D-013): %s", got)
	}
	if h, _ := lastEnv(cmd.Env, "HOME"); h != f.home {
		t.Fatalf("HOME = %q, want the project home: it reaches the process through srt's environment", h)
	}
	if cmd.Dir != filepath.Dir(f.project.Path) {
		t.Fatalf("working directory %q, want the project's parent (srt anchors its .git denies there)", cmd.Dir)
	}
	// srt itself runs with the gateway's PATH (it needs node); the agent's PATH is the one the
	// environment wrapper sets, not the gateway's.
	if p, _ := lastEnv(cmd.Env, "PATH"); p != os.Getenv("PATH") {
		t.Fatalf("srt PATH = %q, want the gateway's", p)
	}
}

func TestSRTStartRefusesAnUnreadableSecretsFileBeforeLocking(t *testing.T) {
	f := newSRTFixture(t, "/bin/true")
	path := filepath.Join(t.TempDir(), "agent.env")
	if err := os.WriteFile(path, []byte("BOB_API_KEY=x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	f.cfg.Runners[0].SecretsFile, f.cfg.Runners[0].SecretNames = path, []string{"BOB_API_KEY"}
	if _, err := f.runner.start(f.project, f.home); !errors.Is(err, errSecrets) {
		t.Fatalf("start: %v", err)
	}
	lock, err := lockHome(f.home, lockRunner(f.project))
	if err != nil {
		t.Fatalf("the home is locked after a refused start: %v", err)
	}
	lock.Close()
}

// fakeSRT is a shell script that records its arguments and then runs the command after `--` the
// way srt does, so the runner's lifecycle can be tested without the real sandbox.
func fakeSRT(t *testing.T) (bin, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	bin, argsFile = filepath.Join(dir, "srt"), filepath.Join(dir, "args")
	script := `#!/bin/sh
echo "$@" > ` + argsFile + `
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, argsFile
}

func TestSRTStartHoldsTheProjectLock(t *testing.T) {
	bin, _ := fakeSRT(t)
	f := newSRTFixture(t, bin)
	f.cfg.Runners[0].Command = []string{"sleep", "30"}
	proc, err := f.runner.start(f.project, f.home)
	if err != nil {
		t.Fatal(err)
	}
	defer proc.terminate(0)
	if _, err := f.runner.start(f.project, f.home); !errors.Is(err, errProjectLocked) {
		t.Fatalf("a second start while the first runs: %v, want errProjectLocked", err)
	}
}

func TestSRTTerminateKillsTheWholeProcessGroup(t *testing.T) {
	bin, _ := fakeSRT(t)
	f := newSRTFixture(t, bin)
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	f.cfg.Runners[0].Command = []string{"sh", "-c", "sleep 60 & echo $! > " + pidFile + "; wait"}
	proc, err := f.runner.start(f.project, f.home)
	if err != nil {
		t.Fatal(err)
	}
	var child int
	for i := 0; i < 100 && child == 0; i++ {
		if b, err := os.ReadFile(pidFile); err == nil {
			child = atoi(strings.TrimSpace(string(b)))
		}
		time.Sleep(20 * time.Millisecond)
	}
	if child == 0 {
		t.Fatal("the agent's child never started")
	}
	proc.terminate(time.Second)
	select {
	case <-proc.exited:
	case <-time.After(5 * time.Second):
		t.Fatal("the agent did not exit")
	}
	for i := 0; i < 100; i++ {
		if err := syscall.Kill(child, 0); err != nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the agent's child %d is still running after terminate", child)
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func TestSRTExecRunsGitWithTheGitEnvironmentOnly(t *testing.T) {
	bin, _ := fakeSRT(t)
	f := newSRTFixture(t, bin)
	t.Setenv("BOB_API_KEY", "must-not-appear")
	res, err := f.runner.exec(context.Background(), f.project, f.home, []string{"env"}, []string{"GIT_INDEX_FILE=/x"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	out := string(res.Out)
	if strings.Contains(out, "must-not-appear") || strings.Contains(out, "BOB_API_KEY") {
		t.Fatalf("git got the agent's environment:\n%s", out)
	}
	for _, want := range []string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_INDEX_FILE=/x", "NODE_USE_ENV_PROXY=1", "HOME=" + f.home} {
		if !strings.Contains(out, want) {
			t.Errorf("git environment lacks %s:\n%s", want, out)
		}
	}
}

func TestSRTExecTimeoutKillsTheProcessGroup(t *testing.T) {
	bin, _ := fakeSRT(t)
	f := newSRTFixture(t, bin)
	pidFile := filepath.Join(t.TempDir(), "pid")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// The deadline is a cancel that waits for the child to exist, so the test does not depend on
	// how long the settings and the process take to start.
	go func() {
		for i := 0; i < 500; i++ {
			if b, err := os.ReadFile(pidFile); err == nil && strings.TrimSpace(string(b)) != "" {
				cancel()
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		cancel()
	}()
	_, err := f.runner.exec(ctx, f.project, f.home, []string{"sh", "-c", "sleep 30 & echo $! > " + pidFile + "; wait"}, nil, nil)
	if !errors.Is(err, errGitTimeout) {
		t.Fatalf("exec: %v, want errGitTimeout", err)
	}
	b, _ := os.ReadFile(pidFile)
	child := atoi(strings.TrimSpace(string(b)))
	if child == 0 {
		t.Fatal("no child pid")
	}
	for i := 0; i < 100; i++ {
		if syscall.Kill(child, 0) != nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("child %d survived the timeout", child)
}

func TestSRTOneOffGivesNetworkOnlyToTheGitHostsAndKeepsTheTokenOutOfArgv(t *testing.T) {
	bin, argsFile := fakeSRT(t)
	f := newSRTFixture(t, bin)
	f.cfg.GitHosts = []string{"github.com"}
	scratch := filepath.Join(f.state, "push-tmp", "push-1")
	if err := os.MkdirAll(scratch, 0o700); err != nil {
		t.Fatal(err)
	}
	res, err := f.runner.oneOff(context.Background(), f.project, f.home, oneOffCmd{
		argv:    []string{"sh", "-c", `echo "token=$ACPCODE_GIT_TOKEN"`},
		secrets: []string{tokenEnv + "=" + secretValue},
		mounts:  []string{scratch},
		network: true,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(res.Out), "token="+secretValue) {
		t.Fatalf("the push command did not get the token in its environment: %q", res.Out)
	}
	args, _ := os.ReadFile(argsFile)
	if strings.Contains(string(args), secretValue) {
		t.Fatal("the token is in argv")
	}
	settingsPath := strings.Fields(string(args))[1]
	if _, err := os.Stat(settingsPath); err == nil {
		t.Errorf("the push settings file %s was not removed", settingsPath)
	}
	if left, _ := filepath.Glob(filepath.Join(f.state, "srt", "*push*")); len(left) != 0 {
		t.Errorf("push settings left behind: %v", left)
	}
}

// --- live tests: the real srt. Run with ACPCODE_TEST_SRT=/path/to/srt (npm i -g @anthropic-ai/sandbox-runtime).

func liveSRT(t *testing.T) srtFixture {
	t.Helper()
	bin := os.Getenv("ACPCODE_TEST_SRT")
	if bin == "" {
		t.Skip("set ACPCODE_TEST_SRT to the srt command to run the live sandbox tests")
	}
	f := newSRTFixture(t, bin)
	f.cfg.Runners[0].AllowedDomains = []string{"example.com"}
	return f
}

// sandboxed runs script in the project's sandbox through exec (no network, git environment).
func (f srtFixture) sandboxed(t *testing.T, script string) (string, error) {
	t.Helper()
	res, err := f.runner.exec(context.Background(), f.project, f.home, []string{"sh", "-c", script}, nil, nil)
	return string(res.Out), err
}

func TestLiveSRTConfinesFilesystemAndSignals(t *testing.T) {
	f := liveSRT(t)
	other := filepath.Join(f.cfg.Roots[0], "beta", "secret.txt")
	mustWrite(t, other, "beta-secret")
	mustWrite(t, filepath.Join(f.project.Path, "a.txt"), "alpha")
	mustWrite(t, filepath.Join(f.state, "gateway.db"), "state-secret")
	outside := filepath.Join(filepath.Dir(f.cfg.Roots[0]), "outside.txt")

	out, err := f.sandboxed(t, `
cat a.txt && echo READ_OWN_OK
cat `+other+` 2>/dev/null || echo SIBLING_DENIED
cat `+filepath.Join(f.state, "gateway.db")+` 2>/dev/null || echo STATE_DENIED
ls ~/.ssh 2>/dev/null || echo HOME_DENIED
echo x > b.txt && echo WRITE_OWN_OK
echo x > `+outside+` 2>/dev/null || echo WRITE_OUTSIDE_DENIED
echo x > `+filepath.Join(f.cfg.Roots[0], "beta", "w.txt")+` 2>/dev/null || echo WRITE_SIBLING_DENIED
echo x > `+filepath.Join(f.home, "h.txt")+` && echo WRITE_HOME_OK
echo $TMPDIR
ls /tmp/claude 2>/dev/null; ls /private/tmp 2>/dev/null | head -1 || true
`)
	if err != nil {
		t.Fatalf("exec: %v\n%s", err, out)
	}
	for _, want := range []string{"READ_OWN_OK", "SIBLING_DENIED", "STATE_DENIED", "HOME_DENIED", "WRITE_OWN_OK", "WRITE_OUTSIDE_DENIED", "WRITE_SIBLING_DENIED", "WRITE_HOME_OK", filepath.Join(f.home, "tmp")} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "beta-secret") || strings.Contains(out, "state-secret") {
		t.Errorf("a secret was readable:\n%s", out)
	}
	if _, err := os.Stat(outside); err == nil {
		t.Error("a file was written outside the project")
	}
}

func TestLiveSRTBlocksNetworkAndSignalsForGit(t *testing.T) {
	f := liveSRT(t)
	victim := exec.Command("sleep", "60")
	if err := victim.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = victim.Process.Kill(); _, _ = victim.Process.Wait() }()
	out, _ := f.sandboxed(t, `
curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null && echo NET_OPEN || echo NET_DENIED
kill -9 `+strconv.Itoa(victim.Process.Pid)+` 2>/dev/null && echo KILLED || echo KILL_DENIED
`)
	if !strings.Contains(out, "NET_DENIED") || strings.Contains(out, "NET_OPEN") {
		t.Errorf("git has network:\n%s", out)
	}
	if !strings.Contains(out, "KILL_DENIED") {
		t.Errorf("the sandbox could signal a host process:\n%s", out)
	}
	if syscall.Kill(victim.Process.Pid, 0) != nil {
		t.Error("the host process died")
	}
}

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLiveSRTGitInitStatusAndHooks(t *testing.T) {
	f := liveSRT(t)
	s := &Server{runner: f.runner, cfg: f.cfg}
	// Project creation: git init and remote add work, and no hook is installed.
	if _, rerr := s.gitInitFolder(context.Background(), f.project, gitOptions{init: true, remote: "https://github.com/owner/repo.git"}); rerr != nil {
		t.Fatalf("git init in the sandbox: %+v", rerr)
	}
	for _, want := range []string{".git/HEAD", ".git/config"} {
		if _, err := os.Stat(filepath.Join(f.project.Path, want)); err != nil {
			t.Errorf("%s missing: %v", want, err)
		}
	}
	if entries, _ := os.ReadDir(filepath.Join(f.project.Path, ".git", "hooks")); len(entries) != 0 {
		t.Errorf("git init installed %d sample hooks", len(entries))
	}
	mustWrite(t, filepath.Join(f.project.Path, "a.txt"), "x")
	res, err := s.runGit(context.Background(), f.project, nil, nil, "status", "--porcelain=v2", "-z")
	if err != nil || !strings.Contains(string(res.Out), "a.txt") {
		t.Fatalf("git status in the sandbox: %v %q", err, res.Out)
	}
	// The agent's own sandbox cannot write a hook or the repository config.
	cmd, _, err := f.runner.command(f.project, f.home, "agent-probe", srtSpec{}, []string{"sh", "-c",
		`mkdir -p .git/hooks 2>/dev/null; echo x > .git/hooks/pre-commit 2>/dev/null && echo HOOK_WRITTEN || echo HOOK_DENIED
echo x >> .git/config 2>/dev/null && echo CONFIG_WRITTEN || echo CONFIG_DENIED`}, gitEnv(f.home, nil))
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("probe: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "HOOK_DENIED") || strings.Contains(string(out), "HOOK_WRITTEN") {
		t.Errorf("the agent could write a git hook:\n%s", out)
	}
	if !strings.Contains(string(out), "CONFIG_DENIED") || strings.Contains(string(out), "CONFIG_WRITTEN") {
		t.Errorf("the agent could write .git/config:\n%s", out)
	}
}

func TestSRTLaunchGateSpacesCloseLaunches(t *testing.T) {
	old := srtLaunchGap
	srtLaunchGap = 60 * time.Millisecond
	defer func() { srtLaunchGap = old }()
	srtLaunchGate() // the first call may wait for an earlier test's launch; start the clock after it
	start := time.Now()
	var wg sync.WaitGroup
	var mu sync.Mutex
	var times []time.Duration
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			srtLaunchGate()
			mu.Lock()
			times = append(times, time.Since(start))
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	for i := 1; i < len(times); i++ {
		if times[i]-times[i-1] < 50*time.Millisecond {
			t.Errorf("launches %d and %d were %s apart, want at least 60ms: %v", i-1, i, times[i]-times[i-1], times)
		}
	}
}
