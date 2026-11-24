package server

// srt runner (D-122): the agent, git and the push commands run as processes under Anthropic
// sandbox-runtime (`srt`), the macOS Seatbelt or Linux bubblewrap sandbox, instead of in a
// container. Same contract as the other runners: one agent per project with its HOME set to the
// project home, git only through the gateway's own commands, the push path in its own process.
//
// What this is not: a VM. The sandboxed process is the gateway user, on the gateway's kernel; the
// settings file is the only boundary (D-122). The settings are built here from the config and the
// project, written under <stateDir>/srt (denied to the agent), and read by srt at its start.
//
//   - Reads: the gateway user's home, the project roots, the state folder and the temp areas are
//     denied; this project's folder and its home are allowed back. runner.allowRead adds paths
//     (for toolchains under the user's home).
//   - Writes: this project's folder and its home. TMPDIR is <home>/tmp: srt would otherwise point
//     it at /tmp/claude, which every sandbox shares.
//   - Network: runner.allowedDomains for the agent; none for git; the git hosts for a push.
//   - .git/hooks is never writable (srt's own rule). .git/config is writable only for the commands
//     the gateway builds (git init, remote add, the push neutralizer), never for the agent.
//   - Node ignores proxy variables unless NODE_USE_ENV_PROXY=1 (Node 22.21 or later), so it is set.
//   - The process group is the unit: srt starts proxies and the command as children, and killing
//     srt alone leaves them running.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/store"
)

type srtRunner struct{ cfg *config.Config }

// srtSettings is srt's settings file. Every key srt requires is present, because srt refuses a
// file with a missing key rather than using a default.
type srtSettings struct {
	Network struct {
		AllowedDomains []string `json:"allowedDomains"`
		DeniedDomains  []string `json:"deniedDomains"`
		// AllowLocalBinding is srt's flag for connecting to localhost and binding local ports.
		AllowLocalBinding bool `json:"allowLocalBinding,omitempty"`
	} `json:"network"`
	Filesystem struct {
		DenyRead       []string `json:"denyRead"`
		AllowRead      []string `json:"allowRead"`
		AllowWrite     []string `json:"allowWrite"`
		DenyWrite      []string `json:"denyWrite"`
		AllowGitConfig bool     `json:"allowGitConfig,omitempty"`
	} `json:"filesystem"`
	EnableWeakerNetworkIsolation bool `json:"enableWeakerNetworkIsolation,omitempty"`
}

// srtSpec is what differs between the agent, git and a push command.
type srtSpec struct {
	domains   []string // hosts the process may reach
	gitConfig bool     // may write .git/config (never .git/hooks)
	localhost bool     // may use localhost ports (the agent only, when configured)
	readOnly  []string // extra paths it may read (the push scratch folder)
}

// pathForms is p and, when it differs, p with symbolic links followed. Seatbelt judges the real
// path; the configured one is kept too.
func pathForms(p string) []string {
	out := []string{filepath.Clean(p)}
	if r, err := filepath.EvalSymlinks(p); err == nil && r != out[0] {
		out = append(out, r)
	}
	return out
}

