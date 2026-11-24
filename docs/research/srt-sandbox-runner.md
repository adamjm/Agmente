# Research: replacing the Apple `container` runner with Anthropic sandbox-runtime (`srt`)

Date: 2026-11-20. Repo: `/Users/adammakarucha/Documents/Projects/remote-bob-app/Agmente`. Tested on macOS 27.0.1, arm64, Node 24.5.0, Bob `@ibm/bob` 2.0.9 (commit `9690f20b0`, host install at `/opt/homebrew/lib/node_modules/@ibm/bob`), `@anthropic-ai/sandbox-runtime` 0.0.83 (npm `latest`, engines `node >=22.12.0`).

Scope: research, probes and a plan. No repo code or config was changed. All probes ran in `/tmp/srt-spike` with dummy folders (deleted afterwards). **No real Bob prompt was sent**, so Bob's API reachability under the proxy is not verified (section 4).

## 0. Answer in brief

`srt` can replace the Apple runner for the Mac, and the numbers favour it clearly. The security model is different in kind, though, and that needs an owner decision before any code.

| | Apple `container` (RESULTS 2026-11-07) | `srt` (this spike) |
| --- | --- | --- |
| Isolation | Separate VM and kernel per project, own uid | Seatbelt profile on the owner's own uid, same kernel, same machine |
| Cold start, 1 project | about 2.4 s median load | 0.12 s from spawn to `initialize` answered and exit (includes `srt` start) |
| 8 projects at once | 9.2 s median load | 0.31 s, 8 of 8 answered `initialize` |
| Marginal memory per project | about 830 MiB (VM) | about 385 MiB (Bob 309 MiB + `srt` wrapper 75 MiB), idle after `initialize` |
| Fixed baseline | about 0.7 GB runtime | none |
| Dependencies | `container` CLI, kernel, image build, DNS setting | Node 22.12 or later, `npm i -g @anthropic-ai/sandbox-runtime`; `bob` and git on the host |
| Toolchains | Pinned in the image (Go, Rust, Python, Node, D-110) | Whatever is on the host `PATH` |

The trade is a weaker boundary for a much lighter runtime. `srt` is a sandbox for a process the owner already trusts on their machine, not a VM. D-008 ("Bob and git run inside the project container") and D-051 (container user mapped to the gateway user) rest on a stronger boundary and would need a superseding decision.

## 1. What `srt` is

- A CLI and a Node library. On macOS it generates a Seatbelt profile and runs the command under `sandbox-exec`. On Linux it uses bubblewrap. Network is filtered by an HTTP proxy and a SOCKS5 proxy that `srt` starts on the host; the profile only lets the process reach those local ports.
- Filesystem: reads are **allowed everywhere by default** (deny-then-allow); writes are **denied everywhere by default** (allow-only). `allowRead` beats `denyRead`; `denyWrite` beats `allowWrite`.
- Network: nothing by default. `allowedDomains` takes wildcards and optional ports. Per-command allow lists exist in the library (`registerCommandNetworkLists`).
- Always-denied writes, even inside an allowed folder: `.bashrc`, `.zshrc`, `.gitconfig`, `.gitmodules`, `.mcp.json`, `.vscode/`, `.idea/`, `.claude/commands|agents`, `.git/hooks/`, `.git/config`.
- Status: "Beta Research Preview", config format may change. The CLI changed shape between the README's examples and 0.0.83 (a command string now needs `-c`; a config file with a missing key such as `filesystem.denyWrite` is refused rather than defaulted). Pin the version.
- macOS uses `sandbox-exec`, which Apple marks deprecated but still ships. The README lists ripgrep as a macOS dependency. It was not installed here and every probe, including the `.git/hooks` deny, still worked, so treat that as "to confirm", not as a fact either way.

## 2. What the gateway does today (the surface to replace)

From `gateway/internal/server/runner.go`, `runner_apple.go`, `git_oneoff.go`, `agent.go`:

