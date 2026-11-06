# Results

## Summary

| Test | Result | Date |
| --- | --- | --- |
| T-1 | PASS on macOS with Xcode 27.2: gateway 37/37, docs check, ACPClient and AppServerClient Swift tests | 2026-11-06 |
| T-2 | PASS | 2026-11-05 |
| T-3 | PASS | 2026-11-05 |
| T-4 | PASS | 2026-11-05 |
| T-5 | PASS | 2026-11-05 |
| T-6 | PASS | 2026-11-05 |
| T-7 | PASS | 2026-11-05 |
| T-8 | PASS (fake agent and real Bob 2.0.9) | 2026-11-05 |
| T-9 | PASS | 2026-11-05 |
| T-10 | PASS | 2026-11-05 |
| T-11 | PASS: p95 0.84 ms (limit 50 ms) | 2026-11-05 |
| T-12 | PASS: overhead p95 0.18 ms (limit 5 ms) | 2026-11-05 |
| T-13 | PASS | 2026-11-05 |
| T-14 | PASS: secrets migrate to the Keychain; Core Data attributes nil after reload | 2026-11-06 |
| T-15 | PASS: 24-case policy matrix; refused URLs make zero `makeConnection` calls | 2026-11-06 |
| T-16 | PASS: a 17 MiB frame header closes with 1009; no payload buffered | 2026-11-06 |
| T-17 | PASS: a wrong SPKI pin fails the TLS handshake against a local server; a right pin never replaces trust | 2026-11-06 |
| T-18 | PASS: disconnect mid-turn, subscribe with the last seq: no gap, no duplicate | 2026-11-06 |
| T-19 | PASS: 10,000 events replayed in 146 ms max (limit 1 s) | 2026-11-06 |
| T-20 | PASS: after SIGKILL of the gateway, every event a phone received is in the log | 2026-11-06 |
| T-21 | PASS (fake agent with Bob's load behaviour): no load or resume reaches the agent for a live session; no replay in the log | 2026-11-06 |
| T-22 | PASS: first answer wins; the second gets "answered elsewhere" | 2026-11-06 |
| T-23 | PASS: the timeout sends a reject option, or cancelled; never an allow | 2026-11-06 |
| T-24 | PASS (payload builder, Go unit test): 3 event types × 9 hostile names, at most 256 bytes, only name, session id and event type | 2026-11-06 |
| T-48 | PARTIAL: the wire part passes against a fake APNs server (17 tests in `test/apns.test.mjs`); the device part is `BLOCKED: needs a real APNs .p8 key, the Apple account and an iPhone` | 2026-11-07 |
| T-25 | PASS: outside roots and through a symlink, refused | 2026-11-06 |
| T-26 | PASS (host runner, wire level; runner level in 3.13): fsmonitor, external diff, textconv and pager programs never run for status, diff or log | 2026-11-06 |
| T-28 | PASS: a path not in the last status, none before a status, `../`, absolute, `.git/config`, `--output=…`, `-p`, a glob and an empty string are all refused | 2026-11-06 |
| T-29 | PASS: 14 deny-list names (changed, staged or untracked) show by name; their content is in no response | 2026-11-06 |
| T-30 | host runner PASS (p95 195 ms); podman on this Mac FAIL (about 3 s per call, over the 5 s timeout when three run together); not run on Linux. Recorded by the owner's decision to go on (2026-11-06) | 2026-11-06 |
| T-27 | PASS: with real Podman, a clean filter ran inside the container and left no marker on the host (3.13); the turn snapshot runs no filter at all, on the host runner and under Podman (3.15) | 2026-11-06 |
| T-31 | PASS: a turn in which the agent writes `new.txt` has a turn diff that lists it | 2026-11-06 |
| T-46 | PASS with a fake podman: one container per project at any time; each lifecycle case as stated | 2026-11-06 |
| T-32 | PASS on Bob 2.0.9: `initialize` equals the fixture (also matched on 2.0.7 except the version) | 2026-11-06 |
| T-33 | PASS on Bob 2.0.9 (and 2.0.7): new, prompt, load, resume, list, delete all succeed | 2026-11-06 |
| T-34 | Recorded (differs from F-12): on 2.0.7 and 2.0.9, `session/load` and (2.0.9) `session/resume` during a turn are refused with `-32600`; the turn completes. A second Bob process is not refused (see Q-5 entry) | 2026-11-06 |
| T-35 | Partial: Bob's error recorded; app part not built | 2026-11-05 |
| T-36 | PASS in the iOS Simulator (unit tests, not on a device): 50 MP PNG downsampled to 2048x1600, peak footprint increase 17 MiB; oversized, wrong MIME, corrupt data and 108 MP bomb refused | 2026-11-06 |
| All others | Not run | — |

## Entries

### 2026-11-05 — T-1 check gate (scaffold build)
- **Environment:** Linux 6.18, Node v22.23.4, npm 10.9.9, `ws` 8.22.1, no Swift toolchain.
- **Command:** `scripts/check.sh`, run twice: in the overlay alone, and after applying the overlay to upstream Agmente `87f224e`.
- **Output (trimmed):**
  ```
  == Gateway tests
  # tests 36
  # pass 36
  # fail 0
  == Docs cross-check
  ok  45 tests, 44 FRs, 14 NFRs, 11 decisions; all tests scheduled
  == Swift package tests (macOS only)
  SKIP: Swift package tests need macOS (ACPClient uses Network.framework)
  All checks passed.
  ```
- **Result:** PASS on Linux. Re-run on macOS (PLAN 0.5).
- **Notes:** After the overlay, `git status` showed `M CLAUDE.md` and only new files. The upstream `.gitignore` hides `.claude/` (line 16). D-011 and PLAN 0.2 fix this; the fix was tested on the clone.

### 2026-11-05 — T-2 to T-10, T-13 gateway tests
- **Environment:** as above. The agent is `gateway/test/fixtures/fake-agent.mjs`.
- **Command:** `npm test --prefix gateway`
- **Output (trimmed):**
  ```
  ok 3 - T-2: no Authorization header gets 401 and spawns nothing
  ok 4 - T-3: wrong token gets 401, right token gets 101
  ok 5 - T-4: an Origin header gets 403 even with a valid token
  ok 6 - T-7: the connection over the per-identity cap gets 429; the cap frees on close
  ok 7 - T-7: parallel requests cannot pass the cap
  ok 8 - T-10: 10 failures lock the address out, even for a good token
  ok 9 - T-10: behind a trusted proxy the limit applies per X-Forwarded-For address
  ok 20 - T-13: the audit log holds method names but no prompt text or token
  ok 22 - T-5: a non-loopback listen host is refused
  ok 23 - T-5: main.js exits non-zero for a public host
  ok 30 - T-6: a message over maxMessageBytes closes with 1009
  ok 31 - T-6: an agent line over maxMessageBytes closes with 1009
  ok 32 - T-8: cwd inside a root is forwarded; outside and symlink escape are refused
  ok 33 - T-9: arrays, two lines and invalid JSON each close with 1007
  ```
- **Result:** PASS
- **Source:** `gateway/test/*.test.mjs`
- **Notes:** T-6 and T-8 ran with `maxMessageBytes` 64 KiB to keep the test fast. The 16 MiB default uses the same code path.

### 2026-11-05 — T-11, T-12 latency (NFR-1, NFR-2)
- **Environment:** as above, 2 vCPU. Client, gateway and agent on one host; the client runs in the gateway's process.
- **Command:** `node gateway/test/bench.mjs` (2,000 echo calls of 1,030 bytes after 200 warm-up calls; 500 unauthenticated upgrades)
- **Output (three runs):**
  ```
  run 1: direct p95 0.138 ms, gateway p95 0.317 ms, overhead p95 0.180 ms, reject p95 0.839 ms, spawned 0
  run 2: direct p95 0.126 ms, gateway p95 0.249 ms, overhead p95 0.123 ms, reject p95 0.673 ms, spawned 0
  run 3: direct p95 0.132 ms, gateway p95 0.298 ms, overhead p95 0.167 ms, reject p95 0.511 ms, spawned 0
  run 4 (after the backpressure fix): direct p95 0.133 ms, gateway p95 0.270 ms, overhead p95 0.137 ms, reject p95 0.709 ms
  ```
- **Result:** PASS. The worst run is 28 times under the NFR-2 limit and 60 times under the NFR-1 limit.
- **Notes:** The benchmark does not include Caddy's TLS. Measure again on the host after PLAN 1.11. The shared event loop between client and gateway makes the overhead figure conservative, not optimistic.

### 2026-11-05 — T-32 partial: real Bob behind the gateway
- **Environment:** as above. `@ibm/bob` 2.0.9 from npm, started by the gateway as `bob acp --accept-license --log-level warn`, environment `PATH` and `HOME` only, no `BOB_API_KEY`.
- **Command:** a probe script (not in the overlay) that runs `createGateway` with the Bob command, connects with a token, and sends `initialize` and two `session/new` calls.
- **Output:**
  ```
  upgrade status 101
  initialize ms 1591
  initialize matches fixture: true
  session/new outside roots -> {"code":-32602,"message":"cwd is outside the allowed project roots"}
  session/new inside roots -> {"code":-32000,"message":"Authentication required"}
  audit events: connect, rpc:initialize, cwd_rejected:session/new, rpc:session/new, disconnect
  ```
- **Result:** Partial PASS. The `initialize` result through the gateway equals the fixture. Session tests are BLOCKED: need `BOB_API_KEY` and licence review (PLAN 4.2).
- **Notes:**
  - T-35: Bob returns JSON-RPC error `-32000` with message "Authentication required". FR-35 should map this error.
  - Unexpected: the project folder was a new temp folder that was never trusted, yet Bob reported the auth error, not a trust error. Either Bob checks auth before trust, or it treated the folder as trusted. Confirm in PLAN 4.3 with a key set. Do not rely on Bob's trust check as a control; the gateway's `cwd` guard (FR-6) is the control.
  - `--accept-license` was used for this probe only, in a disposable environment. Review the licence before you use it on your host.

### 2026-11-05 — Code review fixes before delivery
- **Environment:** as above.
- **Command:** `scripts/check.sh` after three fixes found by reading the gateway code.
- **Output (trimmed):**
  ```
  ok 10 - T-10: a client-supplied X-Forwarded-For prefix cannot dodge the lockout
  ok 34 - T-9: a message queued behind a violation never reaches the agent
  ok 35 - backpressure: a stalled agent pauses the phone socket and nothing is lost
  # pass 36
  # fail 0
  All checks passed.
  ```
- **Result:** PASS
- **Notes:**
  1. The rate-limit key used the first `X-Forwarded-For` entry. A proxy that appends lets the client control that entry and dodge the lockout. Now the last entry is used (the address the proxy saw).
  2. No backpressure: a client could send faster than the agent reads, and the gateway buffered without limit. The gateway now pauses the socket until the agent's stdin drains, and pauses the agent's stdout when the phone is slow.
  3. A message queued behind a protocol violation could still reach the agent during the close handshake. The gateway now drops every message once the socket is closing.
  Each new test fails against the old code by construction.

### 2026-11-06 — T-1 check gate on macOS (fork root)
- **Environment:** macOS (Darwin 27.0.0, arm64), Node v24.5.0, `ws` from `npm ci`, Command Line Tools only (no Xcode.app).
- **Command:** PLAN 0.1 to 0.4: overlay copied to the fork root, `.gitignore` changed (D-011), `npm ci --prefix gateway`, `scripts/check.sh`.
- **Output (trimmed):**
  ```
  git status: M .gitignore, M CLAUDE.md, all other entries new (?? .claude/..., docs/..., gateway/..., scripts/..., deploy/..., FORK.md)
  git check-ignore .claude/settings.local.json -> .claude/settings.local.json
  # tests 36  # pass 35  # fail 1
  ✖ the agent environment holds only allow-listed variables
    assert.ok(res.result.names.every((n) => n === 'PATH'))
  env -i PATH=/usr/bin node -e 'console.log(Object.keys(process.env))' -> [ 'PATH', '__CF_USER_TEXT_ENCODING' ]
  swift test --package-path ACPClient -> unable to resolve module dependency: 'XCTest'
  ```
- **Result:** FAIL. The test was not changed.
- **Notes:**
  - macOS itself adds `__CF_USER_TEXT_ENCODING` (a uid and text-encoding value) to every child process, even under `env -i`. The gateway does not pass it. Waiting on a decision about whether the test should allow this one OS-set name on Darwin.
  - BLOCKED: needs Xcode. Command Line Tools have no XCTest, so the Swift package tests (PLAN 0.5) and all app tasks cannot run on this Mac.
  - The `.env` file with `BOB_API_KEY` is at the fork root. `*.env` in `.gitignore` covers it; `git check-ignore .env` confirms that.

### 2026-11-06 — T-32, T-33, T-34, Q-6: live Bob behind the gateway
- **Environment:** as above. Bob `/opt/homebrew/bin/bob` 2.0.7 (Homebrew; the spec fixture is 2.0.9). Started by the gateway as `bob acp --accept-license --log-level warn`, with no `--trust` and no `--auto-approve`, env allow-list `PATH HOME LANG BOB_API_KEY`. `BOB_API_KEY` came from `.env` in the shell environment and was never printed. `HOME` was a temporary folder, so `~/.bob` was not read or changed.
- **Command:** `set -a; . ./.env; set +a; node gateway/scripts/probe-bob.mjs <args>`, three runs:
  - A: `--agent-cwd gateway --trust-project --skip-load-race`
  - B: `--agent-cwd project --skip-load-race`
  - C: `--agent-cwd project --trust-project`
- **Output (trimmed):**
  ```
  A: session/new {cwd: <trusted project>} -> -32600 Workspace "<gateway cwd>" is not trusted. Pass --trust ...
  B: session/new {cwd: <project>}         -> -32600 Workspace "<project>" is not trusted. Pass --trust ...
  C: initialize matches fixture (ignoring version): true
     session/new outside roots -> -32602 cwd is outside the allowed project roots
     session/new -> ok; modes: ["agent","plan","ask"]
     session/prompt -> ok (5057 ms), stopReason end_turn; updates: available_commands_update, agent_message_chunk, session_info_update
     session/list -> ok, 1 session
     session/load (idle) -> ok;  session/resume (idle) -> ok
     session/load during running turn -> -32600 Invalid request: Session is already running a prompt
       running turn -> ok, stopReason end_turn; 41 updates before the load, 266 after
     session/delete -> ok
     permission requests: []
  ```
- **Result:** T-32 PASS. T-33 PASS on 2.0.7; repeat on the pinned version after PLAN 4.1. T-34 recorded.
- **Notes:**
  - **Q-6 answered (2.0.7):** with a key set, Bob checks folder trust before auth and licence (`initializeSession`: `requireTrustedWorkspace`, then `requireAuthenticated`, then `requireLicenseConsent`). The workspace it checks is the **agent process's working directory**, not `session/new` `cwd`. In the minified package, `G0e` sets `directory: mQe()`, and `mQe(e)` uses `e || process.cwd()`. The earlier "Authentication required" result (2026-11-05) fits a run where folder trust was off or the folder was trusted.
  - **Security consequence:** in phase 1 the gateway spawns the agent in its own working directory, so `cwd` in `session/new` does not set Bob's workspace. The FR-6 guard checks a value that Bob 2.0.7 does not use for trust. Task 3.4 (one agent per project) must spawn Bob with `cwd` = the project path. This is not yet verified for tool file access.
  - **Trust at registration (PLAN 4.3):** run C trusted the folder by writing `{"version":1,"folders":{"<path>":"TRUST_FOLDER"}}` to `$HOME/.bob/trustedFolders.json`, the format in the local `~/.bob/trustedFolders.json` (verify against Bob docs). `--trust` was never passed.
  - **Q-1 / F-12 differs on 2.0.7:** `disposeExistingSession` throws "Session is already running a prompt" when `running` is set, so a load during a turn is refused and the turn is not cancelled. Not yet checked on 2.0.9. FR-20 stays useful because the refusal is still an error the phone would see.
  - The audit log writes one `rpc:session/update` line per agent notification (about 300 for a 300-line answer). Method names only, so it meets FR-9, but the volume is high.
  - **Bob writes into its working directory before trust:** the first run (agent cwd = fork root, folder not trusted) created `.bob/skills/next/SKILL.md`, a copy of `.claude/commands/next.md`, even though `session/new` was then refused as untrusted. It looks like Bob 2.0.7 converts Claude commands to Bob skills at startup (verify). The file was removed. One more reason to start Bob only in its project folder, in the container (D-008).

### 2026-11-06 — T-1 re-run after D-012
- **Environment:** as in the T-1 macOS entry above.
- **Command:** `scripts/check.sh`
- **Output (trimmed):**
  ```
  == Gateway tests
  ℹ tests 36  ℹ pass 36  ℹ fail 0
  == Docs cross-check
  ok  45 tests, 44 FRs, 14 NFRs, 12 decisions; all tests scheduled
  == Swift package tests (macOS only)
  error: ... ACPClientManagerRaceTests.swift:2:8 unable to resolve module dependency: 'XCTest'
  exit 1
  ```
- **Result:** FAIL. Every step before the Swift step passes. BLOCKED: needs Xcode (PLAN 0.5).

### 2026-11-06 — Bob updated to 2.0.9; T-32, T-33, T-34, Q-6 again
- **Environment:** as above. Global Bob changed from `bobshell` 2.0.7 (not on npm) to `@ibm/bob` 2.0.9 (npm `latest`; maintainers include `bobdev@ibm.com`; integrity `sha512-o/au6XXaXynhl9ictqIkxwlBVOHg7v6Anvv67SufUvQGDb26qfUcktH/PiMhvQ0zn41bxspiw83QAGU6ERSdiw==`). Commands: `npm uninstall -g bobshell`, `npm install -g --save-exact @ibm/bob@2.0.9`. `bob --version` → `2.0.9, commit: 9690f20b0`. A copy of 2.0.7 is kept outside the repo.
- **Command:** `set -a; . ./.env; set +a; node gateway/scripts/probe-bob.mjs <args>`, with a disposable `HOME` each time:
  - `--agent-cwd project --trust-project` (full run with the load race)
  - `--agent-cwd project --skip-load-race` (no trust entry)
  - `--agent-cwd project --distrust-project --skip-load-race` (`DONT_TRUST` entry)
  - `--agent-cwd gateway --skip-load-race` (agent in the fork root, no entry)
  - `--agent-cwd project --trust-project --deny-root --skip-load-race` and `--agent-cwd project --deny-root --skip-load-race` (`"/": DONT_TRUST`)
- **Output (trimmed):**
  ```
  trusted:   initialize agentInfo {"name":"bob-shell","title":"Bob","version":"2.0.9"}; matches fixture: true
             session/new ok; session/prompt ok (1696 ms) end_turn; session/list 1; load ok; resume ok
             session/load during running turn -> -32600 Invalid request: Session is already running a prompt
             running turn -> ok, end_turn (49 updates before the load, 259 after); session/delete ok
  no entry:              session/new -> ok
  DONT_TRUST:            session/new -> -32600 Workspace "<project>" is not trusted. Pass --trust ...
  gateway cwd, no entry: session/new -> ok
  "/" DONT_TRUST (with or without TRUST_FOLDER for the project): session/new -> ok
  ```
- **Result:** T-32 PASS. T-33 PASS on 2.0.9. T-34 recorded: same as 2.0.7, so F-12 does not hold on either version.
- **Notes:**
  - **Behaviour change in 2.0.9: a folder with no trust entry is trusted.** The run-context builder now contains `A.enabled&&A.trusted===void 0&&!t&&(A={...A,trusted:!0})`, and the ACP path calls it with `t` false. 2.0.7 has no such line. Only a folder marked `DONT_TRUST` is refused. `security.folderTrust.enabled` still defaults to `true` in both versions.
  - **`DONT_TRUST` matches one exact path.** The matcher `kpe(e,t)` normalises both paths and checks `e===t`. `TRUST_FOLDER` also matches subfolders. So `"/": DONT_TRUST` blocks nothing below `/`, and `trustedFolders.json` cannot give a deny-by-default.
  - **Consequence:** F-15 ("Bob refuses `session/new` in an untrusted workspace") no longer holds for new folders on 2.0.9. Bob's trust check is not a folder control. The controls are the gateway `cwd` guard (FR-6), starting Bob with `cwd` = the project (task 3.4), and the container (D-008). PLAN 4.3 can still write `TRUST_FOLDER` at registration, so that projects keep working if Bob brings the old default back.
  - The workspace is still the agent's process directory (`directory:cQe()`, and `cQe(e)` uses `e || process.cwd()`).
  - The gateway-cwd run started Bob in the fork root, and Bob again wrote `.bob/skills/next/SKILL.md` there. The file was removed.

### 2026-11-06 — Race probes: resume during a turn, and a second Bob process (T-34, Q-5)
- **Environment:** as above, Bob 2.0.9. One gateway; each socket gets its own Bob process (D-006). All processes share one disposable `HOME` and one trusted temp project, as one project would on a host.
- **Command:** `set -a; . ./.env; set +a; node gateway/scripts/probe-bob-races.mjs` (run twice; the second run added R0 and waited 1 s after each load before counting replayed updates).
- **Output (second run, trimmed):**
  ```
  [A] R0 session/load (idle, same process) -> ok; result keys ["modes"]; 3 updates: available_commands_update, user_message_chunk, agent_message_chunk; prompts ["[P0]"]
  [A] R1 session/resume during running turn -> -32600 Invalid request: Session is already running a prompt
  [A] R1 running turn -> ok stopReason=end_turn (53 updates before the resume, 373 after)
  [B] R2 session/load in a second process during A's turn -> ok (525 ms)
  [B] R2 session/prompt [PB] in the second process during A's turn -> ok stopReason=end_turn (2195 ms)
  [A] R2 A's running turn -> ok stopReason=end_turn; A kept streaming while B prompted (337 updates)
  [C] R3 session/load in a third process -> ok; replay 7 updates; user prompts in history: ["[P0]","[P1]","[P2]"]
  [C] R3 session/list -> 1 session (the same one)
  agent stderr lines matching lock|SQLITE|busy|conflict|error: 0
  ```
- **Result:** Recorded.
- **Notes:**
  - **R1:** `session/resume` during a turn is refused the same way as `session/load`. The turn is not cancelled.
  - **R2 / Q-5: a second process is not refused, and a write is lost.** The "already running" check only covers sessions in one Bob process. Process B loaded the session and ran a whole turn (`[PB]`, `end_turn`) while process A was mid-turn. Afterwards the stored history holds `[P0]`, `[P1]` and `[P2]` but not `[PB]`. B's turn reported success but is gone from Bob's history. It looks like A's later save overwrote B's (last writer wins; not confirmed in the package source). Bob logged no lock or busy error. So two Bob processes on one project are unsafe without any visible failure. This backs FR-16 and task 3.4 (one agent per project): the phase 1 one-agent-per-socket model (D-006) lets two phone connections corrupt a session's history.
  - **Replay timing:** Bob sends the replayed history as `session/update` notifications after the `session/load` response. A count taken right after the response reads 0. The first run of this probe did that, so its "replay: 0" lines for B and C are not valid. In the second run, B's replay count was still taken right after the response, so it is not measured. C waited 1 s.
  - **Replay is coalesced:** 3 prompts replayed as 7 updates, one `user_message_chunk` or `agent_message_chunk` per message, not the original few hundred streaming chunks. An event log replay (FR-19) and Bob's own replay will differ in shape.

### 2026-11-06 — PLAN 1.13 interim guard (D-015)
- **Environment:** as in the T-1 macOS entry.
- **Command:** `npm test --prefix gateway`; then the new test alone with the old release point restored: `node --test --test-name-pattern=D-015 gateway/test/admission.test.mjs`.
- **Output (trimmed):**
  ```
  with the fix:      ✔ D-015: a closed socket keeps its slot until the agent has exited (993 ms); tests 37, pass 37, fail 0
  old release point: ✖ D-015: a closed socket keeps its slot until the agent has exited
  ```
- **Result:** PASS. The test fails against the old code.
- **Notes:** The fixture `gateway/test/fixtures/slow-exit-agent.mjs` keeps running 600 ms after `SIGTERM`, as Bob may while it saves. On the first try the test closed the socket about 10 ms after spawn, before the fixture had installed its `SIGTERM` handler, so the fixture died at once. The test now waits 300 ms first. `config.example.json` now sets both agent caps to 1. The code defaults stay at NFR-4 (4 and 16), so a config that leaves them out still gets 4 and 16 (see D-015).

### 2026-11-06 — Project start time: Bob on the host vs a fresh container (start on demand)
- **Environment:** MacBook (Darwin 27.0.0, arm64). Podman 5.6.2, `podman-machine-default` (libkrun VM, 2 CPUs, 3.6 GiB). Image `agmente-bob:2.0.9` from the draft `deploy/bob-project.Containerfile` (`node:22-bookworm-slim`, Node 22.23.4, `@ibm/bob@2.0.9`, user uid 10001, 413 MB). Named volumes for `HOME` (with a `TRUST_FOLDER` entry for `/work`) and for the project. Host runs used Bob 2.0.9 with a disposable `HOME`. Image and VM already up and cached.
- **Command:** `set -a; . ./.env; set +a; node gateway/scripts/bench-start.mjs --runs 5`. Each run starts a new Bob (host) or a new `podman run --rm -i --name agmente-bench-<tag>` container, then sends `initialize`, `session/load` of a seeded session (one prompt of history), and `session/new`, then stops it. ACP goes straight over stdio; the gateway adds under 1 ms (T-12).
- **Output (ms from the start command):**
  ```
  host bob 2.0.9 (5 runs)
    initialize  median    834  max    853
    load        median   1363  max   1376   (replay of 3 updates done by 1364)
    sessionNew  median   2196  max   2627
    stopMs      median     14  max     19
  fresh container per run (5 runs)
    initialize  median   1066  max   1075
    load        median   1518  max   1638   (replay done by 1519)
    sessionNew  median   2257  max   2426
    stopMs      median    263  max    277
  same-name second container while one runs: refused: ... the container name "agmente-bench-0222ea" is already in use ...
  ```
- **Result:** Recorded (no NFR covers start time yet).
- **Notes:**
  - A cold start costs about 1.5 s until an existing session is loaded and replayed. That is the delay when a phone reopens a session in an idle project. A new session is ready after about 2.3 s. Most of this is Bob's own start-up (about 0.83 s to `initialize` on the host). The container adds about 0.2 s to `initialize` and about 0.25 s to stop.
  - The container-name lock in D-015 holds: Podman refused a second container with the same name while the first was running.
  - Not measured: the first start after the Podman VM boots, or after the image cache is cleared. Starting the VM itself took 11.8 s here. That cost does not apply on a Linux host, which runs containers without a VM. Measure again on the Linux host after PLAN 1.11.
  - Each run used a model-free path (no prompt), so model latency is not included. The 1-prompt history is small, so the load time for a long session is not measured.

### 2026-11-06 — T-1 and PLAN 0.5 with Xcode; app unit tests
- **Environment:** macOS (Darwin 27.0.0, arm64), Xcode 27.2 (27B52) selected at `/Applications/Xcode.app/Contents/Developer`, iOS 27.2 simulator runtime, Node v24.5.0. Simulator "iPhone 17" (there is no "iPhone 16" in this Xcode; the test command in `CLAUDE.md` now names iPhone 17).
- **Command:** `scripts/check.sh`; then `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:AgmenteTests test`.
- **Output (trimmed):**
  ```
  ACPClient:       Executed 156 tests, with 0 failures; Test run with 9 tests in 2 suites passed
  AppServerClient: Executed 9 tests, with 0 failures
  check.sh: exit 0, "All checks passed."
  AgmenteTests:    Test Suite 'All tests' passed; Executed 121 tests, with 0 failures (0 unexpected);
                   Test run with 10 tests in 2 suites passed
  ** TEST SUCCEEDED **
  ```
- **Result:** T-1 PASS. PLAN 0.5 PASS. App unit tests PASS.
- **Notes:** `CodexThreadReadMergeFixtureTests` reads its fixtures from the source tree (`#filePath`) under `~/Documents`. The first run blocked in `open()` for about 20 minutes until the owner allowed macOS file access for the Simulator. A stack sample showed `loadFixtureURLs` → `contentsOfDirectory` → `open`. The 1,474 s run time includes that wait. The UI tests (`AgmenteUITests`) were not run.

### 2026-11-06 — Phase 2: 2.5, 2.1, 2.2, 2.8, 2.3, 2.4 (T-14, T-15, T-16)
- **Environment:** macOS, Xcode 27.2, iOS 27.2 simulator "iPhone 17".
- **Commands:** `swift test --package-path AgmenteTransport|ACPClient|AppServerClient`; `xcodebuild ... -only-testing:AgmenteTests test`; `xcodebuild ... -only-testing:AgmenteUITests test`.
- **Output (trimmed):**
  ```
  AgmenteTransport: Executed 7 tests, with 0 failures (3 runs in a row)
  ACPClient:        Executed 158 tests, with 0 failures   (156 before, plus 2 EndpointPolicyTests)
  AppServerClient:  Executed 9 tests, with 0 failures
  AgmenteTests:     Executed 133 tests, with 0 failures  (121 before, plus KeychainStore 4, ServerSecretMigration 2,
                    StoreProtection 2, TransportPolicy 4); includes CodexServerViewModelTests and ViewModelSyncTests
  AgmenteUITests:   ** TEST SUCCEEDED **; testExample, testLaunchPerformance, testLaunch x4 passed;
                    testCodexDirectWebSocketConnectInitializeAndSessionFlow skipped (opt-in E2E)
  store protection attribute on this platform: nil   (the simulator does not report data protection)
  ```
- **Result:** T-14 PASS, T-15 PASS, T-16 PASS. PLAN 2.1 to 2.5 and 2.8 done.
- **Notes:**
  - **2.5:** new local package `AgmenteTransport` (`NativeWebSocketConnection`). The two `URLSessionWebSocketProvider.swift` files are now adapters, and neither package's public API changed. `AppServerClient` raised its macOS minimum from 10.15 to 13 to match. `scripts/check.sh` tests the new package. The Xcode project needed no edit: `AgmenteTransport` resolves as a path dependency of the two local packages.
  - **2.2:** `ServerSecretMigration` runs on every `fetchServers`. `SessionStorage` reads secrets from the Keychain, writes them there, stores nil in Core Data, and deletes Keychain items with the server. `SessionStorage.inMemory()` uses its own Keychain service.
  - **2.8:** `NSPersistentStoreFileProtectionKey = .complete`, SQLite `secure_delete = ON`, and `isExcludedFromBackup` on the `.sqlite`, `-wal` and `-shm` files at each launch. A store that fails to load now falls back to memory (`PersistenceController.loadError`) instead of `fatalError`. No screen shows that error yet. The erased-bytes test passes, but it also passed with `secure_delete` set to `OFF`, because migration overwrites the row in place and the checkpoint replaces the page. So the test confirms that no token bytes remain after migration, and does not show the effect of `secure_delete`. `secure_delete` protects deleted rows. It does not clean free pages that older app versions left; a one-time `VACUUM` would (not done).
  - **2.3:** `TransportPolicy` (D-018, D-019); model version `Agmente 2` adds `localOnly` (Boolean, default NO) and `spkiPins` (String, optional), and the `scheme` default becomes `wss`. `ACPClientManager.endpointPolicy` checks every connect and reconnect: a refused endpoint makes no connection and is not retried. `validateServerConfiguration` checks the policy before it builds a client. The add-server form has a "Local only" toggle (`LocalOnlyToggle`) and a warning (`LocalOnlyWarning`), and offers `ws` only when "Local only" is on or in Debug builds. No existing test needed a change: they use mocks, or `ws://127.0.0.1`, which Debug builds still allow. The sidebar's connection picker still lists `ws`; the policy refuses it at connect time.
  - **2.4:** the cap is checked on the declared frame length (and the reassembled length for continuation frames) before the payload is buffered. Control frames are not counted. On overflow the client sends close 1009, half-closes, cancels after 250 ms and returns `.closed(1009)`. Before that half-close, the test showed that cancelling at once could lose the close frame at the peer (a TCP reset with unread data).
  - **Upstream bug found and fixed:** `receive()` read the network after a ping, pong or non-final fragment even when the next frame was already buffered. Back-to-back frames, for example a ping followed by a message, could then stall until more data arrived. `testControlFramesAreNotCountedAgainstTheCap` hung on the old loop and passes on the new one. T-16 also hangs, rather than failing, against code without the cap (the client waits for the 17 MiB payload).

### 2026-11-06 — Phase 2: 2.6 (T-17), 1.10, 2.7, and the full regression
- **Environment:** macOS, Xcode 27.2, iOS 27.2 simulator "iPhone 17", LibreSSL 3.3.6 (`/usr/bin/openssl`), Caddy v2.11.9 (Homebrew), Node v24.5.0.
- **Commands:**
  - `swift test --package-path AgmenteTransport` (two runs in a row)
  - `scripts/make-client-cert.sh --dry-run iphone`; `scripts/make-client-cert.sh --out <scratch>/ca testphone`; `openssl verify -CAfile <scratch>/ca/ca.pem <scratch>/ca/testphone.pem`
  - Local stack, all on loopback: gateway (`--config <scratch>/gateway.json`, fake agent, port 18787, `trustProxy` true, caps 1); `caddy run` with `skip_install_trust`, `tls internal`, `client_auth { mode require_and_verify; trust_pool file <scratch>/ca/ca.pem }`, site `https://localhost:18443`. Then `AGMENTE_MTLS_*=... xcrun xctest -XCTest AgmenteTransportTests.MutualTLSLiveTests`.
  - `scripts/check.sh`; `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test`
- **Output (trimmed):**
  ```
  SPKIPinTests: testPinMatchesOpenSSLForEachKeyType passed (RSA 2048, RSA 4096, P-256, P-384)
                testT17WrongPinFailsTheHandshake passed: right leaf pin -> TLS passed; CA pin -> TLS passed;
                wrong pin -> refused (-9808); right pin without a trusted anchor -> refused
  make-client-cert.sh: --dry-run prints 8 commands and writes nothing;
                testphone.pem: OK   (EC prime256v1, ecdsa-with-SHA256, TLS Web Client Authentication; keys and .p12 -rw-------)
  local Caddy, curl:  no client cert -> handshake failure (000); cert + upgrade, no token -> HTTP/1.1 401 (Via: 1.1 Caddy)
  MutualTLSLiveTests: no identity -> tlsRefused; identity, no token -> http(401); identity + token -> connected
                (ACP initialize round trip through Caddy, gateway and fake agent)
  AgmenteTransport: Executed 12 tests, with 1 test skipped (the opt-in live test) and 0 failures
  check.sh: gateway 37/37, docs ok, AgmenteTransport 12 (1 skipped), ACPClient 158, AppServerClient 9; "All checks passed."
  App:      Executed 137 tests, with 0 failures; ** TEST SUCCEEDED ** (UI tests included; the Codex E2E test skipped, opt-in)
  ```
- **Result:** T-17 PASS. PLAN 1.10 PASS. PLAN 2.6 and 2.7 done; the 2.7 check passed against a local Caddy. Repeat it on the host after PLAN 1.11.
- **Notes:**
  - **2.6:** `TransportTLSOptions` (pins, trust anchors, client identity) sits in `AgmenteTransport` and is passed from `ACPConnectionConfig` through `ACPClientConfiguration` to the provider. `ACPClient` re-exports `AgmenteTransport`. The verify block runs only when pins or anchors are set: it runs `SecTrustEvaluateWithError` first, and then needs one certificate in the chain to match a pin. Pins are base64 SHA-256 SPKI values (an optional `sha256/` prefix is accepted). The pin value equals `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`. The form has a "Certificate pins" field (`SPKIPinsField`), stored in Core Data `spkiPins` (not a secret).
  - **2.7:** `ClientIdentityStore` imports a `.p12` (`SecPKCS12Import`; the passphrase is not stored) and keeps the identity in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, one per server. The form has import and remove buttons (`ImportClientCertificateButton`, `RemoveClientCertificateButton`). The identity is deleted with the server. `ClientIdentityStoreTests` embeds a throwaway self-signed test `.p12` (CN=agmente-test-client, passphrase in the test). It is not a credential for any server. `scripts/check.sh` looks only for PEM private keys, so it does not flag this base64 test fixture.
  - **1.10:** output goes to `secrets/client-ca/` by default, which is now in `.gitignore`. The `.p12` passphrase is random and printed once to stderr. The `.p12` uses PBE-SHA1-3DES so that iOS can import it (verify on new iOS releases).
  - **Found while testing, all fixed in `AgmenteTransport`:**
    1. LibreSSL writes EC keys with explicit curve parameters (`-newkey ec -pkeyopt ec_paramgen_curve`), and signs with SHA-1 by default. Apple's Security framework rejects both (`SecCertificateCopyKey` returns nil; "broken signature algorithm"). The script and the tests use `ecparam -param_enc named_curve` and `-sha256`. LibreSSL `req -x509 -key` without `-new` reads a request from stdin and hangs.
    2. Upstream `connect()` had no deadline. There is now one (15 s by default) over TCP, TLS and the WebSocket handshake. Test: `testConnectTimesOutWhenTheServerNeverAnswers`.
    3. With TLS 1.3, a server that rejects a missing client certificate does so after the client reports `.ready`. The pending handshake read then never returned. A `.failed` state after `.ready` now cancels the connection, so pending reads end.
  - **Caddy and SNI:** a connection by IP sends no SNI. Caddy's client-auth policy did not match, the handshake completed without a client certificate, and every request got HTTP 421. Clients must use the host name. This is noted in `deploy/Caddyfile`.
  - The local Caddy, the gateway and all keys lived in the scratch folder and were stopped and left there. Nothing was added to the system trust store (`skip_install_trust`; Caddy logged "root certificate trust store installation disabled").


### 2026-11-06 — Wire-level gateway tests, and the Go gateway (D-021)
- **Environment:** macOS, Node v24.5.0, Go 1.27.3 (Homebrew), `github.com/coder/websocket` v1.8.15.
- **Commands:**
  - `npm test --prefix gateway` (Node gateway, the default target), three runs
  - `go vet ./... && go test ./... && go build -trimpath -o bin/agmente-gateway ./cmd/agmente-gateway` (in `gateway/`)
  - `AGMENTE_GATEWAY_CMD='["<abs>/gateway/bin/agmente-gateway"]' npm test --prefix gateway`, four runs
  - `node gateway/test/bench.mjs` with and without `AGMENTE_GATEWAY_CMD`
  - Idle RSS: each gateway started on the example config (port 0, one empty root), `ps -o rss` after 2 s, no connections
  - `scripts/check.sh`
- **Output (trimmed):**
  ```
  Node gateway: tests 53, pass 53, fail 0   (before the U+2028 fix: 52/53, see notes)
  Go gateway:   tests 53, pass 53, fail 0   (4 runs in a row; about 5.4 s each)
  go test:      ok agmente/gateway/internal/jsonv; ok agmente/gateway/internal/server
  bench, 2000 calls, 1 KiB:   Go   gateway p95 0.163 ms, direct p95 0.143 ms, overhead p95 0.020 ms; reject p95 0.348 ms (n=500)
                              Node gateway p95 0.177 ms, direct p95 0.044 ms, overhead p95 0.133 ms; reject p95 0.358 ms
                              spawnedDuringRejects 0; nfr1 PASS, nfr2 PASS (both)
  idle RSS:     Go 12.9 MB; Node 58.1 MB
  check.sh:     Go vet/test/build ok; wire suite 53/53 on Go and on Node; docs ok;
                AgmenteTransport 12 (1 skipped), ACPClient 158, AppServerClient 9; "All checks passed."
  ```
- **Result:** T-2 to T-10 and T-13 PASS on both gateways, over the wire. T-11 and T-12 PASS on both. T-5 is checked through the CLI.
- **Notes:**
  - **The suite is wire-level now (D-021).** `gateway/test/helpers.mjs` starts the gateway from `AGMENTE_GATEWAY_CMD` (a JSON array; default the Node gateway), writes a real config file, and reads the audit log from stderr. Agent spawn counts come from `connect` audit lines; the old in-process `stats` counters are gone. Config checks run through `--dry-run` and the exit code.
  - **Old tests and what replaced them** (none was dropped or loosened):
    - Unit tests of `parseBearer`, `findTokenEntry`, `FailureLimiter`, `LineSplitter`, `isInsideRoots`, `parseClientMessage`, `isLoopbackAddress` and `validateConfig` became wire tests of the same cases: header variants at the upgrade, lockout expiry with `lockoutSeconds: 1`, chunked agent output (`_test/chunks`), a `<root>-evil` sibling, each bad message shape, each listen host through `--dry-run`, and each config error through stderr.
    - `buildAgentEnv` is covered by the env test: one passed variable with its value, and an unlisted secret that must be absent.
    - "a valid config is normalized and frozen": the defaults are checked in the dry-run summary. Freezing is a JavaScript detail and is not observable over the wire.
    - The backpressure test now checks for a `backpressure` audit line (`dir: "in"`) instead of an in-process counter. Both gateways write that line.
  - **New cases:** argv passed without a shell; ids, values, client responses and notifications pass through; CRLF and blank agent lines; last output before exit; a command that cannot start (1011, slot freed); SIGKILL after the grace period for an agent that ignores SIGTERM; shutdown on SIGTERM; audit fields limited to the allow-list with an ISO timestamp; no project path in the audit; bare CR, two trailing newlines, trailing data, a non-string `jsonrpc`, the empty message, invalid UTF-8 (1007); a fragmented message over the cap (1009); a message of exactly the cap (accepted); refusal ids echoed unchanged; a missing root allows nothing; U+2028 and U+2029; port, token entry, agent, roots and limit errors; unreadable and non-JSON config files; usage exit code 2; the example config.
  - **Bug found, fixed in the Node gateway:** Node's `readline` ends a line at U+2028 and U+2029 (checked: `printf '{"a":"x\xe2\x80\xa8y"}\n' | node -e '...readline...'` prints two lines). The Node gateway re-serialized with `JSON.stringify`, which leaves both raw, so a phone message containing U+2028 reached the fake agent as two lines and got no reply. The Node gateway now escapes both characters; the Go encoder always escapes them. Test: "U+2028 and U+2029 in a message cannot split it into two agent lines". Not verified: whether Bob's stdin reader splits on them.
  - The bench now measures the gateway named by `AGMENTE_GATEWAY_CMD`.
  - The old in-process figure of 75 MB idle for the Node gateway (Phase 3 planning) and today's 58 MB differ in setup; both are this Mac, idle, no agent.

### 2026-11-06 — Node gateway removed (D-022); Bob probes through the Go gateway
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, `@ibm/bob` 2.0.9 (global), `BOB_API_KEY` from `.env` (never printed).
- **Commands:**
  - `scripts/check.sh`
  - `node gateway/scripts/probe-bob.mjs --trust-project`
  - `node gateway/scripts/probe-bob-races.mjs`
  - Wrapper check: `/bin/sh -c 'exec "$@" 2>>file' sh node -e '<one stderr line, one stdout line>'`
- **Output (trimmed):**
  ```
  check.sh: Go vet/test/build ok; wire suite 53/53 (Go, the only target); dry run ok; docs ok (22 decisions);
            Swift packages pass; "All checks passed."
  probe-bob: initialize matches fixture (ignoring version): true; session/new outside roots -> -32602;
             prompt end_turn; load (idle) ok; resume (idle) ok;
             load during running turn -> -32600 "Session is already running a prompt"; running turn end_turn
             summary {"T32":true,"sessionNew":true,"prompt":true,"load":true,"resume":true,"Q1":"end_turn"}
  races:     R1 resume during turn -> -32600, turn end_turn; R2 second-process load ok, prompt end_turn, A end_turn;
             R3 history prompts ["[P0]","[P1]","[P2]"] (B's [PB] missing); agent stderr lines matching lock|SQLITE|busy|conflict|error: 0
  wrapper:   stdout passed through; the stderr line landed in the file
  ```
- **Result:** T-32, T-33 and T-34 PASS again through the Go gateway, with the same Bob behaviour as through the Node gateway (F-12). F-21 reproduces through the Go gateway: the second process's completed prompt is missing from the history, and Bob logs no lock error.
- **Notes:** `gateway/src/` and `gateway/scripts/new-token.mjs` are deleted. The wire suite and the bench default to `gateway/bin/agmente-gateway`. Both probes now start the gateway as a process (`spawnGateway` in `gateway/test/helpers.mjs`), with the agent's working directory and a disposable `HOME`. The race probe keeps Bob's stderr with an `sh -c 'exec "$@" 2>>file'` wrapper in its own config, checked above.

### 2026-11-06 — Phase 3 task 3.1: the fake agent copies Bob's behaviour
- **Environment:** macOS, Node v24.5.0, Go 1.27.3.
- **Commands:** `node --test gateway/test/fake-agent.test.mjs`; `scripts/check.sh` (two runs).
- **Output (trimmed):**
  ```
  fake-agent.test.mjs: 9 pass, 0 fail
  check.sh (x2): wire and fixture tests 62, pass 62, fail 0; "All checks passed."
  ```
- **Result:** PLAN 3.1 done. The new tests in `gateway/test/fake-agent.test.mjs` talk to the fake agent over stdio, with no gateway, and check each behaviour that phase 3 relies on:
  - Slow turns: `[chunks:N]` and `[slow:MS]` directives in the prompt. Every update arrives before the prompt response, and the first turn sends `session_info_update` with the title.
  - F-12: `session/load` and `session/resume` during a turn return `-32600` "Invalid request: Session is already running a prompt" with `data.sessionId`, and the turn completes. When idle, the response (`{modes}`) comes first, then the replay: `available_commands_update`, then one `user_message_chunk` or `agent_message_chunk` per message.
  - Persistence: a JSON store (`--store <file>`, default `$HOME/.fake-agent/store.json`, memory only without `HOME`). A new process lists and loads the session. `session/delete` removes it.
  - `session/request_permission` (`[permission]`): the turn waits for the answer; allow gives `tool_call_update` `completed`, reject gives `failed`. `session/cancel` ends a turn that is waiting or streaming, with `stopReason: "cancelled"`.
  - F-21: process B loads and completes a turn while A is mid-turn; neither is refused. A third process then sees `[P0]`, `[P1]`, `[P2]` and not `[PB]`, the same result as the live race probe.
- **Notes:**
  - Shapes that no Bob probe has shown, marked "verify" in the fixture: `modes.currentModeId`, `cwd` and `updatedAt` in `session/list`, and the permission option ids and kinds.
  - Not modelled on Bob: a prompt for a session that is not loaded in this process is refused with `-32602`, and a second prompt during a turn with `-32600`. What Bob does in these two cases has not been probed.
  - The live order of `available_commands_update` differs: Bob sends it during the first turn; the fake sends it only at the start of a replay.
  - All 53 earlier wire tests still pass with the extended fake agent.

### 2026-11-06 — Phase 3 task 3.2: SQLite driver (D-023)
- **Environment:** macOS, Go 1.27.3, `modernc.org/sqlite` v1.61.1.
- **Commands:** `go test -v -count=1 ./internal/store/` (in `gateway/`); a throwaway `main` that imports only the store, built with `go build -trimpath`; `scripts/check.sh`.
- **Output (trimmed):**
  ```
  TestOpenUsesWALAndCreatesTheSchemaOnce   PASS   (journal_mode wal; 5 tables; state dir 0700; reopen does not migrate again)
  TestANewerSchemaIsRefused                PASS
  TestSeqStartsAt1AndIncreasesBy1PerSession PASS
  TestTenThousandEventsWriteAndReplay      PASS   10000 events (355 bytes each): write 552.554042ms (one commit each), read 25.740667ms
  TestCommittedEventsSurviveSIGKILL        PASS   acknowledged 500, present after SIGKILL 501
  size probe: store + driver alone 8.8 MB; gateway today 9.8 MB (store not linked in yet)
  ```
- **Result:** PLAN 3.2 done: `modernc.org/sqlite` chosen by the owner (D-023). The new `gateway/internal/store` package opens `gateway.db`, creates schema version 1, appends events with `seq` starting at 1 per session, and reads them back in order.
- **Notes:** The store-level SIGKILL test is not T-20: T-20 kills the gateway itself and is checked in task 3.5. The 10,000-event read is not T-19 either; T-19 replays through `_agmente/sessions/subscribe` in task 3.6. The child process wrote one event past the last one the parent counted ("present 501") because the kill came after that commit; nothing acknowledged was lost.

### 2026-11-06 — Phase 3 task 3.3: project registry (T-25, D-024)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test gateway/test/projects.test.mjs`; `scripts/check.sh` (two runs).
- **Output (trimmed):**
  ```
  ✔ T-25: a project outside the roots, or reached through a symlink that leaves them, is refused
  ✔ names and default modes are checked
  ✔ a project inside a root is registered with its realpath, a HOME and a trust entry
  ✔ _agmente/* requests are answered by the gateway and never reach the agent
  ✔ projects persist across a gateway restart
  ✔ stateDir is required and must be absolute
  ✔ the gateway refuses to start when it cannot open its database
  check.sh (x2): Go store test added; wire and fixture tests 69, pass 69, fail 0; "All checks passed."
  gateway binary: 15.8 MB with SQLite linked in (9.8 MB before)
  ```
- **Result:** T-25 PASS. PLAN 3.3 done.
- **Notes:**
  - T-25 cases, each refused with `-32602` and with no project home created: a folder outside the roots; a symlink inside a root that points outside (with and without a trailing slash); a `<root>-evil` sibling; `../..` out of a project; `/`; a missing path; a file; a relative path; the empty string; a number; null.
  - Accepted: a symlink that stays inside the root, stored as the target's realpath; a root itself. A second registration of the same folder, by either path, is refused with the existing project's id.
  - `config.example.json` gains `"stateDir": "/var/lib/agmente/state"`, which the systemd unit already allows to be written (`ReadWritePaths=/var/lib/agmente`).
  - Still in the phase 1 model: every socket spawns its own agent (D-006). Task 3.4 replaces that with one agent per project.

### 2026-11-06 — Phase 3 task 3.5: event log (T-20, D-027)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0 (`node:sqlite` for reading `gateway.db` in the tests).
- **Commands:** `node --test gateway/test/eventlog.test.mjs`; `scripts/check.sh` (two runs).
- **Output (trimmed):**
  ```
  ✔ FR-18: a turn is logged in order with seq 1, 2, 3...: turn_started, the updates, turn_ended
  ✔ each session has its own sequence; messages without a session and responses are not logged
  ✔ a permission request is logged as phones see it, under the gateway id
  ✔ a turn cut short by the agent exiting ends with turn_ended and the error
  # T-20: received 304 updates before SIGKILL; logged 304; 305 events, seq 1..305
  ✔ T-20: after SIGKILL of the gateway and a restart, every event a phone received is in the log
  check.sh (x2): wire and fixture tests 82, pass 82, fail 0; "All checks passed."
  ```
- **Result:** T-20 PASS. PLAN 3.5 done.
- **Notes:**
  - T-20 method: a 3,000-chunk turn streams to a phone. After the phone has received at least 300 updates, the test SIGKILLs the gateway and starts a new gateway on the same `stateDir`. The 304 updates received are the first 304 logged updates, equal message by message and in the same order. `seq` runs from 1 to 305 with no gap (`turn_started` plus 304 updates). The restarted gateway lists the project.
  - The logged updates of a normal turn equal, message by message, what the phone received.
  - Still to come: task 3.6 replays the log to subscribers (T-18, T-19); task 3.7 stops Bob's load replay from entering the log (T-21).

### 2026-11-06 — Phase 3 task 3.7: load and resume guard (T-21, D-029)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test --test-concurrency=1 gateway/test/reopen.test.mjs` (10 runs in a row); `scripts/check.sh` (2 runs).
- **Output (trimmed):**
  ```
  ✔ T-21: reopening a session while its turn runs: no load reaches the agent, the turn completes, history is replayed once
  ✔ T-21: reopening an idle session: answered with the current mode, history from the log, nothing logged, nothing sent to the agent
  ✔ T-21: after an agent restart, one load reaches the agent; its replay goes to that phone and stays out of the log
  ✔ T-21: a phone that reopens during a permission request gets the open request and can answer it
  reopen.test.mjs: 10 runs, 0 failed
  check.sh (2 runs): wire and fixture tests 95, pass 95, fail 0; "All checks passed."
  ```
- **Result:** T-21 PASS. The fake agent refuses a load or resume during a turn and rebuilds and replays when idle, as Bob 2.0.9 does (F-12). In every T-21 case `_test/received` shows the agent got no `session/load` or `session/resume` for a live session. The turn completed with `end_turn`, and the log held only the turn's own events (303 for a 300-chunk first turn), with no `user_message_chunk` or `available_commands_update` from a replay. After an agent restart, two phones reopened at once and one also prompted straight away: the new agent got exactly one `session/load`, and the prompt ran after it. PLAN 3.7 done.
- **Notes:**
  - Method: the mid-turn case reopens with `session/load` and with `session/resume` from two new sockets during a 300-chunk turn (5 ms between chunks). Each gets the cached `session/new` result first, then the prompt as one `user_message_chunk` and the reply exactly once, equal to the log converted to plain updates. The idle case also checks that the cached mode follows `session/set_mode`, and that a subscribed socket gets only the response.
  - Mutation checks: with live reopens forwarded to the agent, all four tests fail. With the replay window closed at the load response instead of at the fence, the restart test fails, because a prompt sent straight after the load let replayed history into the log. That race led to the fence (D-029).
  - Changed test, not loosened: the D-009 test "the first answer wins" in `supervisor.test.mjs` failed once in `check.sh`. It sends b's answer and then a's on two sockets, which the gateway reads independently, so the order was not guaranteed. Run alone 30 times, it failed 11 times against this gateway and 15 times against the gateway before 3.7. The test now sends a's answer only after the agent has b's. Its assertions are unchanged, and it then failed 0 of 30 times.
  - Differs from the plan note: after a restart the agent's replay is not dropped. It goes to the phone that sent the load (only to that phone, and not logged), so that phone sees the session's full history from Bob, including turns from before the gateway logged them.
  - Not tested: Bob itself behind the guard (the fence assumes Bob writes its replay before it answers the next request: verify, with the T-34 probes); `session/close` and `session/delete` removing a live session; a reopen when the log cannot be read.

### 2026-11-06 — Phase 3 task 3.8: session index and read markers (D-030)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test --test-concurrency=1 gateway/test/sessions.test.mjs`; `scripts/check.sh` (2 runs).
- **Output (trimmed):**
  ```
  ✔ index lists every session with project, title, status, last activity and unread, newest first
  ✔ index status: running during a turn, awaiting_approval during a permission request, error after an agent death, idle again after a turn
  ✔ read markers are shared by every device of an identity, not by other identities
  ✔ index survives a gateway restart and starts no agent; a deleted session leaves the index
  check.sh (2 runs): wire and fixture tests 99, pass 99, fail 0; "All checks passed."
  ```
- **Result:** PASS. FR-21 has no T-n in SPEC section 7. These tests check it, and FR-25 for read markers. PLAN 3.8 done.
- **Notes:**
  - Method: one test per area: fields, order and filter; each status from live state; read markers with two devices of one identity (a third test token, `tablet`, for `owner`) and one device of another; the index after a gateway restart, and after `session/delete`.
  - Mutation checks: with the identity ignored, the read-marker test fails. With `running` never set, the status test fails.
  - Not tested: `status` with several projects running at once; an index with many sessions (the unread count scans each session's events after its marker, and there is no index on `kind`); sessions in Bob's store that never went through the gateway, which are not listed (D-030).
  - The wire suite prints `MaxListenersExceededWarning` from the `rpc` test helper, which adds a close listener on every call. It is harmless and not new.

### 2026-11-06 — Phase 3 task 3.9: approval queue with timeout (T-22, T-23, D-031)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test --test-concurrency=1 gateway/test/approvals.test.mjs` (10 runs in a row); `(cd gateway && go test ./...)`; `scripts/check.sh` (2 runs).
- **Output (trimmed):**
  ```
  ✔ T-22: two devices answer one request: the first answer goes to the agent, the second gets "answered elsewhere"
  ✔ T-23: with no answer past the timeout the agent gets a reject option, or cancelled when there is none; never an allow
  ✔ pending lists open approvals; the answer method checks its params
  ✔ session/cancel answers the open approval with cancelled; an agent exit closes it
  ✔ a gateway restart closes open approvals, and new approval ids do not repeat old ones
  approvals.test.mjs: 10 runs, 0 failed
  go test: TestRejectOutcomeNeverAllows ok
  check.sh (2 runs): wire and fixture tests 104, pass 104, fail 0; "All checks passed."
  ```
- **Result:** T-22 PASS. T-23 PASS (timeout 1 s in the test; the agent got `cancel` (reject_once), or `cancelled` for a request with only allow options, after 1.0 to 1.1 s; no allow in any case). PLAN 3.9 done.
- **Notes:**
  - T-22 method: two identities on two sockets. Method then method; method then plain response (the plain one gets `_agmente/notice` "answered elsewhere"); then 10 rounds of both answering at once. Each round has exactly one winner, and the agent received exactly one answer per request (12 in all).
  - T-23 method: `limits.approvalTimeoutSeconds: 1`, one `[permission]` request and one `[permission:allow-only]` request (new fake-agent directive: only allow options), no answer. The agent's answer is checked against the request's options: never an `allow_*` kind. A late answer gets "timed out", and the `approvals` row shows `answered_by` `timeout`.
  - Gateway race found by the full check: the first `check.sh` runs failed T-22, in the concurrent rounds. The losing answer got "unknown approval" because the winner had not stored its answer yet. The gateway now keeps who claimed an approval in memory until it is stored (D-031). Two `check.sh` runs and 10 runs of the file then passed.
  - Gateway bug found while writing the tests: `_agmente/approvals/answer` without `cancelled` dereferenced a nil value and panicked. The panic did not stop the gateway, but that socket never got an answer. Fixed. A guard was also added in the history replay (`subscribe.go`) for a logged prompt with no `prompt` field, which the gateway never writes. The socket handler has no recover of its own, so a future panic would again leave a socket hanging.
  - My test errors, corrected and not loosened: T-23 first expected `end_turn` after a `cancelled` outcome, but under ACP that cancels the turn (`stopReason: cancelled`). The restart test first stopped the gateway with SIGTERM; that closes approvals as `agent_exit`, so it now uses SIGKILL to test `gateway_restart`.
  - Mutation checks: with the timeout sending the first option (an allow), T-23 fails. With the first answer not claiming the approval, T-22 fails.
  - Changed tests: the dry-run defaults now include `approvalTimeoutSeconds: 43200`, and `extensions` is `["projects", "sessions", "approvals"]`.
  - Not tested: a real 12 h timeout; Bob's own option list (the fake's options are marked "verify"); a plain response whose `optionId` is not one of the options, which is forwarded as the phone sent it.

### 2026-11-06 — Phase 3 task 3.12: idle close and idle stop (T-46, D-032)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0. Podman runner pointed at `gateway/test/fixtures/fake-podman.mjs`.
- **Commands:** `node --test --test-concurrency=1 gateway/test/lifecycle.test.mjs` (5 runs in a row); `scripts/check.sh` (2 runs).
- **Output (trimmed):**
  ```
  ✔ T-46: the first requests start one container, even when several arrive while it starts
  ✔ T-46: idle past the idle time stops the container; the next prompt starts a new one and opens the session again
  ✔ T-46: a pending approval keeps the container running past the idle time; it stops after the answer
  ✔ T-46: a subscriber keeps the container running; it stops once the subscriber leaves
  ✔ T-46: a request during the stop waits for the exit, then starts a new container
  ✔ FR-24: an idle session is closed while another session keeps the project busy; it opens again on use
  lifecycle.test.mjs: 5 runs, 0 failed
  check.sh (2 runs): wire and fixture tests 110, pass 110, fail 0; "All checks passed."
  ```
- **Result:** T-46 PASS. In every case the fake podman's log shows at most one container per project at a time, and Podman never had to refuse a second one. PLAN 3.12 done.
- **Notes:**
  - Method: `limits.idleSeconds: 1`. The fake podman holds the container name as a file and logs each start and exit with a time. The cases:
    - Two sockets send `session/new` during a 400 ms container start: one start.
    - An idle stop came 0.9 to 2.5 s after the last activity.
    - An approval was left open for 2.5 s with no stop; the stop followed the answer.
    - A subscriber stayed for 2.5 s with no stop; the stop came at least 0.9 s after it left.
    - A prompt sent while the agent took 700 ms to exit: the new container started after the old one exited, and the prompt completed.
  - After an idle stop, the same socket prompted again without a load of its own. The new agent received `initialize`, `session/load` (the gateway's), `session/list` (the fence), then the prompt. No replayed update entered the log.
  - FR-24: with one session in a 3 s turn and one idle, only the idle one got `session/close`. The project kept running, and the closed session opened again on its next prompt.
  - Mutation checks: an idle stop that skips the "stopping" state lets the request during the stop reach the dying agent, and that test fails. A busy check that ignores open approvals still passes T-46, because each approval comes inside a running prompt, which keeps the project busy anyway. The approval check is a second guard that no test can isolate with this fake agent.
  - Changed tests: the dry-run defaults now include `idleSeconds: 1800`. The fake agent now answers `session/close`.
  - Not tested: real Podman (PLAN 4.1); stopping a leftover container at gateway start (D-016, not built); Bob's `session/close`.

### 2026-11-06 — Milestone 3A report (sessions core: tasks 3.1 to 3.9 and 3.12)
- **Done:** 3.1 fake agent, 3.2 SQLite (D-023), 3.3 project registry (D-024), 3.4 one agent per project (D-025, D-026), 3.5 event log (D-027), 3.6 subscribe and replay (D-028), 3.7 load and resume guard (D-029), 3.8 session index (D-030), 3.9 approval queue (D-031), 3.12 idle close and stop (D-032).
- **Tests:** T-18, T-19, T-20, T-21, T-22, T-23, T-25 and T-46 PASS. `scripts/check.sh`: 110 wire and fixture tests, Go unit tests and the Swift package tests pass.
- **T-21 stop condition (PLAN):** not triggered. In every T-21 case the agent received no `session/load` or `session/resume` for a live session, and the turn completed. The fake agent copies Bob 2.0.9's recorded behaviour (F-12, T-34).
- **Open before app work (3D):**
  - The guard has not run against real Bob. Two assumptions are marked "verify": Bob writes its whole load replay before it answers the next request (the D-029 fence), and Bob's `session/close` (D-032).
  - The podman runner has run only against the fake podman (PLAN 4.1).
  - A leftover container at gateway start is not stopped yet (D-016).
  - ~~The socket handler has no recover~~: fixed after the report, D-033.

### 2026-11-06 — Crash guard for phone messages (D-033)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `(cd gateway && go test ./internal/server/ -run Panic -v)`; `(cd gateway && go test -race ./internal/server/)`; `scripts/check.sh` (2 runs).
- **Output (trimmed):**
  ```
  --- PASS: TestPanicInAMessageAnswersAndClosesOnlyThatSocket (0.01s)
  go test -race ./internal/server/: ok
  check.sh (2 runs): Go unit tests ok; wire and fixture tests 110, pass 110, fail 0; "All checks passed."
  ```
- **Result:** PASS. A panic while handling one message gives that phone `{"code":-32603,"message":"internal error"}`, then close 1011. A second socket on the same gateway is still answered, and the audit line names the method but holds none of the message's content.
- **Notes:**
  - Mutation check: without the recover, the test fails after its 10 s timeout. The socket stays open with no answer, which is the hang seen in task 3.9.
  - The per-message code moved, unchanged, from the read loop in `handleConnection` into `handleMessage`; the 110 wire tests pass without change.
  - Not covered: a panic in another goroutine (an agent's read loop, a timer). There `net/http` is not involved, so the gateway process exits, as before.

### 2026-11-06 — 3.13 Container exec runner for git (D-034)
- **Environment:** macOS, Go 1.27.3, Podman 5.6.2 (libkrun machine), image `localhost/agmente-bob:2.0.9` (git 2.39.5, user `bob` uid 10001).
- **Commands:** `(cd gateway && go test ./internal/server -run 'Git|Hostile|CleanFilter|Podman' -v)`; `scripts/check.sh`.
- **Result:** PASS for the runner (T-26, T-27 at runner level, see the summary table). All seven new Go tests pass; check.sh passes.
  - T-26: a repo with `core.fsmonitor`, `diff.external` and a textconv driver, each creating a marker. `status` and `diff` through the runner create none. Control: plain git on the same repo creates all three, so the repo is really hostile.
  - T-27: a repo with a required clean filter. Under real Podman, `git status` ran the filter inside the container (git failed on the required filter) and the host path stayed empty. Control: under the host runner the filter creates the marker on the host.
  - Cap: `yes` stops at 2 MiB with `truncated`, in under 3 s. Timeout: the process group is killed, including a child. Environment: `env` lists exactly `PATH HOME GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL GIT_TERMINAL_PROMPT LC_ALL` plus the gateway's own extras; a gateway secret never appears. A failed git keeps its stderr out of the error message.
- **Found while testing:** the first T-27 run was a false pass. Git inside the container refused the repo ("dubious ownership", the folder belongs to the host user), which looked like a filter failure. The test now fails on that message, and the runner passes `-c safe.directory=<project path>` for exactly that folder.
- **Mutation checks:** removing `core.fsmonitor=false` fails T-26; removing `--network=none` fails the podman argument test.
- **Not tested:** timeout and cap through real Podman (the code removes the container by name after a kill; not run live); a Linux host, where uid mapping differs (the project folder's owner vs the container user); no wire test yet, since no method uses `runGit` until 3.14.

### 2026-11-06 — 3.14 git/status, git/diff, git/log (D-035)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, git 2.54.0 (host runner); Podman 5.6.2 machine, image git 2.39.5 (podman measurement).
- **Commands:** `node --test test/git.test.mjs`; `node test/bench-git.mjs`; `node test/bench-git.mjs --podman localhost/agmente-bob:2.0.9`; `scripts/check.sh`.
- **Result:** check.sh passes, 118 wire tests (8 new in `test/git.test.mjs`). T-26 and T-28 PASS. T-29 PASS. T-30: see below.
  - `bench-git`, host runner, 10,000 files, 20 runs: `{"p50_ms":152.5,"p95_ms":194.6,"max_ms":195.8,"pass":true}`.
  - **T-30 on the podman runner: FAIL on this Mac.** The same status in the Bob image takes about 3.0 s per call (container start alone is 0.4 s). The repository sits on a bind mount through the Podman VM (virtiofs), where git's 10,000 file stats are slow; the same repo on the host takes 0.09 s. `git/status` runs three git commands at once (status and two numstats), so under podman they exceeded the 5 s limit and the bench got "git timeout". I did not change the test or the limit. Not measured: a Linux host with a native bind mount, which is the deployment target (NFR-8 says "10,000-file repository", T-47 is also for Linux).
- **Mutation checks (each fails the test named):** no path allow-list → T-28; no single-path deny → T-29; no deny excludes on the whole-tree diff → T-29; no `--no-textconv` → T-26; path not passed as a literal → T-28 (after I added a second file that the glob would also match: the first version of the test let this survive). Removing `core.hooksPath=/dev/null` fails nothing: status, diff and log never run hooks, so it stays as a guard only.
- **Notes:**
  - Git calls run in their own goroutine with a crash guard, so a 5 s git call does not hold up the same socket's other messages.
  - Deny-list matching is on every path component, case-insensitive, so files under a folder named `secrets` are hidden. The whole-tree diff leaves them out through git exclude pathspecs, then names the changed ones from the last status.
  - Not built: the per-project additions to the deny-list (PLAN notes); `fromTree` and `toTree` (3.15); the `git/changed` notification (3.16).

### 2026-11-06 — 3.15 Turn snapshots and git/turnDiff (D-036)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, git 2.54.0 (host runner), Podman 5.6.2 and the Bob image (git 2.39.5).
- **Commands:** `node --test test/turndiff.test.mjs`; `(cd gateway && go test ./internal/server ./internal/store -run 'Snapshot|Schema|Open' -v)`; `scripts/check.sh`.
- **Result:** PASS. check.sh passes with 125 wire tests (7 new in `turndiff.test.mjs`) and the Go tests. T-31 passes; T-27 now also covers the snapshot.
  - T-31: the agent writes `new.txt` in a turn; `git/turnDiff {sessionId, turn: 1}` returns a diff that lists it as a new file with `+x`, and nothing else.
  - Turn 2 shows only its own changes (a new file and a deleted tracked file); a file the owner typed between turns is in neither.
  - T-27 for the snapshot: a repo with required clean and smudge filters, `core.fsmonitor` and a hooks folder runs none of them (no marker). Under real Podman a required filter that would fail git does not stop the snapshot.
  - The repository is unchanged by snapshots: same `.git/index`, same objects, same refs, and status differs only by the new file.
  - Secret files written in a turn are named, not shown. A symlink to a file outside the project is not followed or listed; a pipe in the project does not block the snapshot.
  - A folder with no repository: the turn runs, the audit has `snapshot_failed`, and `turnDiff` says "no snapshot for this turn". A turn that is still running says "turn is still running".
  - `git/diff` with `fromTree` and `toTree` takes only tree ids, and a path only from that diff.
- **Mutation checks (each fails the test named):** `hash-object` without `--no-filters` fails the T-27 snapshot test; accepting any file type fails the symlink and pipe test; writing objects into the repository's own store fails the "repository as it was" test. After a first run, the test that adds a symlink during the turn was needed: a symlink present before the turn is in both trees and never shows in a diff.
- **Found while testing:**
  - `update-index -z --index-info` needs `-z` first; the first run failed every snapshot.
  - Under Podman the snapshot failed with git's message "not a git repository". The cause is that the gateway makes its snapshot folder with mode 0700, and the container user (uid 10001) cannot write it, so git cannot create objects. The Go test opens the folders to 0777 as a stand-in. The same mismatch exists for the project home that the agent writes to; the Linux deployment has to map the container user to the host user (PLAN 4.1). Not solved here.
  - The store test counted five tables; it now counts six, and a new test opens a schema 1 database and checks that it keeps its events and gains the table.
  - The T-46 lifecycle tests counted every container start. Git runs now start their own short-lived containers (`agmente-git-…`), so those tests count only the agent's containers; the one-at-a-time rule is unchanged for the agent.
  - The first end-of-turn test edited a file right after the response, and the edit landed in the turn's diff: the end snapshot is taken after `turn_ended` is sent. The test now waits for the diff first. This is a real limit: an edit made in the seconds after a turn ends can count as part of that turn.
- **Not tested:** timing under Podman (7 container runs per snapshot, and 10,000 files over the VM mount were slow in 3.14, so the start snapshot would delay the prompt by seconds or fail at the 5 s limit); a repository with symlinks inside tracked directories; submodules (skipped); two sessions in one project at once (their diffs include each other's changes); more than about 50,000 files (the 2 MiB list cap makes the snapshot fail).

### 2026-11-06 — 3.16 Debounced git/changed (D-037)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, git 2.54.0 (host runner).
- **Commands:** `node --test test/gitchanged.test.mjs`; `(cd gateway && go test -race ./internal/server)`; `scripts/check.sh`.
- **Result:** PASS (NFR-9). check.sh passes with 130 wire tests (5 new) and the Go tests; `-race` is clean.
  - One edit sends one notification whose hash equals the next `git/status` hash. Nothing is sent when nothing changed.
  - A burst of 40 writes over about 2 s sends nothing while it goes on, then one notification after 500 ms of quiet, with the final hash. The gap between any two notifications is at least 450 ms.
  - A change to an ignored file and a change under `node_modules` send nothing. A commit made outside the gateway sends one.
  - Only a socket that asked for the status is told. Two sockets share one watch; it stops when the last one closes. A project that is not a repository starts no watch.
- **Mutation checks:** no quiet-interval wait fails the burst test; notifying without comparing the hash fails the single-edit and ignored-file tests; not skipping `node_modules` fails the ignored test.
- **Found while testing:**
  - The status hash first covered only git's status text, so a second edit to an already modified file (same status, same line counts) gave no notification. The hash now also covers the size and modification time of each listed file.
  - A folder's own modification time changes when an entry is added to it, even inside a skipped folder, so the first version sent a notification for a change under `node_modules`. Folders are now left out of the fingerprint.
  - Two of my test files had `\\n` where a newline was meant; one made `.gitignore` match nothing.
- **Not tested:** the cost of the 500 ms poll on a very large project (the walk stops at 200,000 files); the status run under Podman (3 s on this Mac, so a notification can arrive seconds late); a symlinked project folder.

### 2026-11-06 — Milestone 3B report (git: tasks 3.13 to 3.16)
- **Done:** 3.13 git runner in a container (D-034), 3.14 status, diff and log (D-035), 3.15 turn snapshots and turnDiff (D-036), 3.16 debounced git/changed (D-037).
- **Tests:** T-26, T-27, T-28, T-29, T-31 PASS. NFR-9 (debounce) PASS. T-30 PASS on the host runner (p95 195 ms) and FAIL under Podman on this Mac (about 3 s per call, over the 5 s limit); not run on Linux. `scripts/check.sh`: 130 wire tests, Go unit tests (also with `-race` on `internal/server`) and the Swift package tests pass. T-27 under real Podman is a Go test that runs only where Podman and the image exist.
- **Open before app work (3D):**
  - T-30 on a Linux host with a native mount. The Podman cost on this Mac is the VM mount, not git itself.
  - Container user and file permissions on Linux: the gateway's folders are 0700, and the container user (uid 10001) cannot write them. This stops snapshots, and likely the agent's own home, under rootless Podman. Needs the user-namespace decision in PLAN 4.1.
  - A start snapshot delays each prompt (7 container runs). Not measured under Podman; it may delay by seconds or fail at the 5 s limit, in which case the turn runs without a diff.
  - Per-project additions to the deny-list are not built.
  - The watch polls instead of using OS file events (D-037); a change in a skipped folder is not announced.

### 2026-11-06 — 3.10 Push payload builder (D-038)
- **Environment:** macOS, Go 1.27.3.
- **Commands:** `(cd gateway && go test ./internal/push -v)`; `scripts/check.sh`.
- **Result:** PASS (T-24). Three event types against nine project names (5,000 ASCII characters, 2,000 Japanese, 400 emoji, newlines and HTML, bidi overrides and NUL, combining marks, empty, spaces) all give valid JSON of at most 256 bytes, decode with no unknown field, and hold only the title (project name), a fixed body per event, the session id and the event type. A long name is cut on a character boundary with an ellipsis and uses all the room. A session id of 300 characters is refused.
- **Mutation checks:** no length loop fails; dropping the control-character removal fails; dropping the format-character (bidi) removal fails.
- **Not done (3.11, BLOCKED: needs an APNs `.p8` key and a test device):** delivery, the token store and the gateway method that registers a device token. Nothing calls the builder yet.

### 2026-11-06 — 3.17 Projects and sessions home (app, D-039)
- **Environment:** macOS, Xcode 27.2, iPhone 17 simulator (iOS 27.2), Swift packages and the app built from this checkout.
- **Commands:** `(cd ACPClient && swift test)`; `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test` (the app's unit and UI tests); `scripts/check.sh`.
- **Result:** PASS for the code and unit tests; the simulator run is in the end-to-end entry below.
  - The app reads `_meta["agmente/gateway"]` from `initialize` (`GatewayInfo`: version and extensions). A server without it behaves as before (5 parse cases).
  - `GatewayClient` (new, in the ACPClient package) calls `_agmente/projects/list` and `_agmente/sessions/index` and decodes them; a status the app does not know decodes as `unknown`, so the list still shows.
  - The home shows sessions grouped by project, newest first, with a status badge and an unread count; the new-session sheet picks a project and sends `session/new` with its path. Layout rules are pure code with 6 tests (section and session order, ties, empty projects, orphans, search, totals); the model has 4 tests (load, a failed refresh keeps the list and says why, a late answer from the old server is dropped, no client).
  - Totals: ACPClient package 171 tests pass; the app 158 unit tests pass; `scripts/check.sh` passes (130 wire tests); full `xcodebuild test` including the UI tests: TEST SUCCEEDED.
- **Mutation checks:** removing the stale-answer guard fails the reconfigure test; reversing the section order fails the order test.
- **Not tested:** a gateway with many projects. The home on the simulator: see the end-to-end entry below.

### 2026-11-06 — 3.18 Open by subscribing; X-Client-Id removed (app, D-039)
- **Commands:** as for 3.17.
- **Result:** PASS for the code and unit tests; the simulator run is in the end-to-end entry below.
  - A gateway server opens a session with `_agmente/sessions/subscribe {sessionId, afterSeq}` and never sends `session/load` or `session/resume`, not even in the prompt preflight. A plain ACP server is unchanged (it sends no `_agmente` call).
  - `_agmente/event` notifications are applied for the open session in `seq` order, each once: `session/update` and permission requests through the existing paths, `turn_started` as the user's message, `turn_ended` as the stop reason, `approval_answered` clears the options. A repeat is dropped; a gap resubscribes from the last event applied; a reopen of a session continues from its last event; a finished turn is marked read through `_agmente/sessions/read`.
  - This device's own prompt, which the gateway sends back as `turn_started`, is skipped once.
  - New tests: 9 in `GatewayEventTests` (package) and 11 in `GatewayOpenTests` (app) .
  - `X-Client-Id` is gone: the header, `ACPClientManager.clientId`, its defaults key, the migration, and `Agents.md`'s description. Three tests that tested the persisted client id are replaced by two that check no header is sent and nothing is stored.
- **Mutation checks:** no gateway branch in `openSession` fails the reopen test; the preflight not gated by the gateway fails the failed-subscribe test; applying duplicates fails the events test; no resubscribe on a gap fails the gap test; always replaying from 0 fails the reopen and gap tests; not consuming the echo fails the new "no streaming reply yet" test (the first version of the echo test passed without the code, because the chat's own duplicate check covers that case, so I added the case where it does not).
- **Deviation from the plan:** the last applied `seq` is kept in memory, not in Core Data. A cold start replays the whole log (cleared chat, `afterSeq` 0). Reason: the chat is saved at its own times, so a stored `seq` could get ahead of the stored messages and lose events after a crash; replaying from 0 cannot. Cost: opening a long session after a restart replays all of it (10,000 events took under 1 s in T-19). No Core Data model change was needed.
- **Found while testing:** an `AppViewModel` test must create the model and add the server before it sets the test connection and initializes, because adding a server resets the connection (my first harness got `isInitialized` false and every test passed for the wrong reason, until I added a check).
- **Not tested:** reconnect after a real network drop; images in a replayed prompt; permission cards on screen. The run against a gateway on the simulator: see the end-to-end entry below.

### 2026-11-06 — 3D stop 1: end-to-end run on the iPhone 17 simulator (3.17, 3.18)
- **Setup:** the Debug app (iOS 27.2 simulator) against the real Go gateway with the fake agent and the host runner, on `ws://127.0.0.1:8799` (D-019 allows `ws://` to loopback in Debug). The gateway held one project, "Demo Site", with one session whose first turn (`add a readme [write:README.md]`) had run before the app connected. The token was the test value from the project's own wire-test helper. Driven through the simulator panel; each step checked on a screenshot.
- **Result:** PASS.
  1. Add Server (`ws`, `127.0.0.1:8799`, token) → the app's capability review showed "Bob v2.0.9", the gateway's own `initialize` answer. Saved. After Refresh the dot went green.
  2. The home showed the gateway layout, not the plain list: a project section "Demo Site" with an unread badge 1, and the session "add a readme [write:README.md]", "2 min., 47 sec.", unread 1.
  3. Opening the session showed the logged user message and the agent's reply, rebuilt from the gateway log by `_agmente/sessions/subscribe`.
  4. A new prompt ("second question [chunks:3]") appeared once as the user's message (no echo duplicate), "Thinking…" and the stop button showed, then the reply "echo: second question [chunks:3]" arrived through events and the send button came back.
  5. Gateway side, read through a second socket afterwards: the session's unread count was 0 (the app had marked it read) and `headSeq` 9 (two turns). The fake agent had received `initialize`, `session/new`, `session/prompt`, `session/prompt`: no `session/load` and no `session/resume`.
- **Observations, not fixed:**
  - The "active / idle" counts in the summary card at the top still come from the plain session list, so they read "0 active 0 idle" on a gateway server until a session is opened.
  - After adding a server the dot stays orange until Refresh; the app did not connect by itself (existing behaviour).
  - The session header shows the latest prompt as the title, while the gateway index keeps the first one.
  - The simulator's Agmente had 11 leftover "Test Server" entries, made by the app's own unit tests, which write to the app's real store. I uninstalled and reinstalled the simulator app to start clean; only that simulator's Agmente data was removed.
- **Not covered by this run:** the approvals card on screen, an agent exit mid-turn, a network drop and reconnect, two devices at once, and a gateway behind TLS. Each is covered by unit or wire tests only.

### 2026-11-06 — Summary counts on a gateway home (fix after 3D stop 1)
- **Result:** PASS. The "active / idle" counts at the top of the home now come from the gateway's session statuses: running or waiting for approval is active, everything else is idle. On the simulator (see the approvals run below): "1 active, 1 idle" while one session waited for approval, then "0 active, 2 idle" after it was answered. Unit test: 5 statuses (running, awaiting approval, idle, error, unknown) split 2 and 3; the model reports the counts of what it loaded.
- **Found while testing:** my fake gateway caller recorded its calls without a lock, while the model asks for projects and sessions at once. `testRefreshLoadsProjectsAndSessions` failed once in four runs. The fake now has a lock; three runs passed after.
- **Not covered by a test:** the view reading these counts (one line in `ContentView`); it was checked on the simulator only.

### 2026-11-06 — 3.19 Approvals inbox and banner (app, D-040)
- **Commands:** `(cd ACPClient && swift test)`; `xcodebuild … test` (all app and UI tests); `scripts/check.sh`.
- **Result:** PASS.
  - New in the package: `GatewayApproval` with its options, `pendingApprovals()`, `answerApproval()`, `cancelApproval()`, and `GatewayError.isAlreadyClosed` for `-32001`. 4 tests; the package has 174 tests.
  - New in the app: `ApprovalsInboxModel` (11 tests), the inbox sheet with a card per approval (title, the command when the tool call has one, project and session, age, one button per option the agent offered, "Cancel request"), and a banner on the home ("N approvals waiting"). 5 new tests in `GatewayOpenTests` for the in-session card.
  - The in-session card on a gateway server now answers through `_agmente/approvals/answer`, not a plain response. A request that someone else closed first is dropped from the card and the chat says "This request was already closed: <reason>"; any other failure keeps the options so the person can try again.
  - Nothing answers on its own (D-009): loading, refreshing and receiving a request send no answer, tested in the model and on the card.
  - Refresh: on open, on pull, on a permission or answered event for the open session, and every 15 s while the home is on screen.
- **End-to-end on the simulator:** a local gateway with the fake agent held one finished session and one running a `[permission]` turn. The home showed the "Needs approval" badge, "1 approval waiting" and "1 active, 1 idle". The banner opened the inbox with the card ("Run echo", `echo fake`, "Demo Site · New Chat", Allow once, Always allow, Reject, Cancel request). I tapped Reject. The inbox then said "No approvals waiting"; the gateway had logged one `approval_answered` by `owner/phone`, no approvals left, and the session idle with its title. Back on the home the banner was gone, "0 active, 2 idle". I chose Reject on purpose and did not test an allow option on screen.
- **Mutation checks:** the card not routed through the gateway fails 3 tests; `-32001` treated as an ordinary error fails the closed-elsewhere test; removing a row on any failure fails the retry test; no in-flight guard fails the double-tap test; a late answer of the old server removing the new server's approval fails the reconfigure test (the first version of that test did not catch it, because the new list was empty at that moment; it now uses the same approval id on both servers).
- **Deviation from the plan:** a banner on the home instead of a toolbar badge. Reason: the home toolbar has different placements on iOS 26 and earlier, and a banner is visible on both. The count is the same.
- **Not tested:** the inbox with many approvals or long commands; an approval from a session on another server; a device answering while the sheet is open (the row disappears on the next refresh or on the event, up to 15 s later); the Allow buttons on screen.

### 2026-11-06 — Phase 3 task 3.4: one agent per project (D-025, D-026)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, `@ibm/bob` 2.0.9 (global, host runner), `BOB_API_KEY` from `.env` (never printed).
- **Commands:** `go test ./...` (in `gateway/`); `node --test gateway/test/*.test.mjs`; `true` (two runs); `node gateway/test/bench.mjs`; `node gateway/scripts/probe-bob.mjs --trust-project`; `node gateway/scripts/probe-bob-races.mjs` (two runs).
- **Output (trimmed):**
  ```
  go test:   ok jsonv, server (podman args; host lock exclusive and inherited by the child; HOME replaced), store (sessions belong to one project)
  check.sh (x2): wire and fixture tests 77, pass 77, fail 0; "All checks passed."
  bench:     overhead p95 0.157 ms; reject p95 0.418 ms; spawnedDuringRejects 0; nfr1 PASS, nfr2 PASS
  probe-bob: initialize (gateway, after Bob started) matches fixture ignoring version and the gateway _meta: true;
             session/new outside roots -> -32602; prompt end_turn; load and resume (idle) ok;
             load during running turn -> -32600; running turn end_turn
  races, run 1: Bob's service blocked both long prompts ("ContentFilterError ... Request Blocked", -32603) after about 2 s,
             so the resume and the second socket's load ran when idle. Not a valid run of the check.
  races, run 2: R1 resume during turn -> -32600, turn end_turn;
             R2 second socket: load during A's turn -> -32600; prompt during A's turn -> -32600; A's turn end_turn;
             R3 third socket: history prompts ["[P0]","[P1]","[P2]"]; Bob processes started: 1; stderr lock/error lines: 0
  ```
- **Result:** PLAN 3.4 done; its checks pass: two sockets for one project share one process; a second gateway on the same project is refused while the first one's agent runs; the race probe's second socket reaches the same Bob, and its load is refused. T-7 PASS as revised in D-025. T-8 PASS with routing added.
- **Notes:**
  - **New finding:** Bob 2.0.9 refuses a second `session/prompt` during a running turn with `-32600` "Invalid request: Session is already running a prompt" (race run 2, R2). The fake agent already did this; it is now confirmed.
  - **New finding:** Bob's service can block a prompt with "ContentFilterError ... Request Blocked" (JSON-RPC `-32603`, Internal error) for a prompt that passed minutes earlier (race run 1; the same prompt passed in run 2 and this morning). The probes treat it as a failed turn. Not yet handled in the app.
  - **Bug found and fixed:** a message over the cap must finish its close handshake. The library sends 1009, but nothing then closed the socket, because the socket no longer owns an agent whose exit used to close it. The gateway now calls `Close(1009)` after the read error, which drains the rest of the frame and waits for the peer's close.
  - **Tests changed for the new model** (D-006 behaviour replaced; none loosened):
    - T-3: right token gives 101 and starts no agent; the agent starts on the first project request (`agent_start` with project and pid).
    - T-7: the per-identity cap counts sockets (`maxConnectionsPerIdentity`) and frees on socket close. New test: `maxAgentsTotal` refuses a second project with `-32000`.
    - D-015: "a closed socket keeps its slot until the agent has exited" became "a replacement agent starts only after the old one has exited". It uses `--exit-delay 600`; the audit order is start, exit, start; the exit marker exists before the new agent answers. `slow-exit-agent.mjs` is deleted: the fake agent's `--exit-delay` replaces it.
    - "socket closes with 1011 when the agent exits" became: the pending request gets `-32000` "agent exited", the socket stays open, and the next request restarts the agent.
    - "closing the socket kills the agent (D-006)" became: closing a socket leaves the agent running, and a new socket continues the session by id.
    - "an agent line over maxMessageBytes closes with 1009" became: the agent is stopped, the socket stays open, and the next request starts a new agent.
    - "a command that cannot start closes 1011" became: a JSON-RPC `-32000` "agent failed to start", and the slot is freed (two attempts with `maxAgentsTotal: 1`).
    - "a client response reaches the agent" became: a response to an id the gateway never sent is dropped and audited.
    - The env test also checks `HOME` = the project home and the agent's working directory = the project.
    - The SIGKILL-after-grace test triggers the stop with an oversize line instead of a socket close.
    - Shutdown now also checks that the agent has exited (`ESRCH`).
    - Tests that call the fake agent first register a project and open a session (`useProject` in `helpers.mjs`).
  - **New tests** (`gateway/test/supervisor.test.mjs`): sockets and identities share one process; per-socket responses with clashing ids; a closed socket leaves the agent running; exit handling and restart; a second gateway refused (`agent_error` reason `locked`), and it works after the first stops; `initialize` answered by the gateway with `_meta["agmente/gateway"]`, plus capture; permission fan-out with the first answer winning; routing refusals.
  - **Harness:** gateway processes are now unreferenced and killed when the test process exits, so a timed-out test no longer keeps the runner alive.
  - **Not yet tested:** the podman runner live (arguments only), and the 1013 slow-client close.
  - `config.example.json`: `runner: {kind: "podman", image: "agmente-bob:2.0.9"}`, `maxAgentsTotal` 4, `maxConnectionsPerIdentity` 8. `maxAgentsPerIdentity` and `HOME` were removed from it; `HOME` is now always the project home.

### 2026-11-06 — Phase 3 task 3.6: subscribe and replay (T-18, T-19, D-028)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test --test-concurrency=1 gateway/test/subscribe.test.mjs`; `node gateway/test/bench.mjs`; `scripts/check.sh`.
- **Output (trimmed):**
  ```
  ✔ subscribe answers {headSeq} first, then replays each logged event as _agmente/event
  ✔ afterSeq selects where the replay starts; at or past the head nothing is replayed
  ✔ subscribe refuses an unknown session and a bad afterSeq, and starts no agent
  ✔ T-18: disconnect mid-turn, reconnect and subscribe with the last seq: the turn completes with no gap
  ✔ subscribing while events stream: each subscriber gets 1..head exactly once, in order
  ✔ a subscribed socket gets events instead of plain messages; an attached socket still gets plain ones
  ✔ a permission request reaches a subscriber as an event and is answered with its gateway id
  ✔ a second subscribe on one socket replaces the first: live events arrive once
  # T-19: replayed 10000 events in 160.1 ms   (check.sh run: 149.2 ms)
  ✔ T-19: replaying 10,000 events takes at most 1 s, and the phone is not closed as slow
  bench.mjs: replayMs {events: 10000, n: 10, p50: 138.8, max: 145.6}, nfr6 PASS;
             overheadP95Ms 0.203 (nfr2 PASS), rejectMs p95 0.518 (nfr1 PASS)
  check.sh: wire and fixture tests 91, pass 91, fail 0; "All checks passed."
  ```
- **Result:** T-18 PASS. T-19 PASS (NFR-6: at most 1 s; measured 146 ms max over 10 replays). PLAN 3.6 done.
- **Notes:**
  - T-18 method: phone A subscribes, then sends a 200-chunk turn (5 ms between chunks). After at least 40 events it closes its socket mid-turn. 100 ms later phone B connects and subscribes with A's last seq. B receives last+1 to the head with no gap and no duplicate, ending in `turn_ended` with `end_turn`. A's and B's events together equal the whole log, in order. One agent process ran throughout.
  - The streaming test subscribes four sockets at 20 to 630 ms into a 1,500-chunk turn, each from `afterSeq` 0. Each gets seq 1 to 1,503 exactly once, in order, equal to the log. A mutation check (live events sent at once during the replay instead of after it) makes this test fail; T-18 alone did not catch that mutation.
  - T-19 method: one turn logs 10,000 events with no phone connected. A new socket subscribes from 0; the time runs from sending the subscribe to receiving seq 10,000. The socket queue holds 4,096 messages, so this also shows that the replay waits for the queue instead of tripping the 1013 slow-phone close.
  - Test counts: a fake-agent first turn with `[chunks:N]` logs N + 3 events, because it also sends a `session_info_update` with the title. My first draft of the tests assumed N + 2 and failed on the counts; the expected numbers were corrected, not loosened.
  - Changed test: `initialize` now reports `extensions: ["projects", "sessions"]` (D-028).
  - `bench.mjs` now also measures T-19 (`--replays`, `--events`) and exits 1 if NFR-6 is missed.
  - Not yet tested: the 1013 close when live events pile up during a slow replay, and the 1011 close on a replay read error.

### 2026-11-06 — 3.20 Deep link and push registration (app, D-041)
- **Commands:** `scripts/check.sh`; `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test`; `xcrun simctl openurl` on the simulator.
- **Result:** PASS for the deep link and for permission and token capture. Push to the gateway and delivery are **BLOCKED**.
  - `scripts/check.sh`: "All checks passed" (130 gateway wire tests, Go tests, ACPClient 174, AppServerClient, AgmenteTransport).
  - App: 191 unit tests, 0 failures, TEST SUCCEEDED (175 before, plus 16 new in `DeepLinkAndPushTests`: 6 parsing, 4 routing, 6 push registration).
  - **Simulator, link:** `agmente://session/<Local Gateway id>/<waiting session id>` opened that session, with the permission card still showing its three options and nothing answered (the gateway still listed `agmente-perm-1`). A link with a server id the device does not have showed "Link not opened: That link is for a server this device does not have" and the screen did not change. iOS asks "Open in Agmente?" first; that is the system's prompt.
  - **Mutation checks:** three were run on the 3.20 code before the incident, and each made a test fail. I no longer have a record of the exact changes, so I do not list them; they were not re-run after the rebuild.
- **BLOCKED:** `_agmente/push/register` (no gateway method; needs the owner's approval); the `aps-environment` entitlement and Push capability (needs the Apple account and signing); the APNs `.p8` key and a device for delivery (3.11).
- **Not tested:** a notification tap (no push can reach the simulator build without the entitlement; `simctl push` with the D-038 payload is not run); the Settings row on screen; a link opened while the app is not running.
- **Incident, same day (my mistake):** while cleaning up a mutation check I ran `git checkout -- .`, which reverted every tracked file to the last commit (0068137) and discarded all uncommitted edits to tracked files from 3A to 3D. Untracked files were not touched. I rebuilt the tracked files by replaying my recorded edits onto the commit, then fixed what the replay missed: the `go.mod` and `go.sum` entries for SQLite, the git, snapshot and watch wiring in `server.go`, the file directives of the fake agent (`[write:]`, `[remove:]`, `[symlink:]`), `markSessionUnmaterialized`, `dismissPermissionRequest`, the gateway sections of `ContentView.swift`, the app delegate hook, the Notifications settings row and the URL scheme in `Info.plist`, and decisions D-025, D-026 and D-028 with the PLAN ticks for 3.4 and 3.6. Checked afterwards by the full suites above (130 wire tests, Go tests, 174, 191 and the simulator run). Not provable: that every line of every document is identical to what it was; I compared behaviour through the tests, not text.

### 2026-11-06 — Follow-up to 3.14/3.15: per-project deny-list (D-050) and container user under Podman (D-051)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, git 2.54.0, Podman 5.6.2 with the running machine `podman-machine-default` (libkrun) and image `localhost/agmente-bob:2.0.9`. The machine was under heavy load from other sessions (load average above 400), which matters for the timing notes below. This worktree was behind `main`; it was fast-forwarded to `81ea3c5` first.
- **Commands:** `(cd gateway && go test ./...)`; `node --test test/denypaths.test.mjs test/runner-user.test.mjs test/lifecycle.test.mjs`; `scripts/check.sh`.
- **Check:** `scripts/check.sh` run after the last change (23:20 to 23:25, after the 23:15 pkill notice): "All checks passed." 137 wire tests (130 before, 7 new), 137 pass, 0 fail; 38 Go tests pass, 0 fail, 0 skipped (Podman was available).
- **Result:** PASS for tasks 1 and 2; task 3 not done (below).
- **Task 1, deny-list additions (FR-30):**
  - `_agmente/projects/create` takes `denyPaths` (max 32 entries, 100 characters each, ASCII letters/digits/space/`. _ - / *`; no absolute path, `..`, `.`, empty component, `**`, `?`, `[]`, `\`, `:`, `!`, non-ASCII). Stored in `projects.deny_paths` (schema version 3). A schema 1 and a schema 2 database open, keep their projects, and take the column (Go tests). `create` and `list` return `denyPaths` only when it is not empty.
  - Applied in `git/diff` (path, whole tree, staged, tree ids) and `git/turnDiff`, with the built-ins always tested first.
  - New tests: 5 wire tests in `gateway/test/denypaths.test.mjs` (validation and boundaries; storage and output shape; diff path/whole-tree/staged with `*.db`, `config/prod.yml`, `vault/*`; turnDiff and tree diff; built-ins stay while additions exist and another project is unaffected), Go `TestValidateDenyPaths`, `TestIsSecretForAddsToTheBuiltInsAndNeverRemovesThem`, `TestProjectDenyPathsRoundTripAndSchema2Migration`.
  - **Mutation checks (each fails the tests named):** (a) `isSecretFor` skipping the built-ins when a project has entries fails the Go test and 2 wire tests (git/diff, built-ins stay); (b) `secretExcludesFor` ignoring project entries fails 2 wire tests (git/diff and turnDiff, content would have shown). Both reverted.
  - Existing tests changed: `store_test.go` compares `Project` values with `reflect.DeepEqual` (the struct now holds a slice); the schema 1 migration test also drops the new column when it rebuilds the old shape. No assertion was loosened.
- **Task 2, container user (D-051):**
  - Probe (this Mac): the image user (uid 10001) gets "Permission denied" writing a 0700 host folder by default; with `--userns=keep-id:uid=10001,gid=10001 --user 10001:10001` it writes, and the new file is owned by uid 501 (the gateway user) on the host.
  - The podman runner now adds those flags to the agent run and to every git run; `runner.containerUid` / `containerGid` (optional, 1 to 65535) set another image user. Go test `TestPodmanContainerUserWritesOwnerOnlyFolders` runs under real Podman: the container user writes the project home, the snapshot objects folder and the project folder (all 0700, modes unchanged), the files belong to the host user, and a control run without the flags is refused. `TestSnapshotRunsNoFilterUnderPodman` no longer opens its folders to 0777 and passes (required clean filter, no marker).
  - `fake-podman.mjs` now accepts the two options and refuses a run without them, so the T-46 lifecycle tests also check that the runner passes them. Two argument-string tests were updated for the new flags (`runner_test.go`, `gitexec_test.go`); the rest of each string is unchanged.
  - Start-up cost: 5 runs each, with and without the flags, on the loaded machine: no systematic difference (0.65 to 2.1 s, noise larger than any effect). Not a measurement.
  - **NOT VERIFIED (needs a Linux host):** the minimum Podman version for the `uid=`/`gid=` suboptions; a service user with `/etc/subuid` ranges; SELinux volume labels; a full Bob agent start with the flags (only the git and exec path ran live here); start-up time under T-47.
- **Task 3, per-project watcher skip list:** not done. It needs another column and create parameter, validation, and plumbing into `watch.go` plus a timing test; that is not a small change. `skipDirs` stays hardcoded (D-037).
- **Found while testing:** under heavy machine load, two timing tests failed once each in full runs: `TestGitTimeoutKillsTheProcessGroup` (took 30 s; it passed 3 of 3 alone in 0.5 s) and `TestSnapshotRunsNoFilterUnderPodman` (a git run hit the 5 s limit; it passes alone). I did not change either. The first full run also failed 6 wire tests, which was my fault: `fake-podman.mjs` did not know the new flags; fixed above.

### 2026-11-06 — T-36 image decoding limits (PLAN 5.1, 5.2; D-060)
- **Environment:** macOS, Xcode 27.2, iPhone 17e simulator, `-derivedDataPath /tmp/dd-img`.
- **Command:** `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17e' -derivedDataPath /tmp/dd-img -only-testing:AgmenteTests/ForkMediaTests test`, and `swift test --package-path ACPClient`.
- **Output (trimmed):**
  ```
  T-36 50MP PNG: encoded 231825 bytes, output 2048x1600, peak increase 17 MiB
  ForkMediaTests: 17 tests passed (small png/jpeg/gif, MIME normalization, svg + 6 other MIME refused, declared png with jpeg data,
    non-image data, bad base64, truncated/corrupt PNG, base64 over limit, >20 MiB decoded, 108 MP bomb (growth < 50 MiB), 30000 px side,
    ingest placeholders, resource_link row, mapper)
  ACPClient: 165 XCTest, 0 failures (7 new in ContentBlockParsingTests)
  Existing app suites unchanged and passing: CodexServerViewModelTests, ViewModelSyncTests, ACPSessionViewModelTests (73 XCTest), ChatRenderingTests
  ```
- **Mutation checks (each made a test fail, then the file was restored):** pixel and side limits removed -> `hugePixelCountIsRefusedWithoutDecoding` and `extremeSideLengthIsRefused` fail; display cap raised to 8000 -> the 50 MP test fails (output 8000x6250, +95 MiB); SVG added to the allow-list -> `svgAndOtherMimeTypesAreRefused` and the ingest placeholder test fail. A cap of 100000 hung the test host (ImageIO upscales to the requested size), so it was not used.
- **Not verified:** a real device; a real Bob image block (T-39, task 5.5); Codex (no inbound image item exists); the row on screen (only the mapper and decoder are unit tested, no screenshot was taken); `scripts/check.sh` result is below.


### 2026-11-06 — 3.21 Branch chip, Git tab and turn diff in the app (D-042)
- **Commands:** `scripts/check.sh`; `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/dd-git -only-testing:AgmenteTests test`.
- **Result:** PASS for the unit tests. Not run against a live gateway.
  - `scripts/check.sh`: "All checks passed" (ACPClient 182 tests, 8 new in `GatewayGitTests`: status, diff by path and by trees, log cursor, turn diff and its error mapping, `git/changed` parsing).
  - App: 219 unit tests, 0 failures (191 before, plus 28 new in `GitModelTests.swift`: diff splitting, turn numbering, project model, turn model, store). The runs reported here started after another agent's `pkill xcodebuild` at about 23:15.
  - **Mutation checks** (one run, four changes, each restored afterwards): no dedupe of paged commits fails `testLogPagesAndDropsACommitSeenOnAnEarlierPage`; removing the "path must be in the status" guard fails `testDiffIsRequestedOnlyForAPathInTheStatus`; removing the same-hash check fails `testChangedWithTheHeldHashDoesNothingAndANewHashRefreshes`; disabling secret-stub parsing fails `testSecretStubsAfterADiffBecomeHiddenFilesWithNoContent` and `testAHiddenOnlyAnswerAndEmptyText`.
- **Not tested:** the views on screen (chip, Git tab, diff, turn-diff sheet) and the accessibility identifiers; no simulator run against a gateway with the fake agent; the toolbar placement beside the existing menu; a gateway restart between a status and a diff. The turn-number rule (D-042) is tested as a pure function only.
- **Environment note:** this worktree has no `.claude/settings.json` (untracked in the main checkout), so `check.sh` stops at "JSON files parse". I copied the file in to run the gate and did not commit it. The destination `iPhone 17 Pro` does not exist on this Mac; I used `iPhone 18 Pro`.

### 2026-11-07 — Simulator run of the Git UI, image rows and deep link (3.20, 3.21, 5.1, 5.2)
- **Setup:** iPhone 17 simulator, Debug build of the merged `main`, a local gateway (the Go binary) with the fake agent on `ws://127.0.0.1:8799`, one project that is a git repo with a modified file, an untracked file and a `.env`. Screens were checked by screenshot.
- **Seen working:**
  - Session header: branch chip "main" with a dirty marker. Tap opens the Git sheet.
  - Changes tab: branch, 4 changed files with status letters and +/- counts. A file added on disk while the sheet was open appeared (5 files) without a manual refresh (`git/changed`).
  - Diff of `a.txt` renders removed and added lines; `.env` shows "Content hidden" and no content.
  - History tab lists both commits.
  - Image: a 160x100 PNG sent as an `image` block renders as an image; a `resource_link` renders as a plain row with its URI and is not fetched.
  - Turn diff: "Turn 1 changes" shows only the file the agent wrote in that turn (`made-by-agent.txt`, +1); `a.txt`, modified before the turn, is correctly absent.
  - Deep link `agmente://session/<server>/<session>` opened the session (iOS first asks "Open in Agmente?").
- **Two defects found by this run and fixed:**
  1. The "Turn diff" button was built into the SwiftUI file-change card, but iOS draws the chat with the UIKit list (`FileChangesRows.swift`), so the button never appeared. It is now in the UIKit row, shown only when the gateway offers git and the turn number is known.
  2. "Review" opened an empty "File Changes" sheet (a sheet driven by two state values read before the second was set; upstream behaviour). `SessionDetailView` now uses `.sheet(item:)`, as the Codex view already did.
- **Fake agent:** new directives `[edit:NAME]` (a completed edit tool call with a diff), `[image]`, `[link]`.
- **Checks after the fixes:** `scripts/check.sh` passes (137 wire tests); app tests 219, 0 failures, TEST SUCCEEDED.
- **Not tested:** no unit test and no mutation check for the new Turn diff button wiring (found and verified on screen only); "no snapshot for this turn" and "not a repository" states on screen; many files or a long history; Dynamic Type and dark mode; a real Bob session. The 3.21 note about counting user messages for the turn number held in this run (turn 1).

## 2026-11-07 Turn diff button test (FR-31)
- Added `AgmenteTests/TurnDiffButtonTests.swift`: the UIKit `FileChangesRowView` hides "Turn diff" without a handler, shows it and fires the handler with one, and hides it again on reconfigure.
- Command: `xcodebuild ... test -only-testing:AgmenteTests/TurnDiffButtonTests` → 3 tests pass.
- Mutation check: forcing `turnDiffButton.isHidden = true` in `FileChangesRows.swift` made `buttonIsVisibleAndFiresHandler` fail; source restored.
- Not covered: the closure chain in `HighPerformanceChatListView` and `SessionDetailView` (`canTurnDiff`/`onTurnDiff`); still checked on screen only.

## 2026-11-07 Push token registration, gateway and app (3.11 first half, D-052)
- **Done:** `_agmente/push/register` and `unregister`, schema version 4 (`push_tokens`), `push` extension; app `GatewayClient.registerPush`, `PushGatewaySync`, `AppViewModel+Push`.
- **Result:** PASS for the tests; nothing sent to Apple, nothing run on a device.
  - `scripts/check.sh`: "All checks passed". Wire tests 142 (was 137; 5 new in `test/push.test.mjs`: extension advertised, register and replace, bad tokens and environments refused with nothing stored, unregister removes only the caller's token, token absent from audit and responses). Go store tests: replace and delete, schema 3 migration; two older migration tests now also drop `push_tokens` when they rebuild an old shape, and one table count went from 6 to 7.
  - ACPClient: 3 new `GatewayPushTests`. App: 3 new `PushGatewaySyncTests` (sends token and environment; sends nothing without a token, permission or the `push` extension; a refusal is reported without the token). Full app run: TEST SUCCEEDED.
  - **Mutation check:** widening the token pattern to `{0,200}` made the bad-token wire test fail (141 pass, 1 fail); restored. Not run for the app side.
- **BLOCKED:** APNs delivery (JWT with `.p8`, HTTP/2 send, invalid-token cleanup), the Push entitlement, and any check on a device. Steps: `docs/PUSH-TESTING.md`.
- **Unverified:** that `sandbox` for Debug and `production` otherwise matches the real signing; that the app's token reaches the gateway on a real device (the simulator cannot register for remote notifications).

## 2026-11-07 Real Bob behind the gateway: host runner and Podman container
- **Environment:** this Mac, Bob 2.0.9, Podman 5.6.2 (libkrun VM), image `agmente-bob:2.0.9`, `BOB_API_KEY` from the gitignored `.env`, loaded into the environment of the test process only and never printed. Scratch git project under `~/.agmente-live/`. Fake agent not involved.
- **Command:** `set -a; . ./.env; set +a; AGMENTE_GATEWAY_CMD='["<abs>/gateway/bin/agmente-gateway"]' node gateway/scripts/live-bob.mjs --runner host|podman [--no-key]`. The script's client allows the one scratch-file edit and rejects everything else; the gateway approves nothing (D-009). About 5 short prompts per run.
- **Host runner: 24/24** on the final run (one earlier failure was a wrong assumption in the script: Bob sends `available_commands_update` before the turn starts).
- **Podman container: 24/24 on three runs in a row** after the fix below; before it, 3 earlier runs had 23/24 or 24/24 with random `snapshot_failed` lines.
- **What was shown on real Bob (both runners):** `session/new` with modes agent/plan/ask; a turn is logged in order with contiguous seq; the index gives idle, unread 1 and Bob's own title; T-18 on real Bob (drop after seq 6, resubscribe, events 7 to the end, no gap); FR-20 (load of a live session answered by the gateway, no `session/load` to Bob, history replayed from the log); a real `session/request_permission` (kind `edit`, "Writing file ...") reached the queue, the index showed `awaiting_approval`, and an answer through `_agmente/approvals/answer` let Bob write the file; a rejected shell command (kind `execute`) did not run; `git/status` and `git/turnDiff` list the file Bob wrote and the text-only turn's diff is empty; idle stop then a new prompt made the gateway start a new Bob and load the session itself (D-032), and Bob still knew the earlier conversation.
- **T-35 PASS:** with no `BOB_API_KEY` and no stored login, real Bob answers `session/new` with `-32000 "Authentication required"` (both runners). It is `session/new`, not `session/prompt`, that fails. (A first attempt was invalid: the gateway still inherited the key from the shell; the script now starts it with a replaced environment.)
- **Defect found and fixed (Podman only):** about 1 in 25 git container starts failed with `crun: write to /proc/sys/net/ipv4/ping_group_range ... Invalid argument: OCI runtime error`, exit 126, when several git containers started at once with `--userns=keep-id` and `--network=none`. Git never ran, so the turn snapshot failed and `git/turnDiff` said "no snapshot for this turn". Reproduced directly with 24 parallel starts (1 failure). `--sysctl net.ipv4.ping_group_range=0 0` made all 24 fail and was dropped. Fix: `podmanRunner.exec` retries up to 3 times, only for exit 126 with "OCI runtime error" (`containerNeverStarted`). Three unit tests (retry then success, stop after 3, no retry for other failures); mutation check (condition disabled) fails two of them. The `snapshot_failed` audit line now carries the gateway's own error text (`start: ...`, `end: ...`), never git output. **Cause not confirmed on Linux;** the retry is a mitigation.
- **Not tested here:** real Bob on Linux, T-47, the app against real Bob (simulator pass still to do), Q-2, Q-3, Q-4, Bob's `session/close` on idle close (the project went down by idle stop instead), more than one device, long histories.

### 2026-11-07 — Watch skip list and additive list updates (D-065, D-066, D-067)
- **Done:** `watchSkip` at create, stored in schema 5 (`watch_skip`); `_agmente/projects/addDenyPaths` and `addWatchSkip` (merge, 32 in total, never remove); the watcher reads the project each tick and starts from a baseline taken before `git/status`; the root folder is never skipped by name.
- **Commands and results:**
  - `go vet ./...`, `go test ./...`: pass. New Go tests: `store/store_watch_test.go` (schema 4 to 5 migration, round trip, all-or-nothing update), `server/watchskip_test.go` (validator, merge cap, fingerprint skip). Three older migration tests now also drop `watch_skip` when they rebuild an old shape.
  - New wire tests: `test/watchskip.test.mjs` (5) and `test/projectlists.test.mjs` (6). All 11 pass on their own, and the git watch tests still pass (`gitchanged.test.mjs` 5/5, three runs).
  - `scripts/check.sh` as a whole: **not green in four runs.** Each run reached the wire suite and stopped there. Run 1: T-46 idle stop and turn-diff "each turn has its own diff" (17 s). Run 2: `gitchanged` "changes under node_modules are not watched" (1 of 4 full runs; 3 of 3 standalone passes). The test writes an untracked, non-ignored `node_modules/pkg/index.js`, so a status run that a neighbouring `ignored.log` write triggers late would list it. The same test design is in HEAD. Runs 3 and 4: T-46 "a subscriber keeps the container running; it stops once the subscriber leaves". Wire suite in run 4: 152 pass, 1 fail, 153 total.
  - Checks that ran outside the gate, after the wire suite failed: `scripts/check-docs.mjs` ok (49 decisions, all tests scheduled); the `--dry-run` of `config.example.json` ok; the private-key and raw-secret-key scans found nothing; `swift test` for `AgmenteTransport` (exit 0), `ACPClient` (192 tests, 0 failures) and `AppServerClient` (9 tests, 0 failures).
- **Mutation checks** (each reverted, then the file compared with its backup):
  - Watcher ignores the project's `watchSkip` (`WatchSkip` replaced by nil in `watch.go`): 3 wire tests fail (skip, anchored and bare names, restart).
  - Update drops a built-in once a project has additions (`isSecretFor` skips the built-ins when `extra` is non-empty): `addDenyPaths ... built-ins stay active` fails.
  - Update overwrites instead of merging (`mergeEntries` starts from an empty list): 3 wire tests fail, and the Go merge test fails.
- **Pre-existing timing flake (not caused by this change, measured):** T-46 "a subscriber keeps the container running" asserts that the idle stop comes at least 900 ms after the subscriber leaves, with `idleSeconds` 1. The idle check records activity only at its own ticks (every 250 ms), so the stop can come 750 ms after the leave. A/B with the untouched HEAD gateway (five runs of this one case, same machine): HEAD failed 2, this build failed 3. The idle code is not changed by this work. A fix is to record the project's activity when a subscription ends (`unsubscribeAll`). That changes idle accounting, which needs its own D-n entry; this task allows D-065 to D-067 only, so it is not done.
- **Load note:** during runs 1 and 2 the machine's load average was 140 to 200 (other sessions' gates and Swift builds). The HEAD A/B showed a 30 s turn-diff timeout under the same load.
- **Not tested:** real Bob; a 200,000-file folder for the baseline walk; the Linux host; the watch skip list in the app (no app code changed).
- **Unverified:** that `watchBaseline`'s extra walk on a project's first status is cheap on large trees (not measured).
- **Not committed:** `.claude/settings.json` was copied into this worktree so the gate's JSON step could run (the same as RESULTS 3.21). It is untracked and not part of the commit.

## 2026-11-07 APNs delivery in the gateway (PLAN 3.11 second half, T-48 wire part; D-053, D-054, D-055)
- **Done:** `internal/push` ES256 provider token from a `.p8` (standard library), cached and rebuilt after 50 minutes; HTTP/2 POST to `/3/device/<token>` with the four APNs headers and the `push.Build` payload; the answer table (`push.Decide`): 410, `Unregistered`, `BadDeviceToken`, `DeviceTokenNotForTopic` remove the token; 429 and 5xx retry twice; 403 `ExpiredProviderToken` rebuilds the token once. Triggers: finished turn, failed turn (`session_failed`), approval request; a bounded queue of 64 with `push_dropped` on overflow; a device with a subscriber on the session gets no push. Config `push` block (SPEC 6.3), key-file refusal at start and in dry run, dry-run summary. Audit: `push_sent`, `push_failed`, `push_token_removed`, `push_dropped`, `push_enabled`.
- **Test rig:** `gateway/test/apns-fake.mjs` makes a throwaway P-256 key and certificate at run time. The fake APNs server is HTTP/2 over TLS. The gateway trusts the throwaway certificate through `push.caFile` (test only, D-055). Nothing reaches Apple.
- **Check:** `node --test test/apns.test.mjs` → 17 of 17 pass: no push without a `push` block; headers, host and topic; provider token signature verifies against the test public key, with `kid` and `iss` as configured; payload ≤ 256 bytes, project name as title, no prompt text; `approval_needed` and `session_failed` events; production token to the production host; suppression for a subscribed device and release when it leaves; another session's subscriber does not suppress; 410 removes once with no retry; `BadDeviceToken` and `DeviceTokenNotForTopic` remove; 429 retried twice then kept; 5xx retried and cleared; 403 refresh once; two turns send two pushes in order; a group-readable key refused (exit 1, message names the mode, no key bytes); an unparsable key refused; push block validation (ids, topic, URLs, unknown key); dry-run summary has ids and paths only.
- **Go unit tests:** `go test ./internal/push/` (JWT header, claims and signature checked with the public key; the signature is 64 raw bytes; signer cache and refresh window; key-file permissions and parsing; `Decide` table; `Deliver` retry, refresh and no-retry-after-second-refresh against an `httptest` HTTP/2 server); `go test ./internal/server/ -run TestPushNotify` (a full queue drops and audits; no session id is skipped; nothing queued without `SetPush`).
- **Mutation checks** (source restored after each; no mutation marker left; both checked with `go test` clean afterwards):
  1. Suppression skipped (`subscribedDevice` result ignored): "a device with a live subscriber ... gets no push" **FAILS** ("the foreground device gets no push").
  2. Token removal on 410 skipped: "410 Gone removes the token at once and is not retried" **FAILS** (no `push_token_removed` within the wait).
- **Gate run 1 (`scripts/check.sh` as written):** stops at its first check, "JSON files parse": `.claude/settings.json` is missing from this worktree. The file has never been committed on this branch (`git log --all -- .claude/settings.json` is empty), so it is not a result of this change. Not fixed here.
- **Gate run 2 (the same script with only that one file removed from its JSON list, ROOT set to this worktree):** `All checks passed`, exit 0. Wire suite 159 of 159 pass. Go `vet`, unit tests and build pass. Dry run of `config.example.json` passes. No secrets found. Docs cross-check passes (`scripts/check-docs.mjs`). Swift packages (`AgmenteTransport`, `ACPClient`, `AppServerClient`) pass.
- **Load flakes (run 1 only):** `denypaths.test.mjs` "additions never remove built-ins" (TypeError on an undefined response) and `gitchanged.test.mjs` "a change to an ignored file sends nothing" each failed once, at about 13 s, while other worktrees ran the same suite. Both pass when run alone (10 of 10 in the two files), and both passed in run 2. Nothing was changed for them.
- **Defects found and fixed while building (not behaviour changes):** the test certificate and key made with LibreSSL 3.3.6 do not parse in Go (`unknown elliptic curve` for the PKCS#8 key, `invalid ECDSA parameters` for the certificate, both from explicit curve parameters). The test now makes both keys with Node's OpenSSL and uses `openssl req -key` only for the certificate. Note for the owner: keys generated with LibreSSL are not usable here; Apple's `.p8` files were not tested (no key).
- **BLOCKED:** `BLOCKED: needs a real APNs .p8 key (Apple Developer account, key id, team id) and an iPhone`. The device part of T-48 (`docs/PUSH-TESTING.md` Part E.2, steps 2 to 9) is not run. The `aps-environment` entitlement is not added (Apple account). PLAN 3.11 is marked `[!]`.
- **Not verified:** Apple's live answers (every answer here comes from the fake, which follows Apple's documented codes; verify on the device test); that Apple accepts a token from the real key; the key file's mode and owner on the Linux host; the 20 to 60 minute JWT window (PUSH-TESTING Part E cites it, Apple's page was not re-read here).
- **Not done, on purpose:** `gateway/config.example.json` has no `push` block. Dry run reads the key file, and the example has no key, so a block there would make `check.sh` fail. The block is shown in PUSH-TESTING Part E and described in SPEC 6.3 (D-055).

### 2026-11-07 — Signed file URLs (PLAN 5.3, D-061 to D-064, T-37)
- **Done:** `_agmente/files/url`, `GET`/`HEAD /f/<token>` on the `files.host` only, the `files` config block (key file or random key, TTL cap 300 s, size cap), audit events `file_url_issued`, `file_served`, `file_refused`, `extensions` now ends with `files`.
- **Commands and results:**
  - `(cd gateway && go vet ./... && go test ./...)`: pass (new Go unit tests for token sign/verify, path rules, type allow-list; config key-file tests).
  - `node --test test/files.test.mjs`: 14 of 14 pass (T-37 cases: `../`, absolute, symlink to `/etc/passwd`, folder link to outside, symlink swapped after signing to outside and to `.env`, expired URL with `ttlSeconds: 1`, tampered token, token spliced from another path, `.env` and `denyPaths` entry, secret-named link, folder, named pipe, wrong Host, upgrade on files host (403), POST (405), HEAD, size cap at signing and at serving, nosniff, no-store, CSP on HTML, SVG as text, audit never holds the token, key file never in audit).
  - `node --test test/supervisor.test.mjs`: 8 of 8 pass (extension list now includes `files`).
  - `scripts/check.sh`: **not green.** Three full runs. Run 1 failed in `test/lifecycle.test.mjs` (T-46 subscriber case, assertion "the idle time counts from when the subscriber left"). Run 2 (the one with the exit code recorded, 155 of 156) failed on the same test. Run 3 failed on `test/git*.test.mjs` "a change to a file sends one notification with the new status hash". In each run the failure was a timing assertion under full-suite load. The T-46 subscriber test passed 3 of 3 when run alone.
- **Mutation checks** (`node --test test/files.test.mjs` after each change to `files.go`, source restored and rebuilt after each):
  | Mutant | Result |
  | --- | --- |
  | containment check off (sign and serve) | 2 tests fail (outside paths, swapped symlink) |
  | expiry check off | expired-URL test fails |
  | inner (realpath) deny-list check off | 2 tests fail |
  | outer (name) deny-list check off at signing | caught only after adding the secret-named link case: 1 test fails |
  | Host check always true | 12 tests fail |
  | MAC comparison off | tampered-token test fails |
  | serve-time size checks off (both) | size test fails |
  | serve-time realpath recheck off (first and post-open) | swapped-symlink test fails |
  | post-open `SameFile` recheck off only | **survives** (see Not tested) |
- **Not tested:**
  - The post-open `SameFile` recheck: a race between the check and `open` cannot be reproduced over the wire. Only the first serve-time check is covered by the swap test.
  - Caddy routing of `files.host` and whether the client-certificate rule applies to it (D-061): not checked on any host.
  - The gate itself: not green; the timing flakes above are unresolved. They are not caused by this change as far as the code shows, but a clean base-commit run was not done, so that is unverified.
  - No app (WKWebView) side (PLAN 5.4 and 5.5).
- **Environment note:** `.claude/settings.json` is untracked in the main checkout, so I copied it into the worktree to run the gate. It is not committed, and I removed it afterwards. `npm ci --prefix gateway` installed from the lockfile in this worktree.
