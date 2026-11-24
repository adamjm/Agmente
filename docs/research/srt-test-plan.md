# Test plan: the parts of the srt runner (D-122) that are not verified

Status of what is already verified: `docs/RESULTS.md` 2026-11-22 and `docs/research/srt-sandbox-runner.md`. This plan covers what those records list as not verified. Each test has a pass rule written before the run, so a result cannot be argued into a pass.

Common setup:
- Mac with srt 0.0.83 at an absolute path outside every project root and the state folder, Node 22.21 or later, `BOB_API_KEY` in `.env` (never printed; never run `srt --debug` with a secret in the command line, it prints it).
- Gateway built with `go build -trimpath -o bin/acpcode-gateway ./cmd/acpcode-gateway`.
- Hosts for Bob: `api.us-east.bob.ibm.com`, `bob.ibm.com`, `iam.cloud.ibm.com`.
- Record every result in `docs/RESULTS.md` under a new dated entry, with the exact command, the Bob and srt versions, and pass or fail.

## Decisions taken (2026-11-22)

- `allowLocalBinding` is a config key, off by default, for the agent only. Built and unit-tested; item 3 tests it on the real stack.
- Linux is out of scope for now. Item 7 stays as a TODO and is not run.
- Concurrency target is 8 projects at once (item 5 counts 1, 2, 4 and 8, with 8 the pass target).
- Every toolchain in item 4 is in scope: Go, Rust, Python, Node, ssh and make.

## Order and effort

| # | Component | Why this order | Effort | Needs |
|---|---|---|---|---|
| 1 | Push with network | Security-relevant, code already written, no new tooling | 0.5 day | A throwaway GitHub repo and token |
| 2 | Crash and orphan handling | Can break the project lock; found cheaply | 0.5 day | Nothing |
| 3 | MCP servers | A main Bob feature, and sandbox rules may block it | 1 day | A stdio and an http MCP server |
| 4 | Toolchains | Decides what `allowRead` and `allowedDomains` must hold | 1 day | Go, Rust, Python, Node on the Mac |
| 5 | Concurrency and memory | The reason for the change (NFR-15) | 1 day | `bench-concurrent` srt mode |
| 6 | Long real session (soak) | Finds leaks and slow decay | 1 day, mostly waiting | Items 1 to 5 fixed |
| 7 | Linux | **TODO, out of scope for now** | 1 to 2 days | A Linux host with user namespaces |

Items 1 to 3 can start now and in parallel. Items 5 and 6 should wait for fixes from 1 to 4, because those fixes change the settings the benchmark measures.

## 1. Push with network (oneOff with `network: true`)

**Question.** Does the push path work when the sandbox may reach only the git hosts, and does the token stay out of argv, settings files and the agent's reach?

**Setup.** A private throwaway repo on GitHub, a fine-scoped token stored through the gateway's credential call, a project with `gitInit` and `gitRemote` for that repo.

**Steps.**
1. Create a project with a remote, edit a file, commit through the gateway, then push through the gateway.
2. While the push runs, read `ps -axo args` for the token and `<stateDir>/srt/` for the settings file.
3. After it ends, list `<stateDir>/srt/` and the push scratch folder.
4. Push to a host not in `gitHosts` (a second throwaway remote on another host) and expect a refusal.
5. Run the push with the proxy refusing the host (use a host list without `github.com`) and expect a clear error, not a hang.
6. Inside a sandboxed `sh`, try `curl https://example.com` during a push-shaped settings file and expect a denial.

**Pass.** The push lands on the remote. The token appears in no argv, no settings file and no log line. The settings file is gone after the call. The scratch folder is gone or empty. A wrong host is refused. The no-network case ends inside the push timeout.

**On failure.** TLS errors from git point to `enableWeakerNetworkIsolation` or the trust store; test it on and off and record which. A credential helper that needs the Keychain is outside the sandbox and must be refused (check that the gateway never uses it).

## 2. Crash and orphan handling

**Question.** If the gateway dies, do `srt`, Bob and the proxy die, and can the project be started again?

**Why it matters.** The runner kills the process group on a normal stop. After `kill -9` of the gateway nothing runs that code. The project lock is an inherited file descriptor; an orphaned `bob` that keeps it open would block the next start with `errProjectLocked`.