- `runner` interface: `start` (agent process with pipes), `exec` (git, capped, with timeout kill hooks), `oneOff` (git push path in its own container, D-105).
- The project lock (D-015) is the container name for Apple and Podman, and an `flock` on `<home>/.acpcode.lock` for the host runner. `srt` has no names, so it takes the host runner's lock.
- Apple git goes through `container exec` into the agent container (0.21 s a call) with a marker env var and a kill script for timeouts (D-080).
- Paths: the project folder and the project home are mounted at their host paths, so ACP paths need no translation. That stays true under `srt`, since there is no mount.
- Environment: allow-listed names only, values in `cmd.Env`, `HOME` set to the project home (`agentEnv`). Unchanged.
- `hostRunner` already exists, guarded by `runner.allowHost` ("tests and development only"). An `srt` runner is `hostRunner` with the command wrapped, so most of the structure exists.

## 3. Probe results

All commands were run through `srt -s <settings> -c '<cmd>'` unless noted.

### 3.1 Confinement (worked as configured)

Config used: `denyRead: ["/Users/<owner>"]`, `allowRead` and `allowWrite` for the project and home folders, no network.

| Probe | Result |
| --- | --- |
| Read project file | Works |
| Read `~/.ssh`, `~/Documents` | `Operation not permitted` |
| Write inside project, write outside | Inside works; outside `Operation not permitted` |
| Read a sibling project folder (`denyRead` on the parent, `allowRead` on this project only) | Sibling `Operation not permitted`; the parent's listing also denied. Own folder fine |
| Write `.git/hooks/pre-commit` | Denied (mandatory deny) |
| `kill -9` of a host process | `Operation not permitted`; victim stayed alive |
| `ps`, `sysctl kern.proc.all` | `Operation not permitted` |
| `curl https://example.com` with empty allowlist | `CONNECT tunnel failed, response 403` |

### 3.2 Gaps a default config leaves open

- **Other tenants' and the system's temp areas are readable.** With only `denyRead` on the owner's home, `ls /private/tmp` and `ls /var/folders` both worked. The config must also deny those and give each project its own `TMPDIR` under its home. Not yet re-tested with that config.
- **No uid separation.** The sandboxed process runs as the owner. The 0700 homes (D-051) stop being a boundary; the profile is the only one. A Seatbelt escape or a missed deny is a full-owner compromise, not a container compromise.
- **Reads are allow-by-default.** Every secret outside the deny list is readable. The deny list has to be a positive list built the other way round (deny `/Users`, allow back what is needed), and tested per tool.
- **Cleanup is not automatic.** Killing the `srt` process alone left its children running (`sleep 111`, `sleep 112` stayed). Killing the **process group** left nothing. The gateway's `startProcess` does not set a process group today (`agent.go`), so the `srt` runner must start `srt` in its own group and kill the group (`terminate`, `runCapped`). The existing timeout kill hooks (D-080) are no longer needed for git, since the group kill replaces the marker script.

### 3.3 Network

- `srt` injects proxy variables (`HTTP(S)_PROXY`, `ALL_PROXY`, and tool-specific ones such as `GIT_CONFIG_PARAMETERS` and `CLOUDSDK_*`). The proxy credential sits in those variables inside the sandbox.
- **Node ignores them by default.** `fetch` to an allowed host failed with `ENOTFOUND` (fails closed). With `NODE_USE_ENV_PROXY=1` the allowed host returned 200 and a denied host was cancelled. Node 24.5.0 is installed here, and the flag exists from Node 22.21. Bob is a Node program, so the runner must set `NODE_USE_ENV_PROXY=1` in its environment, and the gateway must require Node 22.21 or later for Bob.
- Bob printed repeated `ERROR: failed to copy trust settings of system certificate` lines until `enableWeakerNetworkIsolation: true` was set. That option re-opens `com.apple.trustd.agent`, which the README calls a possible data-exfiltration route. I did not test whether Bob works without it; the noise may be harmless.
- Per-tool proxying is the weak point. Anything that ignores the proxy variables is blocked rather than leaking (fail closed on macOS, because the profile only allows the proxy port), which means tools break instead of escaping. Each toolchain the agent uses (`npm`, `pip`, `go`, `cargo`, `git` over HTTPS) needs its registry hosts allowed and a check that it honours the proxy.
- Allowing a domain such as `github.com` allows pushes to any repository there. Domain fronting is a documented limit.

### 3.4 Bob under `srt`

