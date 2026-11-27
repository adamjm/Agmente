package server

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Toolchain check for the srt runner (docs/research/srt-test-plan.md, item 4). It needs the real
// srt, the network and the toolchains, so it runs only with
//
//	ACPCODE_TEST_SRT=/path/to/srt ACPCODE_TEST_SRT_TOOLCHAINS=1 go test ./internal/server -run LiveSRTToolchains -v
//
// Each case runs in the agent's sandbox (the settings the gateway writes for the agent), with
// HOME at the project's home, and logs how long it took. A case is skipped when its tool is missing.

func (f srtFixture) agentRun(t *testing.T, name string, extraEnv []string, script string, limit time.Duration) (string, time.Duration, error) {
	t.Helper()
	env := append([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + f.home, "LANG=en_US.UTF-8"}, extraEnv...)
	cmd, path, err := f.runner.command(f.project, f.home, f.project.ID+"-"+name, srtSpec{agent: true}, []string{"/bin/sh", "-c", "exec 2>&1; " + script}, env)
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(path)
	start := time.Now()
	res, err := runCappedFor(context.Background(), limit, cmd, nil)
	return string(res.Out), time.Since(start), err
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

func TestLiveSRTToolchains(t *testing.T) {
	f := liveSRT(t)
	if os.Getenv("ACPCODE_TEST_SRT_TOOLCHAINS") == "" {
		t.Skip("set ACPCODE_TEST_SRT_TOOLCHAINS=1 to run the toolchain cases (network, slow)")
	}
	userHome, _ := os.UserHomeDir()
	// Go makes its module cache read-only; make it removable before the temp dir cleanup runs.
	t.Cleanup(func() { _ = exec.Command("chmod", "-R", "u+w", f.state).Run() })
	f.cfg.Runners[0].AllowRead = []string{"/opt/homebrew", "/usr/local"}
	if extra := os.Getenv("ACPCODE_TEST_SRT_ALLOWREAD"); extra != "" {
		f.cfg.Runners[0].AllowRead = append(f.cfg.Runners[0].AllowRead, strings.Split(extra, ",")...)
	}
	f.cfg.Runners[0].AllowedDomains = []string{
		"proxy.golang.org", "sum.golang.org", "storage.googleapis.com",
		"crates.io", "index.crates.io", "static.crates.io",
		"pypi.org", "files.pythonhosted.org",
		"registry.npmjs.org", "github.com",
	}
	has := func(tool string) bool { _, err := exec.LookPath(tool); return err == nil }
	type result struct {
		name string
		took time.Duration
		ok   bool
		note string
	}
	var results []result
	run := func(name, tool string, extraEnv []string, files map[string]string, script string, limit time.Duration, want ...string) {
		t.Run(name, func(t *testing.T) {
			if tool != "" && !has(tool) {
				t.Skipf("%s is not installed", tool)
			}
			for rel, body := range files {
				mustWrite(t, filepath.Join(f.project.Path, rel), body)
			}
			out, took, err := f.agentRun(t, strings.ReplaceAll(name, "/", "-"), extraEnv, script, limit)
			ok := err == nil
			for _, w := range want {
				if !strings.Contains(out, w) {
					ok = false
				}
			}
			note := ""
			if !ok {
				note = tail(out, 12)
				t.Errorf("%s failed after %s (err %v), last output:\n%s", name, took.Round(time.Millisecond), err, note)
			}
			results = append(results, result{name, took, ok, note})
			t.Logf("%s: ok=%v in %s\n%s", name, ok, took.Round(100*time.Millisecond), tail(out, 6))
		})
	}

	goFiles := map[string]string{
		"go/go.mod":       "module example.com/t\n\ngo 1.21\n\nrequire github.com/google/uuid v1.6.0\n",
		"go/main.go":      "package main\n\nimport \"github.com/google/uuid\"\n\nfunc main() { println(uuid.NewString()) }\n",
		"go/main_test.go": "package main\n\nimport \"testing\"\n\nfunc TestOK(t *testing.T) {}\n",
	}
	goScript := "cd go && go mod download && go build ./... && go test ./... && echo GO_DONE"
	goEnv := []string{"GOTOOLCHAIN=local", "GOFLAGS=-mod=mod"}
	// Default settings: Go cannot verify certificates (it asks the macOS trust service). This case
	// documents that; the next one turns weaker network isolation on, as MAC-SETUP section 14 says.
	run("go-default-tls-fails", "go", goEnv, goFiles, goScript+" || echo GO_FAILED", 4*time.Minute, "x509")
	f.cfg.Runner.WeakerNetworkIsolation = true
	run("go-weaker-network-isolation", "go", goEnv, goFiles, goScript, 4*time.Minute, "GO_DONE")
	f.cfg.Runner.WeakerNetworkIsolation = false

	// cargo and rustc live in ~/.cargo/bin and the toolchain in ~/.rustup, both under the denied
	// home. Allow just those two; ~/.cargo/credentials.toml stays unreadable.
	f.cfg.Runners[0].AllowRead = append(f.cfg.Runners[0].AllowRead, filepath.Join(userHome, ".cargo", "bin"), filepath.Join(userHome, ".rustup"))
	rustEnv := []string{"CARGO_HOME=" + f.home + "/.cargo"}
	if os.Getenv("ACPCODE_TEST_SRT_RUSTUP") != "" {
		rustEnv = append(rustEnv, "RUSTUP_HOME="+os.Getenv("ACPCODE_TEST_SRT_RUSTUP"))
	} else if _, err := os.Stat(filepath.Join(userHome, ".rustup")); err == nil {
		rustEnv = append(rustEnv, "RUSTUP_HOME="+filepath.Join(userHome, ".rustup"))
	}
	run("rust", "cargo", rustEnv, map[string]string{
		"rust/Cargo.toml":  "[package]\nname = \"t\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[dependencies]\nitoa = \"1\"\n",
		"rust/src/main.rs": "fn main() { let mut b = itoa::Buffer::new(); println!(\"{}\", b.format(42)); }\n#[cfg(test)]\nmod tests { #[test] fn ok() {} }\n",
	}, "cd rust && cargo build && cargo test && echo RUST_DONE", 6*time.Minute, "RUST_DONE")

	run("python", "python3", nil, map[string]string{
		"py/test_ok.py": "def test_ok():\n    assert 1 + 1 == 2\n",
	}, "cd py && python3 -m venv .venv && .venv/bin/pip install --disable-pip-version-check -q pytest && .venv/bin/python -m pytest -q && echo PY_DONE", 5*time.Minute, "PY_DONE")

	run("node", "npm", nil, map[string]string{
		"node/package.json": `{"name":"t","version":"1.0.0","dependencies":{"is-odd":"3.0.1"},"scripts":{"test":"node --test"}}`,
		"node/ok.test.js":   "const test = require('node:test');\ntest('ok', () => {});\n",
	}, "cd node && npm install --no-audit --no-fund -q && rm -rf node_modules && npm ci --no-audit --no-fund -q && npm test && echo NODE_DONE", 4*time.Minute, "NODE_DONE")

	// git over ssh has no agent socket, no key and no network: it must fail fast, not hang.
	run("ssh-fails-cleanly", "ssh", nil, nil,
		"ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com; echo EXIT=$?", 90*time.Second, "EXIT=")
	// The agent's sandbox denies writes to .git/hooks and .git/config (D-122), so `git clone` and
	// `git init` inside the project fail. That is a known limit of the agent, not of the gateway's own git.
	run("git-clone-is-denied", "git", nil, nil,
		"git clone -q https://github.com/octocat/Hello-World.git c1; echo EXIT=$?", 2*time.Minute, "Operation not permitted", "EXIT=128")

	run("make-clang", "make", nil, map[string]string{
		"c/hello.c":  "#include <stdio.h>\nint main(void){puts(\"hi\");return 0;}\n",
		"c/Makefile": "hello: hello.c\n\tclang -o hello hello.c\n",
	}, "cd c && make && ./hello", 3*time.Minute, "hi")

	// A package that runs code at install time must not reach the host: no home, no sibling
	// project, no state folder, no git hooks, no network except the allowed hosts.
	sibling := filepath.Join(f.cfg.Roots[0], "beta", "secret.txt")
	mustWrite(t, sibling, "beta-secret")
	mustWrite(t, filepath.Join(f.state, "gateway.db"), "state-secret")
	probe := fmt.Sprintf(`
r=evil-result.txt; : > $r
ls %[1]s/.ssh >/dev/null 2>&1 && echo SSH_READABLE >> $r || echo SSH_DENIED >> $r
ls %[1]s >/dev/null 2>&1 && echo HOME_LISTED >> $r || echo HOME_DENIED >> $r
cat %[2]s >/dev/null 2>&1 && echo SIBLING_READABLE >> $r || echo SIBLING_DENIED >> $r
cat %[3]s/gateway.db >/dev/null 2>&1 && echo STATE_READABLE >> $r || echo STATE_DENIED >> $r
mkdir -p ../.git/hooks 2>/dev/null; echo '#!/bin/sh' > ../.git/hooks/pre-commit 2>/dev/null && echo HOOK_WRITTEN >> $r || echo HOOK_DENIED >> $r
echo x > %[1]s/evil.txt 2>/dev/null && echo HOME_WRITTEN >> $r || echo HOME_WRITE_DENIED >> $r
curl -sS -m 6 -o /dev/null https://example.com 2>/dev/null && echo NET_OPEN >> $r || echo NET_DENIED >> $r
`, userHome, sibling, f.state)
	run("malicious-package", "npm", nil, map[string]string{
		"evil/package.json":   `{"name":"evil","version":"1.0.0","scripts":{"postinstall":"sh ../probe.sh"}}`,
		"evil/probe.sh":       "",
		"probe.sh":            probe,
		"victim/package.json": `{"name":"victim","version":"1.0.0"}`,
	}, "git init -q . 2>/dev/null; cd evil && npm install --no-audit --no-fund -q --foreground-scripts 2>&1 | tail -2; sh ../probe.sh; cat evil-result.txt", 2*time.Minute,
		"SSH_DENIED", "HOME_DENIED", "SIBLING_DENIED", "STATE_DENIED", "HOME_WRITE_DENIED", "HOOK_DENIED", "NET_DENIED")

	t.Log("\ntoolchain results:")
	for _, r := range results {
		t.Logf("| %-26s | %-5v | %8s |", r.name, r.ok, r.took.Round(100*time.Millisecond))
	}
}