**Steps.**
1. Start a project's agent, run a turn, then `kill -9` the gateway.
2. List the survivors: `pgrep -fl 'srt|bob acp'` and `lsof` on the lock file.
3. Restart the gateway and open the same project.
4. Repeat with a `SIGTERM` to the gateway and with a `SIGKILL` of only `srt`.
5. Repeat with a turn running (a long `sleep 120` command approved) at the kill.
6. Check `/var/folders/*/T/srt-mux-*.sock` and `<stateDir>/srt/` for leftovers.

**Pass.** Either no survivor, or the next start recovers (the survivor is found and stopped, or the lock is released). No leftover sockets or settings files grow with each repeat.

**On failure.** Likely fix: the gateway, at start, kills any process group it recorded in a pid file under the project home, as the Apple runner removes stale containers. Alternatively, use `lockf` semantics tied to the gateway process, or run the agent through a small supervisor that exits when its parent does (`POLL_PPID`). Record which one.

## 3. MCP servers under the sandbox

**Question.** Do stdio and http MCP servers work for the agent, and does the sandbox limit them as intended?

**Facts to check first.** Bob starts a stdio MCP server as its own child, so it inherits the sandbox (same reads, writes and network). The gateway accepts http MCP only to `https`, or to a loopback host (`mcp_guard.go`). The settings the runner writes do not set `allowLocalBinding`, which governs localhost connections. Whether a loopback connection from inside the sandbox works is unknown.

**Cases.**
1. A stdio server installed under `/opt/homebrew` (readable). Expect it to start and list tools.
2. A stdio server installed in the user's home (denied). Expect a clear failure; record the message the user sees.
3. A stdio server that needs the network (an API client). Expect it to fail unless its host is in `allowedDomains`; then expect it to work.
4. An http MCP server on `127.0.0.1` run by the user on the host. Test with and without a `allowLocalBinding` setting.
5. An https MCP server on the internet, host in and out of `allowedDomains`.
6. A gateway-provided server entry (`mcp_servers.go`, the entries the gateway adds with secrets): confirm the secret reaches the server and is not in argv.
7. A stdio server that writes outside the project (to `~/.cache`): expect a denial, and check the server reports it instead of hanging.

**Pass.** Cases 1, 3 (with the host allowed), 4 and 5 (host allowed) work through a full turn that calls a tool. Cases 2, 3 (host not allowed), 5 (host not allowed) and 7 fail fast with a message. Secrets appear in no argv and no settings file.

**On failure.** If loopback is blocked and the http case matters, add a config key `allowLocalBinding` (off by default) and a decision note; do not enable it silently, since it opens every local service to the agent. If a stdio server needs a path in home, document `allowRead` for it.

## 4. Toolchains

**Question.** Which common work runs inside the sandbox with the documented `allowRead` and `allowedDomains`, and what must a user add?

**Method.** One scripted task per toolchain, run through the gateway with a real Bob prompt ("run the tests"), or directly with `srt -s <settings> -- ...` for speed.

| Toolchain | Task | Likely needs |
|---|---|---|
| Go | `go build`, `go test`, `go mod download` | read of the Go install, network to `proxy.golang.org`, `sum.golang.org`; weaker network isolation if TLS fails |
| Rust | `cargo build`, `cargo test` | read of `~/.cargo` and `~/.rustup` (denied by default), network to `crates.io`, `index.crates.io`, `static.crates.io` |
| Python | `python3 -m venv`, `pip install`, `pytest` | read of the Python install, `pypi.org`, `files.pythonhosted.org`; venv writes under the project |
| Node | `npm ci`, `npm test` | `registry.npmjs.org`; `node_modules` writes under the project; native add-ons that compile (needs Xcode tools reads) |
| Git over ssh | `git clone git@...` | Expected to fail (no ssh agent, no key); confirm it fails cleanly |
| Build tools | `make`, `clang` via the Xcode shim | Same shim cost as git (about 3 s per call); check `xcrun` cache writes |

**Pass criteria.** Each row either works with a documented `allowRead` and `allowedDomains` addition, or is recorded as unsupported with the reason. The result is a table for `MAC-SETUP.md` section 14, replacing "not tested".

**Watch for.** The Xcode shims (`/usr/bin/clang`, `/usr/bin/python3`, `/usr/bin/make`) call `xcodebuild` and cost seconds under the sandbox, the same cause as the git delay. If they matter, the runner can put the real developer directory first on `PATH`.

**Security check in the same run.** Run each toolchain's install step with a malicious package that tries to read `~/.ssh`, the sibling project, and the state folder, and to write `.git/hooks`. Expect all denied.

## 5. Concurrency and memory