- `bob --version` printed `2.0.9`.
- `bob acp` under `srt` (config allowing `*.ibm.com`, read of `/opt/homebrew`, write of the project and home) answered a real ACP `initialize` with `loadSession`, `session/close`, `mcp http` capabilities, as under the host runner.
- 8 concurrent `bob acp` processes each answered `initialize`: 8 of 8, 0.31 s over the 3 s hold.
- Memory after `initialize` (RSS, `ps`): `bob` node 309 MiB, the `srt` node wrapper 75 MiB. A loaded session and a long turn were **not** measured; the Apple figure of about 830 MiB was measured with one session loaded, so the comparison is indicative only.

### 3.5 Git

- Gateway-style invocation (`GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `core.hooksPath=/dev/null`, `core.fsmonitor=false`, `safe.directory`) works: `git status` took 0.36 s wall including `srt` start, add and commit worked.
- Without `GIT_CONFIG_GLOBAL`, git dies reading `~/.gitconfig` (`Operation not permitted`). The gateway already sets it, so no change.
- macOS `/usr/bin/git` is Apple's shim and writes an `xcrun_db` cache under `/var/folders`, which the sandbox refuses. It prints errors but still returns the right answer. Use Homebrew git (or allow that one write) to keep stderr clean.
- **`git init` inside the sandbox fails**: copying the template hooks into `.git/hooks` is a mandatory deny. The project-creation path (D-105, `git_init.go`) must either run outside the sandbox, or run `git init --template=` with no templates. Likewise anything that writes `.git/config` (`git remote add`, `git config`) is denied for the agent as well. Check which gateway calls write `.git/config`.
- Per-call cost: about 0.3 s, against 0.21 s for `container exec` today. The `srt` start (Node plus two proxies) dominates. A long-lived helper using the library would remove it (option B below).

## 4. Not verified

Updated 2026-11-22 after the test plan (`docs/research/srt-test-plan.md`; results in `docs/RESULTS.md`).

1. A real prompt: **done.** Bob needs `api.us-east.bob.ibm.com`, `bob.ibm.com` and `iam.cloud.ibm.com`.
2. MCP: **done** (item 3). stdio servers inherit the sandbox. http and https entries need `allowLocalBinding` and `localhost` URLs. A stdio server cannot use the network.
3. Toolchains: **done** (item 4). Go needs weaker network isolation; Rust needs `allowRead` for `~/.cargo/bin` and `~/.rustup`; Python and Node work. See `MAC-SETUP.md` section 14.
4. The project lock: **done.** It survives srt; a killed gateway never left it stuck (item 2).
5. Violation reporting for the audit log: not wired. The soak read the Seatbelt denial log (`log show`) and found none.
6. Memory with a loaded session and under a long turn: **done** (item 5): 3.3 GB for 8 projects idle; a busy Bob grows to about 1.9 GB.
7. The Seatbelt behaviour on future macOS releases (`sandbox-exec` deprecation): open.
8. Open: a push over the network to a real remote; the 4-hour two-project soak; Linux.

## 5. Design options

**A. Shell out to the `srt` CLI per process (recommended first step).**
`srtRunner` is `hostRunner` plus a generated settings file per project (written by the gateway into the project home's gateway-owned area, not writable by the agent) and `exec.Command(srtPath, "-s", settings, "--", argv...)` in its own process group. One `srt` process per agent, one per git call, one per push command. Simple, uses the shipped CLI, easy to test with a fake `srt` fixture like `fake-container.mjs`. Costs: 75 MiB and 0.3 s per spawn.

**B. A long-lived Node helper using the library.**
One helper process holds `SandboxManager`, starts the proxies once, and wraps commands (`wrapWithSandbox`, with `commandId` and `registerCommandNetworkLists` for per-command network rules, which fits the push path). Cuts the per-call and per-process cost, and allows `--control-fd` live network updates. Costs: a second process type and a protocol between the Go gateway and the helper, and a longer-lived component holding every project's proxy state. Worth it only if option A's git cost matters in practice.

**C. Generate Seatbelt profiles in Go and call `sandbox-exec` directly.**
No Node, no proxy dependency. But the profile generation, glob handling, mandatory denies, proxy and violation handling are the product. Not recommended.

Use A, measure, and move to B only on a measured need.

## 6. Plan

New runner kind `"srt"` in `config` (`runner.kind`, next to `apple`, `podman`, `host`), implementing the existing `runner` interface. Podman stays for Linux. The Apple runner stays until the `srt` runner passes the same live check, then becomes optional. The app needs no change; this is gateway and docs only.

### Phase 0: owner decisions (before code)

1. Accept the weaker boundary on the Mac: same kernel, same uid, profile only. This supersedes D-008 and D-051 for `kind: "srt"`. Podman or Apple remain the choice for a stronger boundary.
2. Toolchain source: host `PATH` (Homebrew), or a gateway-owned prefix. D-110's pinned toolset no longer applies under `srt`. Bob must stay pinned (FR-32): install `@ibm/bob@2.0.9` in a gateway-owned prefix **outside** every writable path (the README warns that a copy inside a writable path can be rewritten by the sandboxed command).
3. `enableWeakerNetworkIsolation`: accept or not (section 3.3).
4. Network policy: the exact allow list for Bob's API and each toolchain registry, and whether the project can add domains.

### Phase 1: spike to close section 4 (about half a day, no repo code)

Real prompt through the proxy with `SRT_DEBUG`, to get the host list. Toolchain builds. MCP stdio and loopback HTTP. Temp-folder deny retest. Loaded-session memory. Gate: Bob completes a turn with a tool call under the final deny list, with the tenant-isolation and temp probes still passing.

### Phase 2: `srtRunner` (gateway)

- `config`: `runner.kind: "srt"` with `srt` (absolute path), `settingsDir` (gateway-owned), `network.allowedDomains` list. Validation: path absolute and outside every project and home path; Node version check at start (`>= 22.21`).
- `runner_srt.go`: `start` (lock with `lockHome`, as `hostRunner`; settings file per project; `srt` in its own process group; env from `agentEnv` plus `NODE_USE_ENV_PROXY=1`, `TMPDIR` under the home), `exec` (git, same `gitCommand` flags, group kill on timeout or output cap), `oneOff` (push path: its own `srt`, network only to the git host, token in the process environment, never in argv, as today).
- Settings file contents per project: `denyRead` of `/Users`, `/private/tmp`, `/var/folders` and the other tenants' folders; `allowRead` of the project, its home, the toolchain prefixes; `allowWrite` of the project and its home only; the allow list for the network.
- `git_init.go`: run outside the sandbox or with `--template=`. Audit every gateway git call for writes to `.git/hooks` or `.git/config`.
- Tests: Go unit tests for the argument and settings building (secrets never in argv or settings, as `runner_secrets_test.go`), a `fake-srt.mjs` fixture beside `fake-container.mjs`, the lifecycle, lock and stop tests from `runner-apple.test.mjs` run against the new kind, and a live harness mode (`live-bob.mjs --runner srt`).

### Phase 3: verification

Re-run the checks used for Apple: lifecycle, stop, idle stop, git exec and timeout cleanup, push path, `bench-concurrent.mjs` (N = 1, 2, 4, 8) for start time and memory, and a negative suite as tests: read another project, read `~/.ssh`, write outside the project, write `.git/hooks`, signal a host process, reach a denied host. Record in `docs/RESULTS.md`.

### Phase 4: docs and decision

New decision (next free `D-` number) superseding D-008 and D-051 for this kind; update `ARCHITECTURE.md` (project runtime row), `MAC-SETUP.md` (install `srt`, no image build, no DNS step), `config.mac.example.json` or a new example, and the NFR-15 note (D-083).

### Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Profile gap lets a prompt-injected agent read owner files | Owner-level data exposure; no VM behind it | Positive deny list, negative tests as code, per-project settings the agent cannot write |
| `srt` is a research preview | Config or CLI changes between versions | Pin the version; the settings builder is one function with a test |
| `sandbox-exec` deprecation | Future macOS may drop it | Keep Apple and Podman runners; do not remove them |
| Tools that ignore proxy variables | Silent breakage (fail closed) | Per-toolchain checks in Phase 1; document |
| Process leaks on kill | Orphaned agent processes | Process-group start and kill, tested |
| Host toolchain drift | Different results than the pinned image | Decision in Phase 0; record versions in the session |

## 7. Recommendation

Do Phase 0 and Phase 1 first. If the owner accepts the same-uid boundary, build option A as `runner.kind: "srt"`, keep Apple and Podman available, and let the benchmark decide whether the Mac default changes. The measured gain is real (about 0.3 s against 2.4 to 9.2 s for starts, about 385 MiB against 830 MiB per project, no VM baseline), but it is bought with isolation, and that is a decision, not an implementation detail.