// uniq returns the strings once each, in a stable order.
func uniq(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

// denyRegions are the places the agent must not read unless a path inside is allowed back: the
// gateway user's home, every project root, the state folder (homes, database, push scratch,
// these settings) and the shared temp areas. Only paths that exist are listed.
func (r *srtRunner) denyRegions() []string {
	var all []string
	if h, err := os.UserHomeDir(); err == nil {
		all = append(all, h)
	}
	all = append(all, r.cfg.Roots...)
	all = append(all, r.cfg.StateDir, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
	var out []string
	for _, p := range all {
		if p == "" {
			continue
		}
		for _, f := range pathForms(p) {
			if _, err := os.Stat(f); err == nil {
				out = append(out, f)
			}
		}
	}
	return uniq(out)
}

// settings builds the settings for one process of project p.
func (r *srtRunner) settings(p store.Project, home string, spec srtSpec) srtSettings {
	var s srtSettings
	domains := spec.domains
	if spec.localhost && r.cfg.Runner.AllowLocalBinding {
		// Bob's HTTP client sends even a loopback request through srt's proxy, which refuses a
		// host that is not listed. An MCP URL must use the name localhost (config refuses IP literals).
		domains = append(append([]string{}, domains...), "localhost")
	}
	s.Network.AllowedDomains = uniq(domains)
	s.Network.DeniedDomains = []string{}
	s.Network.AllowLocalBinding = spec.localhost && r.cfg.Runner.AllowLocalBinding
	s.Filesystem.DenyRead = r.denyRegions()
	var allow []string
	for _, a := range append([]string{p.Path, home}, append(spec.readOnly, r.cfg.Runner.AllowRead...)...) {
		allow = append(allow, pathForms(a)...)
	}
	s.Filesystem.AllowRead = uniq(allow)
	var write []string
	for _, w := range []string{p.Path, home} {
		write = append(write, pathForms(w)...)
	}
	s.Filesystem.AllowWrite = uniq(write)
	s.Filesystem.DenyWrite = []string{}
	s.Filesystem.AllowGitConfig = spec.gitConfig
	s.EnableWeakerNetworkIsolation = r.cfg.Runner.WeakerNetworkIsolation
	return s
}

// settingsDir is where the gateway keeps the settings files. The agent cannot read it (it lies in
// the state folder) and cannot write it.
func (r *srtRunner) settingsDir() string { return filepath.Join(r.cfg.StateDir, "srt") }

// writeSettings writes the settings atomically to <settingsDir>/<name>.json and returns the path.
func (r *srtRunner) writeSettings(name string, s srtSettings) (string, error) {
	dir := r.settingsDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, name+"-*.tmp")
	if err != nil {
		return "", err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return "", err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	path := filepath.Join(dir, name+".json")
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	return path, nil
}

// command builds the srt command for argv. env is the environment the sandboxed process gets: it
// reaches srt in cmd.Env and passes through to the process, so no value is in argv. srt itself
// needs the gateway's PATH to find node; the process gets env's PATH through the env wrapper.
// TMPDIR is overridden here because srt would set /tmp/claude, shared by every sandbox.
//
// srt anchors its .git/hooks and .git/config denies at its own working directory and pins a
// literal <cwd>/.git, so with the project as the cwd `git init` could not create .git. srt runs in
// the project's parent instead (its globs reach <project>/.git/hooks there) and a shell enters the
// project inside the sandbox.
func (r *srtRunner) command(p store.Project, home, settingsName string, spec srtSpec, argv, env []string) (*exec.Cmd, string, error) {
	srtLaunchGate()
	if err := os.MkdirAll(filepath.Join(home, "tmp"), 0o700); err != nil {
		return nil, "", err
	}
	path, err := r.writeSettings(settingsName, r.settings(p, home, spec))
	if err != nil {
		return nil, "", err
	}
	wrapper := []string{"/usr/bin/env", "TMPDIR=" + filepath.Join(home, "tmp"), "NODE_USE_ENV_PROXY=1"}
	srtEnv := []string{"PATH=" + os.Getenv("PATH")}
	for _, kv := range env {
		if len(kv) >= 5 && kv[:5] == "PATH=" {
			wrapper = append(wrapper, kv)
			continue
		}
		srtEnv = append(srtEnv, kv)
	}
	wrapper = append(wrapper, "/bin/sh", "-c", `cd "$0" && exec "$@"`, p.Path)
	args := append([]string{"-s", path, "--"}, wrapper...)
	cmd := exec.Command(r.cfg.Runner.SRT, append(args, argv...)...)
	cmd.Dir = filepath.Dir(p.Path)
	cmd.Env = srtEnv
	return cmd, path, nil
}

// srt finds the shell with `which` and a 1 s timeout. Eight srt processes starting at the same
// moment make that lookup time out in about one run in two ("Shell 'bash' not found in PATH") and
// the agent dies at start. Starts at least srtLaunchGap apart did not fail in 6 runs of 8
// (RESULTS 2026-11-22, item 5); the gate costs nothing when launches are not close together.
var (
	srtLaunchMu   sync.Mutex
	srtLaunchLast time.Time
	srtLaunchGap  = 250 * time.Millisecond
)

func srtLaunchGate() {
	srtLaunchMu.Lock()
	defer srtLaunchMu.Unlock()
	if wait := srtLaunchGap - time.Since(srtLaunchLast); wait > 0 {
		time.Sleep(wait)
	}
	srtLaunchLast = time.Now()
}

func (r *srtRunner) start(p store.Project, home string) (*agentProcess, error) {
	secrets, err := secretEnv(r.cfg)
	if err != nil {
		return nil, err
	}
	a, err := agentFor(r.cfg, p)
	if err != nil {
		return nil, err
	}
	lock, err := lockHome(home)
	if err != nil {
		return nil, err
	}
	// A marker left by a run that did not end cleanly (the gateway was killed) means commands of
	// that run may still be alive; the lock is ours, so no agent of this project is. Kill them.
	marker := filepath.Join(home, ".acpcode.running")
	if _, err := os.Stat(marker); err == nil {
		reapOrphans(pathForms(p.Path))
	}
	token := []byte(strconv.Itoa(os.Getpid()) + "-" + strconv.FormatInt(time.Now().UnixNano(), 10))
	_ = os.WriteFile(marker, token, 0o600)
	env := append(agentEnv(a.EnvPassthrough, home), secrets...) // a later entry wins for a duplicate name
	cmd, _, err := r.command(p, home, p.ID+"-agent", srtSpec{domains: r.cfg.Runner.AllowedDomains, localhost: true}, a.Command, env)
	if err != nil {
		lock.Close()
		return nil, err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	proc, err := startProcess(cmd, []*os.File{lock})
	if err != nil {
		lock.Close()
		return nil, fmt.Errorf("srt: %w", err)
	}
	proc.lock = lock
	go func() {
		// A clean end leaves no marker. If commands outlived the agent (it died on its own), the
		// marker stays and the next start reaps them.
		<-proc.exited
		time.Sleep(500 * time.Millisecond)
		if got, err := os.ReadFile(marker); err == nil && string(got) == string(token) && len(orphansIn(pathForms(p.Path))) == 0 {
			_ = os.Remove(marker) // only our own marker: a restart may have written a new one
		}
	}()
	return proc, nil
}

var (
	srtGitOnce sync.Once
	srtGitPath string
)

// realGit is the git binary a sandboxed git command runs. On macOS /usr/bin/git is a shim that
// starts xcodebuild to find the real one; under the sandbox that takes about 3 s per call (its
// fs-event stream fails) and a snapshot makes several calls inside the 5 s git limit. A git in
// /usr/local/bin comes first, as in gitEnv's PATH; otherwise the one in the developer directory.
func realGit() string {
	srtGitOnce.Do(func() {
		srtGitPath = "git"
		if _, err := os.Stat("/usr/local/bin/git"); err == nil {
			srtGitPath = "/usr/local/bin/git"
			return
		}
		if out, err := exec.Command("/usr/bin/xcode-select", "-p").Output(); err == nil {
			c := filepath.Join(strings.TrimSpace(string(out)), "usr", "bin", "git")
			if _, err := os.Stat(c); err == nil {
				srtGitPath = c
			}
		}
	})
	return srtGitPath
}

// exec runs one git command: no network, and the gateway's own git environment only.
func (r *srtRunner) exec(ctx context.Context, p store.Project, home string, argv, extraEnv []string, stdin []byte) (gitResult, error) {
	if len(argv) > 0 && argv[0] == "git" {
		argv = append([]string{realGit()}, argv[1:]...)
	}
	cmd, _, err := r.command(p, home, p.ID+"-git", srtSpec{gitConfig: true}, argv, gitEnv(home, extraEnv))
	if err != nil {
		return gitResult{}, err
	}
	return runCapped(ctx, cmd, stdin)
}

// oneOff runs one push-path command in its own srt process. It has network only when c.network is
// set, and then only to the git hosts. The scratch folder in c.mounts is readable.
func (r *srtRunner) oneOff(ctx context.Context, p store.Project, home string, c oneOffCmd, stdin []byte) (gitResult, error) {
	name, err := oneOffName(p)
	if err != nil {
		return gitResult{}, err
	}
	spec := srtSpec{gitConfig: true, readOnly: c.mounts}
	if c.network {
		spec.domains = r.cfg.GitHosts
		if len(spec.domains) == 0 {
			spec.domains = config.DefaultGitHosts
		}
	}
	cmd, path, err := r.command(p, home, name, spec, c.argv, append(append([]string{}, c.vars...), c.secrets...))
	if err != nil {
		return gitResult{}, err
	}
	defer os.Remove(path)
	return runCappedFor(ctx, pushTimeout, cmd, stdin)
}