**Question.** What do 1, 2, 4 and 8 running projects cost in memory and start time under srt, compared with the Apple numbers (RESULTS 2026-11-07: about 6205 MiB for 8, load median 9.2 s with 8, NFR-15 target 3 s p95)?

**Work needed first.** `gateway/scripts/bench-concurrent.mjs` accepts only `apple` and `podman`. Add `--runner srt`:
- spawn `srt -s <settings> -- /usr/bin/env ... bob acp` per project, with the same settings the runner writes (easiest: reuse the Go runner through the gateway, or copy the settings shape);
- replace `rssProcs()` for srt with the process tree under each started `srt` pid (use `ps -axo pid,ppid,rss,command`, walk the children);
- add `footprint -p <pid>` or `vmmap -summary` for a number that does not double-count shared pages, and keep RSS beside it.

**Steps.** Run counts `1,2,4,8`, three times each, on an otherwise idle Mac, same `bob` and `.env`. Also record system free memory before and during with `memory_pressure`, because RSS of node processes overstates shared memory.

**Pass.** A table with load median, p95 and max, turn latency, tree RSS and footprint, for each N, next to the Apple row. NFR-15 is met if p95 cold load is at most 3 s at the chosen N. No process leaks after the run (`pgrep` empty).

**Known from the single sample.** `bob acp` alone reaches about 1.9 GB RSS during a turn, so N=8 may be about 15 GB whatever the runner. Expect the saving to be the VM overhead and the start time, not Bob. Decide `limits.maxAgentsTotal` from this table.

## 6. Long real session (soak)

**Question.** Does anything degrade over a day of real use?

**Steps.**
1. One project, one session, 30 turns with tool use (edit files, run shell commands, run tests), with approvals answered by a script.
2. Idle stop and resume at least 5 times (`limits.idleSeconds` small), checking the session reloads and history is intact.
3. Two projects at once for 4 hours, one turn every few minutes each.
4. Watch every 5 minutes: RSS of the tree, open file descriptors (`lsof -p`), count of `srt-mux-*.sock` files, size and count of `<stateDir>/srt/`, count of `sandboxd` log denials (`log show --predicate 'sender == "Sandbox"'`).
5. Run `git` through the gateway during turns (status, diff, snapshot) and record the p95 of git call time; the 5 s limit must hold.
6. Let a turn run longer than `pushTimeout`-like limits (a 10-minute build) and confirm it is not killed.

**Pass.** RSS, descriptors and socket counts level off. No `git timeout` snapshot failure in the audit log. Idle stop leaves no process. Resume works every time. Denial log shows only expected paths; each unexpected one is explained.

**On failure.** Leaks point to the proxy process (srt keeps one per run) or to unreaped children; the fix belongs in the process-group kill or in the srt version pin.

## 7. Linux (TODO, out of scope for now)

**Question.** Does the runner work off the Mac, where srt uses bubblewrap and a socat proxy instead of Seatbelt?

**Prerequisites.** `bwrap`, `socat` and ripgrep installed, unprivileged user namespaces allowed (Ubuntu 24 restricts them by AppArmor), Node 22.21 or later.

**Known differences to check.**
- srt on Linux scans for `.git` and other protected files under the working directory (`mandatoryDenySearchDepth`), which can be slow on a large project.
- The proxy variable behaviour for Node (`NODE_USE_ENV_PROXY`) is the same; the proxy is a Unix socket bridge.
- `denyRegions` lists macOS paths that do not exist on Linux and are skipped, but `/tmp` and the user's home are real; confirm a denied `/tmp` does not break `bob`.
- `realGit()` falls back to `git` when `xcode-select` is missing; confirm.
- Linux kernel-level isolation is stronger than Seatbelt here (namespaces), which may change the D-122 risk statement.

**Steps.** Build the gateway on the Linux host, run the Go live tests with `ACPCODE_TEST_SRT`, then `live-bob.mjs --runner srt`, then items 1, 2 and 3 above.

**Pass.** 24 of 24 on the live check and the three live Go tests, or a list of the paths and settings that differ.

## Exit criteria for D-122

Move D-122 from "verify" to accepted when items 1 to 6 pass (item 7 is not required while Linux is out of scope), the toolchain table is in `MAC-SETUP.md`, and the memory table is in `RESULTS.md`. Any security-relevant failure (a denied path readable, a token visible, a survivor holding the lock) blocks acceptance until fixed and re-run.

## Still open

- Item 1 needs a throwaway GitHub repo and a token from the owner. Nothing else in the plan does.
