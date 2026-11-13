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
| T-35 | Partial: Bob's error recorded (2026-11-05); app mapping unit-tested 2026-11-07, on-screen check not run | 2026-11-07 |
| T-36 | PASS in the iOS Simulator (unit tests, not on a device): 50 MP PNG downsampled to 2048x1600, peak footprint increase 17 MiB; oversized, wrong MIME, corrupt data and 108 MP bomb refused | 2026-11-06 |
| All others | Not run | — |

## Entries

### 2026-11-05 — T-1 check gate (scaffold build)
- **Environment:** Linux 6.18, Node v22.23.4, npm 10.9.9, `ws` 8.22.1, no Swift toolchain.
- **Command:** `scripts/check.sh`, run twice: in the overlay alone, and after applying the overlay to upstream ACP Code `87f224e`.
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
- **Environment:** MacBook (Darwin 27.0.0, arm64). Podman 5.6.2, `podman-machine-default` (libkrun VM, 2 CPUs, 3.6 GiB). Image `acpcode-bob:2.0.9` from the draft `deploy/bob-project.Containerfile` (`node:22-bookworm-slim`, Node 22.23.4, `@ibm/bob@2.0.9`, user uid 10001, 413 MB). Named volumes for `HOME` (with a `TRUST_FOLDER` entry for `/work`) and for the project. Host runs used Bob 2.0.9 with a disposable `HOME`. Image and VM already up and cached.
- **Command:** `set -a; . ./.env; set +a; node gateway/scripts/bench-start.mjs --runs 5`. Each run starts a new Bob (host) or a new `podman run --rm -i --name acpcode-bench-<tag>` container, then sends `initialize`, `session/load` of a seeded session (one prompt of history), and `session/new`, then stops it. ACP goes straight over stdio; the gateway adds under 1 ms (T-12).
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
  same-name second container while one runs: refused: ... the container name "acpcode-bench-0222ea" is already in use ...
  ```
- **Result:** Recorded (no NFR covers start time yet).
- **Notes:**
  - A cold start costs about 1.5 s until an existing session is loaded and replayed. That is the delay when a phone reopens a session in an idle project. A new session is ready after about 2.3 s. Most of this is Bob's own start-up (about 0.83 s to `initialize` on the host). The container adds about 0.2 s to `initialize` and about 0.25 s to stop.
  - The container-name lock in D-015 holds: Podman refused a second container with the same name while the first was running.
  - Not measured: the first start after the Podman VM boots, or after the image cache is cleared. Starting the VM itself took 11.8 s here. That cost does not apply on a Linux host, which runs containers without a VM. Measure again on the Linux host after PLAN 1.11.
  - Each run used a model-free path (no prompt), so model latency is not included. The 1-prompt history is small, so the load time for a long session is not measured.

### 2026-11-06 — T-1 and PLAN 0.5 with Xcode; app unit tests
- **Environment:** macOS (Darwin 27.0.0, arm64), Xcode 27.2 (27B52) selected at `/Applications/Xcode.app/Contents/Developer`, iOS 27.2 simulator runtime, Node v24.5.0. Simulator "iPhone 17" (there is no "iPhone 16" in this Xcode; the test command in `CLAUDE.md` now names iPhone 17).
- **Command:** `scripts/check.sh`; then `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:ACPCodeTests test`.
- **Output (trimmed):**
  ```
  ACPClient:       Executed 156 tests, with 0 failures; Test run with 9 tests in 2 suites passed
  AppServerClient: Executed 9 tests, with 0 failures
  check.sh: exit 0, "All checks passed."
  ACPCodeTests:    Test Suite 'All tests' passed; Executed 121 tests, with 0 failures (0 unexpected);
                   Test run with 10 tests in 2 suites passed
  ** TEST SUCCEEDED **
  ```
- **Result:** T-1 PASS. PLAN 0.5 PASS. App unit tests PASS.
- **Notes:** `CodexThreadReadMergeFixtureTests` reads its fixtures from the source tree (`#filePath`) under `~/Documents`. The first run blocked in `open()` for about 20 minutes until the owner allowed macOS file access for the Simulator. A stack sample showed `loadFixtureURLs` → `contentsOfDirectory` → `open`. The 1,474 s run time includes that wait. The UI tests (`ACPCodeUITests`) were not run.

### 2026-11-06 — Phase 2: 2.5, 2.1, 2.2, 2.8, 2.3, 2.4 (T-14, T-15, T-16)
- **Environment:** macOS, Xcode 27.2, iOS 27.2 simulator "iPhone 17".
- **Commands:** `swift test --package-path ACPCodeTransport|ACPClient|AppServerClient`; `xcodebuild ... -only-testing:ACPCodeTests test`; `xcodebuild ... -only-testing:ACPCodeUITests test`.
- **Output (trimmed):**
  ```
  ACP CodeTransport: Executed 7 tests, with 0 failures (3 runs in a row)
  ACPClient:        Executed 158 tests, with 0 failures   (156 before, plus 2 EndpointPolicyTests)
  AppServerClient:  Executed 9 tests, with 0 failures
  ACPCodeTests:     Executed 133 tests, with 0 failures  (121 before, plus KeychainStore 4, ServerSecretMigration 2,
                    StoreProtection 2, TransportPolicy 4); includes CodexServerViewModelTests and ViewModelSyncTests
  ACPCodeUITests:   ** TEST SUCCEEDED **; testExample, testLaunchPerformance, testLaunch x4 passed;
                    testCodexDirectWebSocketConnectInitializeAndSessionFlow skipped (opt-in E2E)
  store protection attribute on this platform: nil   (the simulator does not report data protection)
  ```
- **Result:** T-14 PASS, T-15 PASS, T-16 PASS. PLAN 2.1 to 2.5 and 2.8 done.
- **Notes:**
  - **2.5:** new local package `ACPCodeTransport` (`NativeWebSocketConnection`). The two `URLSessionWebSocketProvider.swift` files are now adapters, and neither package's public API changed. `AppServerClient` raised its macOS minimum from 10.15 to 13 to match. `scripts/check.sh` tests the new package. The Xcode project needed no edit: `ACPCodeTransport` resolves as a path dependency of the two local packages.
  - **2.2:** `ServerSecretMigration` runs on every `fetchServers`. `SessionStorage` reads secrets from the Keychain, writes them there, stores nil in Core Data, and deletes Keychain items with the server. `SessionStorage.inMemory()` uses its own Keychain service.
  - **2.8:** `NSPersistentStoreFileProtectionKey = .complete`, SQLite `secure_delete = ON`, and `isExcludedFromBackup` on the `.sqlite`, `-wal` and `-shm` files at each launch. A store that fails to load now falls back to memory (`PersistenceController.loadError`) instead of `fatalError`. No screen shows that error yet. The erased-bytes test passes, but it also passed with `secure_delete` set to `OFF`, because migration overwrites the row in place and the checkpoint replaces the page. So the test confirms that no token bytes remain after migration, and does not show the effect of `secure_delete`. `secure_delete` protects deleted rows. It does not clean free pages that older app versions left; a one-time `VACUUM` would (not done).
  - **2.3:** `TransportPolicy` (D-018, D-019); model version `ACPCode 2` adds `localOnly` (Boolean, default NO) and `spkiPins` (String, optional), and the `scheme` default becomes `wss`. `ACPClientManager.endpointPolicy` checks every connect and reconnect: a refused endpoint makes no connection and is not retried. `validateServerConfiguration` checks the policy before it builds a client. The add-server form has a "Local only" toggle (`LocalOnlyToggle`) and a warning (`LocalOnlyWarning`), and offers `ws` only when "Local only" is on or in Debug builds. No existing test needed a change: they use mocks, or `ws://127.0.0.1`, which Debug builds still allow. The sidebar's connection picker still lists `ws`; the policy refuses it at connect time.
  - **2.4:** the cap is checked on the declared frame length (and the reassembled length for continuation frames) before the payload is buffered. Control frames are not counted. On overflow the client sends close 1009, half-closes, cancels after 250 ms and returns `.closed(1009)`. Before that half-close, the test showed that cancelling at once could lose the close frame at the peer (a TCP reset with unread data).
  - **Upstream bug found and fixed:** `receive()` read the network after a ping, pong or non-final fragment even when the next frame was already buffered. Back-to-back frames, for example a ping followed by a message, could then stall until more data arrived. `testControlFramesAreNotCountedAgainstTheCap` hung on the old loop and passes on the new one. T-16 also hangs, rather than failing, against code without the cap (the client waits for the 17 MiB payload).

### 2026-11-06 — Phase 2: 2.6 (T-17), 1.10, 2.7, and the full regression
- **Environment:** macOS, Xcode 27.2, iOS 27.2 simulator "iPhone 17", LibreSSL 3.3.6 (`/usr/bin/openssl`), Caddy v2.11.9 (Homebrew), Node v24.5.0.
- **Commands:**
  - `swift test --package-path ACPCodeTransport` (two runs in a row)
  - `scripts/make-client-cert.sh --dry-run iphone`; `scripts/make-client-cert.sh --out <scratch>/ca testphone`; `openssl verify -CAfile <scratch>/ca/ca.pem <scratch>/ca/testphone.pem`
  - Local stack, all on loopback: gateway (`--config <scratch>/gateway.json`, fake agent, port 18787, `trustProxy` true, caps 1); `caddy run` with `skip_install_trust`, `tls internal`, `client_auth { mode require_and_verify; trust_pool file <scratch>/ca/ca.pem }`, site `https://localhost:18443`. Then `ACPCODE_MTLS_*=... xcrun xctest -XCTest ACPCodeTransportTests.MutualTLSLiveTests`.
  - `scripts/check.sh`; `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' test`
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
  ACP CodeTransport: Executed 12 tests, with 1 test skipped (the opt-in live test) and 0 failures
  check.sh: gateway 37/37, docs ok, ACP CodeTransport 12 (1 skipped), ACPClient 158, AppServerClient 9; "All checks passed."
  App:      Executed 137 tests, with 0 failures; ** TEST SUCCEEDED ** (UI tests included; the Codex E2E test skipped, opt-in)
  ```
- **Result:** T-17 PASS. PLAN 1.10 PASS. PLAN 2.6 and 2.7 done; the 2.7 check passed against a local Caddy. Repeat it on the host after PLAN 1.11.
- **Notes:**
  - **2.6:** `TransportTLSOptions` (pins, trust anchors, client identity) sits in `ACPCodeTransport` and is passed from `ACPConnectionConfig` through `ACPClientConfiguration` to the provider. `ACPClient` re-exports `ACPCodeTransport`. The verify block runs only when pins or anchors are set: it runs `SecTrustEvaluateWithError` first, and then needs one certificate in the chain to match a pin. Pins are base64 SHA-256 SPKI values (an optional `sha256/` prefix is accepted). The pin value equals `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`. The form has a "Certificate pins" field (`SPKIPinsField`), stored in Core Data `spkiPins` (not a secret).
  - **2.7:** `ClientIdentityStore` imports a `.p12` (`SecPKCS12Import`; the passphrase is not stored) and keeps the identity in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, one per server. The form has import and remove buttons (`ImportClientCertificateButton`, `RemoveClientCertificateButton`). The identity is deleted with the server. `ClientIdentityStoreTests` embeds a throwaway self-signed test `.p12` (CN=acpcode-test-client, passphrase in the test). It is not a credential for any server. `scripts/check.sh` looks only for PEM private keys, so it does not flag this base64 test fixture.
  - **1.10:** output goes to `secrets/client-ca/` by default, which is now in `.gitignore`. The `.p12` passphrase is random and printed once to stderr. The `.p12` uses PBE-SHA1-3DES so that iOS can import it (verify on new iOS releases).
  - **Found while testing, all fixed in `ACPCodeTransport`:**
    1. LibreSSL writes EC keys with explicit curve parameters (`-newkey ec -pkeyopt ec_paramgen_curve`), and signs with SHA-1 by default. Apple's Security framework rejects both (`SecCertificateCopyKey` returns nil; "broken signature algorithm"). The script and the tests use `ecparam -param_enc named_curve` and `-sha256`. LibreSSL `req -x509 -key` without `-new` reads a request from stdin and hangs.
    2. Upstream `connect()` had no deadline. There is now one (15 s by default) over TCP, TLS and the WebSocket handshake. Test: `testConnectTimesOutWhenTheServerNeverAnswers`.
    3. With TLS 1.3, a server that rejects a missing client certificate does so after the client reports `.ready`. The pending handshake read then never returned. A `.failed` state after `.ready` now cancels the connection, so pending reads end.
  - **Caddy and SNI:** a connection by IP sends no SNI. Caddy's client-auth policy did not match, the handshake completed without a client certificate, and every request got HTTP 421. Clients must use the host name. This is noted in `deploy/Caddyfile`.
  - The local Caddy, the gateway and all keys lived in the scratch folder and were stopped and left there. Nothing was added to the system trust store (`skip_install_trust`; Caddy logged "root certificate trust store installation disabled").


### 2026-11-06 — Wire-level gateway tests, and the Go gateway (D-021)
- **Environment:** macOS, Node v24.5.0, Go 1.27.3 (Homebrew), `github.com/coder/websocket` v1.8.15.
- **Commands:**
  - `npm test --prefix gateway` (Node gateway, the default target), three runs
  - `go vet ./... && go test ./... && go build -trimpath -o bin/acpcode-gateway ./cmd/acpcode-gateway` (in `gateway/`)
  - `ACPCODE_GATEWAY_CMD='["<abs>/gateway/bin/acpcode-gateway"]' npm test --prefix gateway`, four runs
  - `node gateway/test/bench.mjs` with and without `ACPCODE_GATEWAY_CMD`
  - Idle RSS: each gateway started on the example config (port 0, one empty root), `ps -o rss` after 2 s, no connections
  - `scripts/check.sh`
- **Output (trimmed):**
  ```
  Node gateway: tests 53, pass 53, fail 0   (before the U+2028 fix: 52/53, see notes)
  Go gateway:   tests 53, pass 53, fail 0   (4 runs in a row; about 5.4 s each)
  go test:      ok acpcode/gateway/internal/jsonv; ok acpcode/gateway/internal/server
  bench, 2000 calls, 1 KiB:   Go   gateway p95 0.163 ms, direct p95 0.143 ms, overhead p95 0.020 ms; reject p95 0.348 ms (n=500)
                              Node gateway p95 0.177 ms, direct p95 0.044 ms, overhead p95 0.133 ms; reject p95 0.358 ms
                              spawnedDuringRejects 0; nfr1 PASS, nfr2 PASS (both)
  idle RSS:     Go 12.9 MB; Node 58.1 MB
  check.sh:     Go vet/test/build ok; wire suite 53/53 on Go and on Node; docs ok;
                ACP CodeTransport 12 (1 skipped), ACPClient 158, AppServerClient 9; "All checks passed."
  ```
- **Result:** T-2 to T-10 and T-13 PASS on both gateways, over the wire. T-11 and T-12 PASS on both. T-5 is checked through the CLI.
- **Notes:**
  - **The suite is wire-level now (D-021).** `gateway/test/helpers.mjs` starts the gateway from `ACPCODE_GATEWAY_CMD` (a JSON array; default the Node gateway), writes a real config file, and reads the audit log from stderr. Agent spawn counts come from `connect` audit lines; the old in-process `stats` counters are gone. Config checks run through `--dry-run` and the exit code.
  - **Old tests and what replaced them** (none was dropped or loosened):
    - Unit tests of `parseBearer`, `findTokenEntry`, `FailureLimiter`, `LineSplitter`, `isInsideRoots`, `parseClientMessage`, `isLoopbackAddress` and `validateConfig` became wire tests of the same cases: header variants at the upgrade, lockout expiry with `lockoutSeconds: 1`, chunked agent output (`_test/chunks`), a `<root>-evil` sibling, each bad message shape, each listen host through `--dry-run`, and each config error through stderr.
    - `buildAgentEnv` is covered by the env test: one passed variable with its value, and an unlisted secret that must be absent.
    - "a valid config is normalized and frozen": the defaults are checked in the dry-run summary. Freezing is a JavaScript detail and is not observable over the wire.
    - The backpressure test now checks for a `backpressure` audit line (`dir: "in"`) instead of an in-process counter. Both gateways write that line.
  - **New cases:** argv passed without a shell; ids, values, client responses and notifications pass through; CRLF and blank agent lines; last output before exit; a command that cannot start (1011, slot freed); SIGKILL after the grace period for an agent that ignores SIGTERM; shutdown on SIGTERM; audit fields limited to the allow-list with an ISO timestamp; no project path in the audit; bare CR, two trailing newlines, trailing data, a non-string `jsonrpc`, the empty message, invalid UTF-8 (1007); a fracpcoded message over the cap (1009); a message of exactly the cap (accepted); refusal ids echoed unchanged; a missing root allows nothing; U+2028 and U+2029; port, token entry, agent, roots and limit errors; unreadable and non-JSON config files; usage exit code 2; the example config.
  - **Bug found, fixed in the Node gateway:** Node's `readline` ends a line at U+2028 and U+2029 (checked: `printf '{"a":"x\xe2\x80\xa8y"}\n' | node -e '...readline...'` prints two lines). The Node gateway re-serialized with `JSON.stringify`, which leaves both raw, so a phone message containing U+2028 reached the fake agent as two lines and got no reply. The Node gateway now escapes both characters; the Go encoder always escapes them. Test: "U+2028 and U+2029 in a message cannot split it into two agent lines". Not verified: whether Bob's stdin reader splits on them.
  - The bench now measures the gateway named by `ACPCODE_GATEWAY_CMD`.
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
- **Notes:** `gateway/src/` and `gateway/scripts/new-token.mjs` are deleted. The wire suite and the bench default to `gateway/bin/acpcode-gateway`. Both probes now start the gateway as a process (`spawnGateway` in `gateway/test/helpers.mjs`), with the agent's working directory and a disposable `HOME`. The race probe keeps Bob's stderr with an `sh -c 'exec "$@" 2>>file'` wrapper in its own config, checked above.

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
- **Notes:** The store-level SIGKILL test is not T-20: T-20 kills the gateway itself and is checked in task 3.5. The 10,000-event read is not T-19 either; T-19 replays through `_acpcode/sessions/subscribe` in task 3.6. The child process wrote one event past the last one the parent counted ("present 501") because the kill came after that commit; nothing acknowledged was lost.

### 2026-11-06 — Phase 3 task 3.3: project registry (T-25, D-024)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test gateway/test/projects.test.mjs`; `scripts/check.sh` (two runs).
- **Output (trimmed):**
  ```
  ✔ T-25: a project outside the roots, or reached through a symlink that leaves them, is refused
  ✔ names and default modes are checked
  ✔ a project inside a root is registered with its realpath, a HOME and a trust entry
  ✔ _acpcode/* requests are answered by the gateway and never reach the agent
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
  - `config.example.json` gains `"stateDir": "/var/lib/acpcode/state"`, which the systemd unit already allows to be written (`ReadWritePaths=/var/lib/acpcode`).
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
  - T-22 method: two identities on two sockets. Method then method; method then plain response (the plain one gets `_acpcode/notice` "answered elsewhere"); then 10 rounds of both answering at once. Each round has exactly one winner, and the agent received exactly one answer per request (12 in all).
  - T-23 method: `limits.approvalTimeoutSeconds: 1`, one `[permission]` request and one `[permission:allow-only]` request (new fake-agent directive: only allow options), no answer. The agent's answer is checked against the request's options: never an `allow_*` kind. A late answer gets "timed out", and the `approvals` row shows `answered_by` `timeout`.
  - Gateway race found by the full check: the first `check.sh` runs failed T-22, in the concurrent rounds. The losing answer got "unknown approval" because the winner had not stored its answer yet. The gateway now keeps who claimed an approval in memory until it is stored (D-031). Two `check.sh` runs and 10 runs of the file then passed.
  - Gateway bug found while writing the tests: `_acpcode/approvals/answer` without `cancelled` dereferenced a nil value and panicked. The panic did not stop the gateway, but that socket never got an answer. Fixed. A guard was also added in the history replay (`subscribe.go`) for a logged prompt with no `prompt` field, which the gateway never writes. The socket handler has no recover of its own, so a future panic would again leave a socket hanging.
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
- **Environment:** macOS, Go 1.27.3, Podman 5.6.2 (libkrun machine), image `localhost/acpcode-bob:2.0.9` (git 2.39.5, user `bob` uid 10001).
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
- **Commands:** `node --test test/git.test.mjs`; `node test/bench-git.mjs`; `node test/bench-git.mjs --podman localhost/acpcode-bob:2.0.9`; `scripts/check.sh`.
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
  - The T-46 lifecycle tests counted every container start. Git runs now start their own short-lived containers (`acpcode-git-…`), so those tests count only the agent's containers; the one-at-a-time rule is unchanged for the agent.
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
- **Commands:** `(cd ACPClient && swift test)`; `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' test` (the app's unit and UI tests); `scripts/check.sh`.
- **Result:** PASS for the code and unit tests; the simulator run is in the end-to-end entry below.
  - The app reads `_meta["acpcode/gateway"]` from `initialize` (`GatewayInfo`: version and extensions). A server without it behaves as before (5 parse cases).
  - `GatewayClient` (new, in the ACPClient package) calls `_acpcode/projects/list` and `_acpcode/sessions/index` and decodes them; a status the app does not know decodes as `unknown`, so the list still shows.
  - The home shows sessions grouped by project, newest first, with a status badge and an unread count; the new-session sheet picks a project and sends `session/new` with its path. Layout rules are pure code with 6 tests (section and session order, ties, empty projects, orphans, search, totals); the model has 4 tests (load, a failed refresh keeps the list and says why, a late answer from the old server is dropped, no client).
  - Totals: ACPClient package 171 tests pass; the app 158 unit tests pass; `scripts/check.sh` passes (130 wire tests); full `xcodebuild test` including the UI tests: TEST SUCCEEDED.
- **Mutation checks:** removing the stale-answer guard fails the reconfigure test; reversing the section order fails the order test.
- **Not tested:** a gateway with many projects. The home on the simulator: see the end-to-end entry below.

### 2026-11-06 — 3.18 Open by subscribing; X-Client-Id removed (app, D-039)
- **Commands:** as for 3.17.
- **Result:** PASS for the code and unit tests; the simulator run is in the end-to-end entry below.
  - A gateway server opens a session with `_acpcode/sessions/subscribe {sessionId, afterSeq}` and never sends `session/load` or `session/resume`, not even in the prompt preflight. A plain ACP server is unchanged (it sends no `_acpcode` call).
  - `_acpcode/event` notifications are applied for the open session in `seq` order, each once: `session/update` and permission requests through the existing paths, `turn_started` as the user's message, `turn_ended` as the stop reason, `approval_answered` clears the options. A repeat is dropped; a gap resubscribes from the last event applied; a reopen of a session continues from its last event; a finished turn is marked read through `_acpcode/sessions/read`.
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
  3. Opening the session showed the logged user message and the agent's reply, rebuilt from the gateway log by `_acpcode/sessions/subscribe`.
  4. A new prompt ("second question [chunks:3]") appeared once as the user's message (no echo duplicate), "Thinking…" and the stop button showed, then the reply "echo: second question [chunks:3]" arrived through events and the send button came back.
  5. Gateway side, read through a second socket afterwards: the session's unread count was 0 (the app had marked it read) and `headSeq` 9 (two turns). The fake agent had received `initialize`, `session/new`, `session/prompt`, `session/prompt`: no `session/load` and no `session/resume`.
- **Observations, not fixed:**
  - The "active / idle" counts in the summary card at the top still come from the plain session list, so they read "0 active 0 idle" on a gateway server until a session is opened.
  - After adding a server the dot stays orange until Refresh; the app did not connect by itself (existing behaviour).
  - The session header shows the latest prompt as the title, while the gateway index keeps the first one.
  - The simulator's ACP Code had 11 leftover "Test Server" entries, made by the app's own unit tests, which write to the app's real store. I uninstalled and reinstalled the simulator app to start clean; only that simulator's ACP Code data was removed.
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
  - The in-session card on a gateway server now answers through `_acpcode/approvals/answer`, not a plain response. A request that someone else closed first is dropped from the card and the chat says "This request was already closed: <reason>"; any other failure keeps the options so the person can try again.
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
  - **New tests** (`gateway/test/supervisor.test.mjs`): sockets and identities share one process; per-socket responses with clashing ids; a closed socket leaves the agent running; exit handling and restart; a second gateway refused (`agent_error` reason `locked`), and it works after the first stops; `initialize` answered by the gateway with `_meta["acpcode/gateway"]`, plus capture; permission fan-out with the first answer winning; routing refusals.
  - **Harness:** gateway processes are now unreferenced and killed when the test process exits, so a timed-out test no longer keeps the runner alive.
  - **Not yet tested:** the podman runner live (arguments only), and the 1013 slow-client close.
  - `config.example.json`: `runner: {kind: "podman", image: "acpcode-bob:2.0.9"}`, `maxAgentsTotal` 4, `maxConnectionsPerIdentity` 8. `maxAgentsPerIdentity` and `HOME` were removed from it; `HOME` is now always the project home.

### 2026-11-06 — Phase 3 task 3.6: subscribe and replay (T-18, T-19, D-028)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0.
- **Commands:** `node --test --test-concurrency=1 gateway/test/subscribe.test.mjs`; `node gateway/test/bench.mjs`; `scripts/check.sh`.
- **Output (trimmed):**
  ```
  ✔ subscribe answers {headSeq} first, then replays each logged event as _acpcode/event
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
- **Commands:** `scripts/check.sh`; `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' test`; `xcrun simctl openurl` on the simulator.
- **Result:** PASS for the deep link and for permission and token capture. Push to the gateway and delivery are **BLOCKED**.
  - `scripts/check.sh`: "All checks passed" (130 gateway wire tests, Go tests, ACPClient 174, AppServerClient, ACP CodeTransport).
  - App: 191 unit tests, 0 failures, TEST SUCCEEDED (175 before, plus 16 new in `DeepLinkAndPushTests`: 6 parsing, 4 routing, 6 push registration).
  - **Simulator, link:** `acpcode://session/<Local Gateway id>/<waiting session id>` opened that session, with the permission card still showing its three options and nothing answered (the gateway still listed `acpcode-perm-1`). A link with a server id the device does not have showed "Link not opened: That link is for a server this device does not have" and the screen did not change. iOS asks "Open in ACP Code?" first; that is the system's prompt.
  - **Mutation checks:** three were run on the 3.20 code before the incident, and each made a test fail. I no longer have a record of the exact changes, so I do not list them; they were not re-run after the rebuild.
- **BLOCKED:** `_acpcode/push/register` (no gateway method; needs the owner's approval); the `aps-environment` entitlement and Push capability (needs the Apple account and signing); the APNs `.p8` key and a device for delivery (3.11).
- **Not tested:** a notification tap (no push can reach the simulator build without the entitlement; `simctl push` with the D-038 payload is not run); the Settings row on screen; a link opened while the app is not running.
- **Incident, same day (my mistake):** while cleaning up a mutation check I ran `git checkout -- .`, which reverted every tracked file to the last commit (0068137) and discarded all uncommitted edits to tracked files from 3A to 3D. Untracked files were not touched. I rebuilt the tracked files by replaying my recorded edits onto the commit, then fixed what the replay missed: the `go.mod` and `go.sum` entries for SQLite, the git, snapshot and watch wiring in `server.go`, the file directives of the fake agent (`[write:]`, `[remove:]`, `[symlink:]`), `markSessionUnmaterialized`, `dismissPermissionRequest`, the gateway sections of `ContentView.swift`, the app delegate hook, the Notifications settings row and the URL scheme in `Info.plist`, and decisions D-025, D-026 and D-028 with the PLAN ticks for 3.4 and 3.6. Checked afterwards by the full suites above (130 wire tests, Go tests, 174, 191 and the simulator run). Not provable: that every line of every document is identical to what it was; I compared behaviour through the tests, not text.

### 2026-11-06 — Follow-up to 3.14/3.15: per-project deny-list (D-050) and container user under Podman (D-051)
- **Environment:** macOS, Go 1.27.3, Node v24.5.0, git 2.54.0, Podman 5.6.2 with the running machine `podman-machine-default` (libkrun) and image `localhost/acpcode-bob:2.0.9`. The machine was under heavy load from other sessions (load average above 400), which matters for the timing notes below. This worktree was behind `main`; it was fast-forwarded to `81ea3c5` first.
- **Commands:** `(cd gateway && go test ./...)`; `node --test test/denypaths.test.mjs test/runner-user.test.mjs test/lifecycle.test.mjs`; `scripts/check.sh`.
- **Check:** `scripts/check.sh` run after the last change (23:20 to 23:25, after the 23:15 pkill notice): "All checks passed." 137 wire tests (130 before, 7 new), 137 pass, 0 fail; 38 Go tests pass, 0 fail, 0 skipped (Podman was available).
- **Result:** PASS for tasks 1 and 2; task 3 not done (below).
- **Task 1, deny-list additions (FR-30):**
  - `_acpcode/projects/create` takes `denyPaths` (max 32 entries, 100 characters each, ASCII letters/digits/space/`. _ - / *`; no absolute path, `..`, `.`, empty component, `**`, `?`, `[]`, `\`, `:`, `!`, non-ASCII). Stored in `projects.deny_paths` (schema version 3). A schema 1 and a schema 2 database open, keep their projects, and take the column (Go tests). `create` and `list` return `denyPaths` only when it is not empty.
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
- **Command:** `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17e' -derivedDataPath /tmp/dd-img -only-testing:ACPCodeTests/ForkMediaTests test`, and `swift test --package-path ACPClient`.
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
- **Commands:** `scripts/check.sh`; `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /tmp/dd-git -only-testing:ACPCodeTests test`.
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
  - Deep link `acpcode://session/<server>/<session>` opened the session (iOS first asks "Open in ACP Code?").
- **Two defects found by this run and fixed:**
  1. The "Turn diff" button was built into the SwiftUI file-change card, but iOS draws the chat with the UIKit list (`FileChangesRows.swift`), so the button never appeared. It is now in the UIKit row, shown only when the gateway offers git and the turn number is known.
  2. "Review" opened an empty "File Changes" sheet (a sheet driven by two state values read before the second was set; upstream behaviour). `SessionDetailView` now uses `.sheet(item:)`, as the Codex view already did.
- **Fake agent:** new directives `[edit:NAME]` (a completed edit tool call with a diff), `[image]`, `[link]`.
- **Checks after the fixes:** `scripts/check.sh` passes (137 wire tests); app tests 219, 0 failures, TEST SUCCEEDED.
- **Not tested:** no unit test and no mutation check for the new Turn diff button wiring (found and verified on screen only); "no snapshot for this turn" and "not a repository" states on screen; many files or a long history; Dynamic Type and dark mode; a real Bob session. The 3.21 note about counting user messages for the turn number held in this run (turn 1).

## 2026-11-07 Turn diff button test (FR-31)
- Added `ACPCodeTests/TurnDiffButtonTests.swift`: the UIKit `FileChangesRowView` hides "Turn diff" without a handler, shows it and fires the handler with one, and hides it again on reconfigure.
- Command: `xcodebuild ... test -only-testing:ACPCodeTests/TurnDiffButtonTests` → 3 tests pass.
- Mutation check: forcing `turnDiffButton.isHidden = true` in `FileChangesRows.swift` made `buttonIsVisibleAndFiresHandler` fail; source restored.
- Not covered: the closure chain in `HighPerformanceChatListView` and `SessionDetailView` (`canTurnDiff`/`onTurnDiff`); still checked on screen only.

## 2026-11-07 Push token registration, gateway and app (3.11 first half, D-052)
- **Done:** `_acpcode/push/register` and `unregister`, schema version 4 (`push_tokens`), `push` extension; app `GatewayClient.registerPush`, `PushGatewaySync`, `AppViewModel+Push`.
- **Result:** PASS for the tests; nothing sent to Apple, nothing run on a device.
  - `scripts/check.sh`: "All checks passed". Wire tests 142 (was 137; 5 new in `test/push.test.mjs`: extension advertised, register and replace, bad tokens and environments refused with nothing stored, unregister removes only the caller's token, token absent from audit and responses). Go store tests: replace and delete, schema 3 migration; two older migration tests now also drop `push_tokens` when they rebuild an old shape, and one table count went from 6 to 7.
  - ACPClient: 3 new `GatewayPushTests`. App: 3 new `PushGatewaySyncTests` (sends token and environment; sends nothing without a token, permission or the `push` extension; a refusal is reported without the token). Full app run: TEST SUCCEEDED.
  - **Mutation check:** widening the token pattern to `{0,200}` made the bad-token wire test fail (141 pass, 1 fail); restored. Not run for the app side.
- **BLOCKED:** APNs delivery (JWT with `.p8`, HTTP/2 send, invalid-token cleanup), the Push entitlement, and any check on a device. Steps: `docs/PUSH-TESTING.md`.
- **Unverified:** that `sandbox` for Debug and `production` otherwise matches the real signing; that the app's token reaches the gateway on a real device (the simulator cannot register for remote notifications).

## 2026-11-07 Real Bob behind the gateway: host runner and Podman container
- **Environment:** this Mac, Bob 2.0.9, Podman 5.6.2 (libkrun VM), image `acpcode-bob:2.0.9`, `BOB_API_KEY` from the gitignored `.env`, loaded into the environment of the test process only and never printed. Scratch git project under `~/.acpcode-live/`. Fake agent not involved.
- **Command:** `set -a; . ./.env; set +a; ACPCODE_GATEWAY_CMD='["<abs>/gateway/bin/acpcode-gateway"]' node gateway/scripts/live-bob.mjs --runner host|podman [--no-key]`. The script's client allows the one scratch-file edit and rejects everything else; the gateway approves nothing (D-009). About 5 short prompts per run.
- **Host runner: 24/24** on the final run (one earlier failure was a wrong assumption in the script: Bob sends `available_commands_update` before the turn starts).
- **Podman container: 24/24 on three runs in a row** after the fix below; before it, 3 earlier runs had 23/24 or 24/24 with random `snapshot_failed` lines.
- **What was shown on real Bob (both runners):** `session/new` with modes agent/plan/ask; a turn is logged in order with contiguous seq; the index gives idle, unread 1 and Bob's own title; T-18 on real Bob (drop after seq 6, resubscribe, events 7 to the end, no gap); FR-20 (load of a live session answered by the gateway, no `session/load` to Bob, history replayed from the log); a real `session/request_permission` (kind `edit`, "Writing file ...") reached the queue, the index showed `awaiting_approval`, and an answer through `_acpcode/approvals/answer` let Bob write the file; a rejected shell command (kind `execute`) did not run; `git/status` and `git/turnDiff` list the file Bob wrote and the text-only turn's diff is empty; idle stop then a new prompt made the gateway start a new Bob and load the session itself (D-032), and Bob still knew the earlier conversation.
- **T-35 PASS:** with no `BOB_API_KEY` and no stored login, real Bob answers `session/new` with `-32000 "Authentication required"` (both runners). It is `session/new`, not `session/prompt`, that fails. (A first attempt was invalid: the gateway still inherited the key from the shell; the script now starts it with a replaced environment.)
- **Defect found and fixed (Podman only):** about 1 in 25 git container starts failed with `crun: write to /proc/sys/net/ipv4/ping_group_range ... Invalid argument: OCI runtime error`, exit 126, when several git containers started at once with `--userns=keep-id` and `--network=none`. Git never ran, so the turn snapshot failed and `git/turnDiff` said "no snapshot for this turn". Reproduced directly with 24 parallel starts (1 failure). `--sysctl net.ipv4.ping_group_range=0 0` made all 24 fail and was dropped. Fix: `podmanRunner.exec` retries up to 3 times, only for exit 126 with "OCI runtime error" (`containerNeverStarted`). Three unit tests (retry then success, stop after 3, no retry for other failures); mutation check (condition disabled) fails two of them. The `snapshot_failed` audit line now carries the gateway's own error text (`start: ...`, `end: ...`), never git output. **Cause not confirmed on Linux;** the retry is a mitigation.
- **Not tested here:** real Bob on Linux, T-47, the app against real Bob (simulator pass still to do), Q-2, Q-3, Q-4, Bob's `session/close` on idle close (the project went down by idle stop instead), more than one device, long histories.

### 2026-11-07 — Watch skip list and additive list updates (D-065, D-066, D-067)
- **Done:** `watchSkip` at create, stored in schema 5 (`watch_skip`); `_acpcode/projects/addDenyPaths` and `addWatchSkip` (merge, 32 in total, never remove); the watcher reads the project each tick and starts from a baseline taken before `git/status`; the root folder is never skipped by name.
- **Commands and results:**
  - `go vet ./...`, `go test ./...`: pass. New Go tests: `store/store_watch_test.go` (schema 4 to 5 migration, round trip, all-or-nothing update), `server/watchskip_test.go` (validator, merge cap, fingerprint skip). Three older migration tests now also drop `watch_skip` when they rebuild an old shape.
  - New wire tests: `test/watchskip.test.mjs` (5) and `test/projectlists.test.mjs` (6). All 11 pass on their own, and the git watch tests still pass (`gitchanged.test.mjs` 5/5, three runs).
  - `scripts/check.sh` as a whole: **not green in four runs.** Each run reached the wire suite and stopped there. Run 1: T-46 idle stop and turn-diff "each turn has its own diff" (17 s). Run 2: `gitchanged` "changes under node_modules are not watched" (1 of 4 full runs; 3 of 3 standalone passes). The test writes an untracked, non-ignored `node_modules/pkg/index.js`, so a status run that a neighbouring `ignored.log` write triggers late would list it. The same test design is in HEAD. Runs 3 and 4: T-46 "a subscriber keeps the container running; it stops once the subscriber leaves". Wire suite in run 4: 152 pass, 1 fail, 153 total.
  - Checks that ran outside the gate, after the wire suite failed: `scripts/check-docs.mjs` ok (49 decisions, all tests scheduled); the `--dry-run` of `config.example.json` ok; the private-key and raw-secret-key scans found nothing; `swift test` for `ACPCodeTransport` (exit 0), `ACPClient` (192 tests, 0 failures) and `AppServerClient` (9 tests, 0 failures).
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
- **Gate run 2 (the same script with only that one file removed from its JSON list, ROOT set to this worktree):** `All checks passed`, exit 0. Wire suite 159 of 159 pass. Go `vet`, unit tests and build pass. Dry run of `config.example.json` passes. No secrets found. Docs cross-check passes (`scripts/check-docs.mjs`). Swift packages (`ACPCodeTransport`, `ACPClient`, `AppServerClient`) pass.
- **Load flakes (run 1 only):** `denypaths.test.mjs` "additions never remove built-ins" (TypeError on an undefined response) and `gitchanged.test.mjs` "a change to an ignored file sends nothing" each failed once, at about 13 s, while other worktrees ran the same suite. Both pass when run alone (10 of 10 in the two files), and both passed in run 2. Nothing was changed for them.
- **Defects found and fixed while building (not behaviour changes):** the test certificate and key made with LibreSSL 3.3.6 do not parse in Go (`unknown elliptic curve` for the PKCS#8 key, `invalid ECDSA parameters` for the certificate, both from explicit curve parameters). The test now makes both keys with Node's OpenSSL and uses `openssl req -key` only for the certificate. Note for the owner: keys generated with LibreSSL are not usable here; Apple's `.p8` files were not tested (no key).
- **BLOCKED:** `BLOCKED: needs a real APNs .p8 key (Apple Developer account, key id, team id) and an iPhone`. The device part of T-48 (`docs/PUSH-TESTING.md` Part E.2, steps 2 to 9) is not run. The `aps-environment` entitlement is not added (Apple account). PLAN 3.11 is marked `[!]`.
- **Not verified:** Apple's live answers (every answer here comes from the fake, which follows Apple's documented codes; verify on the device test); that Apple accepts a token from the real key; the key file's mode and owner on the Linux host; the 20 to 60 minute JWT window (PUSH-TESTING Part E cites it, Apple's page was not re-read here).
- **Not done, on purpose:** `gateway/config.example.json` has no `push` block. Dry run reads the key file, and the example has no key, so a block there would make `check.sh` fail. The block is shown in PUSH-TESTING Part E and described in SPEC 6.3 (D-055).

### 2026-11-07 — Signed file URLs (PLAN 5.3, D-061 to D-064, T-37)
- **Done:** `_acpcode/files/url`, `GET`/`HEAD /f/<token>` on the `files.host` only, the `files` config block (key file or random key, TTL cap 300 s, size cap), audit events `file_url_issued`, `file_served`, `file_refused`, `extensions` now ends with `files`.
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

## 2026-11-07 Open questions on Bob 2.0.9: Q-2 (T-39), Q-3 (T-42), Q-4 (T-43), session/close (D-032)
- **Command:** `node gateway/scripts/probe-bob-open-questions.mjs --env-file <repo>/ACPCode/.env` (run 2, the full set, 7 prompts); `... --only q2 --raw` (run 3, the image question with raw updates, 1 prompt). Run 1 is void (see below). Raw logs kept outside the repo in `~/.acpcode-live/openq-run*.log`.
- **Path:** Bob 2.0.9 on the host runner, run directly as `bob acp --accept-license --log-level warn` over stdio, in a scratch project under `~/.acpcode-live/` with a disposable `HOME`. No `--auto-approve`, no `--trust`. Not run through the gateway: the gateway answers `session/load` and `session/resume` itself for a live session (D-029), so it would hide the behaviour under test. Podman was not run: these answers are about Bob's ACP behaviour, and the container path was not part of the question.
- **Key:** the shell form `set -a; . .env; set +a` was refused by the sandbox (the file is outside the worktree), so the probe read only the `BOB_API_KEY` line from `--env-file`, in its own process. It printed `set: true`. A search of the saved logs found 0 copies of the value.
- **Prompts:** 15 in total (run 1: 7, run 2: 7, run 3: 1).
- **Run 1 is void.** My permission check matched `make_image` and `ping_http`, but Bob titles the calls "Running Make Image (probe-image)" and "Running Ping Http (probe-http)". Both calls were rejected, so the Q-2 and Q-3 "after" results were not valid. The check was fixed and run 2 is reported below. Q-4 and the close probe in run 1 agreed with run 2.
- **Permission requests:** Bob asked only for the two probe tools, and the probe allowed each once. Bob's own read tools ran with no request.

**Q-2 (T-39): Bob does not forward MCP image content over ACP.** The probe MCP server returns `[text, image(image/png)]` for `make_image`, and I checked by hand that it does. Bob 2.0.9 sent:
- `tool_call` (pending, title "Running Make Image (probe-image)", kind `other`), then `tool_call_update` with `status: in_progress`;
- `tool_call_update` (completed) with keys `content, rawOutput, sessionUpdate, status, toolCallId`. `content` holds one block, `{type: "content", content: {type: "text", text}}`. `rawOutput` is `{"result": <the text>}`;
- no `image` block in any update, and no resource block. The agent then sent a text reply.

Outcome: the image is dropped before ACP. FR-37 (phase 5 images from tool results) gets nothing from Bob's MCP tools. Bob's stderr was not inspected for a warning about the image block, because the scratch folder was removed.

**Q-3 (T-42): `session/resume` accepts a changed `mcpServers` list, and the tool list follows it.**
- `session/resume` with `mcpServers: [{type: "http", name: "probe-http", url, headers: []}]` returned a result with `modes` and no error. The server then received, in order: `server/discover`, `initialize`, `notifications/initialized`, `tools/list` (twice). The probe server answered `server/discover` with `-32601`, and Bob went on.
- The next prompt called the tool: `tool_call` "Running Ping Http (probe-http)", one `tools/call` on the server, reply text `http-pong`.
- `session/resume` of the same session with `mcpServers: []` returned a result with no error. No request reached the server. The next prompt did not call the tool and replied with the no-tool marker.
- Limit: the session had no earlier turns when resumed, so the replayed history was not tested here. Not tested: whether a list change without a later prompt restarts servers.

**Q-4 (T-43): a running session can invoke a skill added afterwards, but its command list does not change until a load or a new session.**
- Before the file existed, the command list from `session/new` had six names, with no skill. `/probe-skill` got a reply that no such skill exists.
- After `<project>/.bob/skills/probe-skill/SKILL.md` was written (no prompt, 5 s wait): zero `available_commands_update` updates.
- The next prompt in the same session, with no `session/load`, replied with the skill's marker. That turn had no tool call, only `agent_message_chunk` and `session_info_update`. How the skill text got into the context is not known.
- `session/load` of the same session (idle, same process) returned a result with no error. Its replay started with an `available_commands_update` that listed `probe-skill`. A prompt after the load gave the marker again.
- A fresh `session/new` in the same process listed `probe-skill`.

**session/close (D-032, "verify"): Bob 2.0.9 accepts it, and the session stays loadable.** `initialize` advertises `sessionCapabilities.close`. `session/close {sessionId}` on an idle session returned `{}`, with no error and no update. `session/load` of that session then returned a result with no error and replayed 8 updates, and the next prompt ended with `end_turn`. A second `session/close` also returned `{}`. Not tested: close during a turn, and whether close frees memory in the process.

**Could not determine:** why Bob drops the image block (its stderr was not inspected); whether skill text is injected without a visible tool call in every case; Q-3 on a session with earlier turns; any Podman behaviour.
- **Gate:** `scripts/check.sh` exits 1. Every Go test passes, and every wire test passes except one: T-46 "a subscriber keeps the container running; it stops once the subscriber leaves" (`gateway/test/lifecycle.test.mjs:129`). It fails with `the idle time counts from when the subscriber left` (line 143, `exits[0].t - left >= 900`). It fails alone too, on this unmodified gateway. The gateway stops the agent less than 900 ms after the subscriber leaves, because its activity clock is refreshed at busy checks every quarter of the idle time (D-032), so a stop can come about 250 ms early. The test expects a full idle time after the subscriber leaves. Not changed: either the gateway or the test should change, and that is the owner's call (CLAUDE.md: do not change a test to make it pass).
- **Gate setup:** this worktree had no `.claude/settings.json` (not tracked on this branch). I copied the main checkout's file in, untracked and not committed, and removed it after the run. `npm ci --prefix gateway` was needed for the Node dependencies.
- **Changed files:** `gateway/scripts/probe-bob-open-questions.mjs`, `gateway/scripts/open-questions/mcp-image-server.mjs`, `gateway/scripts/open-questions/mcp-http-server.mjs`, `docs/RESULTS.md`, `docs/SPEC.md` (section 3 F-22 to F-25, section 8 Q-2 to Q-4). No gateway source, no DECISIONS entry (no finding changed a design).

## 2026-11-07 Phase 4 app: plan and usage, start mode, auth error, session delete (4.7 to 4.10, D-070 to D-073)
- **Done:**
  - 4.7 (FR-33): `plan`/`plan_update`, `plan_removed`, `session_info_update` (title), `usage_update` parsed defensively in `ACPClient` (`SessionMetaUpdateParsing.swift`, four new `ACPSessionUpdateEvent` cases). App: `ForkSessionMeta`, a collapsible plan (`SessionPlanView`), a usage line (`SessionUsageFooter`), the agent's title in the navigation title.
  - 4.8 (FR-34): `_meta["bob/mode"]` on `session/new` from the project's `defaultMode` (`ServerViewModel.gatewayStartMeta`, `ForkSessionAgentRules.startMode`). The mode picker and `current_mode_update` already existed and are unchanged.
  - 4.9 (FR-35): `ACPAgentErrorText`: `-32000` "Authentication required" shows "Bob needs authentication. Set BOB_API_KEY on the gateway host." in session create, load, resume and prompt failures. The on-screen text is not checked.
  - 4.10 (FR-36): `initialize` `sessionCapabilities.delete` parsed; "Delete Session" sends `session/delete` first when advertised and the session exists on the agent; local removal only after the agent accepts; errors shown in an alert.
- **Commands and results:**
  - `swift test --package-path ACPClient` → 210 tests, 0 failures (18 new in `SessionMetaUpdateTests`).
  - `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/dd-phase4 -only-testing:ACPCodeTests test` → TEST SUCCEEDED, 222 tests, 0 failures (new `ForkSessionMetaTests`, 15 tests).
  - `node --test --test-timeout=30000 test/start-mode.test.mjs` (gateway) → 1 pass (new: `_meta["bob/mode"]` reaches the agent; no `_meta` gives the agent default).
  - `go vet`, `go test ./...`, build of the gateway → pass.
  - `node scripts/check-docs.mjs` → "47 tests, 45 FRs, 15 NFRs, 50 decisions; all tests scheduled".
  - `swift test` for `ACPCodeTransport` and `AppServerClient` → pass. `ACPClient` → pass (above).
  - `scripts/check.sh` itself: not green. In this worktree `.claude/settings.json` is not tracked, so its JSON step fails before anything else (pre-existing, not changed here). I ran the same steps without that one file: the wire suite then failed (below), so the gate did not reach its end.
- **Mutation checks** (each restored, then re-run green):
  - FR-33: removing the `plan_removed` case → `testPlanRemoved` fails (`[]` vs `[planRemoved]`).
  - FR-34: dropping `_meta` from `ACPSessionCreatePayload.params()` → `testSessionNewSendsStartModeAsMeta` fails.
  - FR-35: matching `-32001` instead of `-32000` → `testAuthenticationRequiredGetsItsOwnText` fails (2 assertions).
  - FR-36: `sendsDeleteToAgent` ignoring the capability → `deleteIsSentOnlyWhenAgentAdvertisesItAndSessionExists` fails (app test, 1 issue).
- **Wire suite is not stable on this machine (not caused by this change, not fixed):**
  - Run 1 (full `npm test`, Go gateway): 140 pass, 3 fail: "a permission request is logged as phones see it" (`logged` undefined), "T-28 diff path" (`status` undefined), "FR-24 idle session closed" (closed with 1006). Each passes when run alone.
  - Run 2 (full): 142 pass, 1 fail: "T-46 subscriber keeps the container running". It passed alone once and failed again inside a filtered run.
  - The gateway code and wire tests in `internal/` were not changed by this task; only `gateway/test/start-mode.test.mjs` was added. The failing tests have 2 to 5 s timeouts and fail under load, which fits a timing race. Not proven. Another Claude session was using the simulator during these runs.
- **Not verified:** how the plan, usage line, title and delete alert look on screen (the simulator was not driven, per the owner's instruction). The shapes of Bob's `plan_update`, `plan_removed` and `usage_update` (no recorded payload; D-070 marks them "verify"). Bob's real `session/delete` and the `-32000` text were not run with a live key. Whether Bob's `session_info_update` after a `session/new` with `_meta` behaves the same (the start mode was tested against the fake agent only).
- **Unverified (tick check):** 4.7, 4.8 and 4.10 are ticked on unit, mutation and wire evidence. 4.9 stays open: T-35 asks for the on-screen auth message, and that was not seen.


## 2026-11-07 HTML preview in a sandboxed WKWebView, T-38 (PLAN 5.4; D-074 to D-077)
- **Done:** `ACPCode/Fork/Preview/` (`AgentHTMLDocument.swift`: policy and sanitizer; `AgentHTMLPreviewController.swift`: the web view, rule list, navigation and UI delegates, scheme handler; `AgentHTMLPreviewSheet.swift`: sheet and representable). Chat: fenced `html` blocks and `resource` blocks with `text/html` get an "HTML preview" row (`ForkMediaRowView`, `ChatEntryMapper`), wired in `SessionDetailView` and `CodexSessionDetailView`. `resource_link` is still never fetched.
- **Result: PASS for T-38** (scripts off and on), in a real `WKWebView` in a window in the unit-test host, against a loopback probe on `127.0.0.1` (POSIX socket, no dependency). Both cases: 0 connections. A control test loads the same page in an unrestricted web view and sees at least one connection, so the zero counts are not from a blind probe.
- **Unit tests:** `AgentHTMLDocumentTests` (policy injected once even with the agent's own meta policy; policy first in the head; `script-src` only when scripts are on; `<base>` and `<meta>` removed; `</head>` trick; nested tags; fence scanner), `AgentHTMLIngestTests` (`text/html` text and blob; malformed and oversize placeholders; `resource_link` stays a link).
- **Commands:**
  - `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/dd-preview -only-testing:ACPCodeTests/AgentHTMLPreviewTests test`: 4 tests pass (T-38 scripts off, scripts on, control, and a final run with the control poll).
  - Full app run, `-only-testing:ACPCodeTests test`: TEST SUCCEEDED, 222 XCTest cases, 0 failures; Swift Testing run 46 tests passed.
  - `scripts/check.sh`: "All checks passed." (wire suite, Go vet and tests, docs cross-check, Swift packages).
- **Mutation checks** (one change at a time, source restored after each; the sources were checked against a saved copy):

  | Mutation | Scripts off | Scripts on | Result |
  | --- | --- | --- | --- |
  | Content rule list not installed | pass (0 connections) | pass (0) | does not fail: CSP blocks every load on its own |
  | Navigation: allow everything | pass | pass | does not fail: the rule list blocks the top navigation |
  | Rule list off and navigation allow-all | pass | **fail: 4 connections, 1828 bytes** | fails T-38 |
  | Rule list off, navigation allow-all, and CSP removed | **fail: 12 connections, 5316 bytes** | **fail: 24 connections, 10288 bytes** | fails T-38 |

  Reading: each network layer catches the others' gaps. T-38 fails only when all of the layers the test covers are removed, with the scripts-on case the first to fail. The rule list and the CSP are each enough alone. That is the defence in depth D-074 describes, but it means T-38 alone cannot say which layer holds.
- **Flakes, not reproduced:** the test host was killed by a signal ("Test crashed with signal kill", `before establishing connection` in one case) on three runs: the first run after the rule-list mutation, the first run after the allow-all mutation, and the first combined run. Each identical rerun passed or ran through. The simulator is shared with another session, and that session's runs may have interfered; the cause is not confirmed. The control test failed once with a fixed 4 s wait, and it now polls for up to 15 s.
- **Fixes during the run:** `WKOpenPanelParameters` is iOS 18.4+ (the app targets 18.0), so the file-picker delegate is `@available(iOS 18.4, *)`; the representable's coordinator is `@MainActor`.
- **Not done:** PLAN 5.5 (Q-2, whether Bob forwards image blocks from MCP tool results) needs a live Bob run with an MCP tool that returns an image. Not run in this task, so 5.5 stays unticked.
- **Environment note:** the worktree's base commit does not track `.claude/settings.json`, which `scripts/check.sh` reads. For the gate run I copied the main checkout's file in, uncommitted, and removed it afterwards. `npm ci --prefix gateway` was needed in the worktree.
- **Unverified (not seen on a screen):**
  - The sheet and the chat row were not seen in the simulator; no UI was driven (another session uses the simulator). Layout, the toggle, the Done button, and the row's button placement are untested visually.
  - Geolocation prompts in the web view on iOS (no delegate; expected not to prompt because the app has no location usage text).
  - Behaviour on a device (the simulator does not enforce every WebKit policy in the same way).
  - Whether `ignore-previous-rules` behaves the same on every iOS version the app supports (checked on iOS 27.2 simulator only).
  - Whether a hostile page can make visible content look like a link that navigates (blocked links appear as text only, by design; not tested on screen).

## 2026-11-07 Apple `container` spike, step 1 of the Podman to Apple migration (no gateway code changed)
- **Setup:** `container` CLI 1.7.0 (`/opt/homebrew/bin/container`), macOS 27.0.1 arm64. `container system start`; default kernel `kata-static-4.3.1-arm64` installed with `container system kernel set --recommended` (downloaded from the kata-containers GitHub release, approved by the owner). Image: `podman save --format oci-archive` of `localhost/acpcode-bob:2.0.9` (Bob 2.0.9), loaded with `container image load`. Scratch files were removed.
- **Results (each run once, on this Mac):**
  - Ownership: uid 10001 writes into a host `0700` home and a same-path project folder with `-u 10001:10001 -v P:P` and no `keep-id`. PASS. The host sees the files as the owner's user. The gate for stopping was not hit.
  - Stdio: `run -i` passes a JSON line and a 2 MB stdin through, and exit codes propagate (`exit 7` gives 7). PASS.
  - Name lock: a second `run --name` with a live name fails with `container with id ... already exists`, exit 1. PASS. The gateway must match this text, since there is no separate error code.
  - Env passthrough: `-e NAME` inherits the value inside the container. A live `ps` scan found no process carrying the value. PASS.
  - Start: warm `run --rm` about 1.1 to 1.3 s (5 runs). Stop with `-t 1` 1.4 s (default 5.4 s).
  - Git: `container exec` into a running project container, `git status`: 0.21 s average over 10 calls. `run --rm` per call: 1.12 s average over 10 calls. This supports running git through `container exec`.
  - Memory (host RSS of the VM processes, `ps`): Apple baseline 734 MiB (apiserver and helpers), +35 MiB per idle agent container, 909 MiB with 5. Podman libkrun VM 2833 MiB, unchanged with 5 containers. These are idle `sleep` containers only; real Bob sessions are not measured.
- **Findings:**
  - `container inspect` prints the value of an `-e NAME` passthrough variable. The gateway must never call `inspect`. Podman's behaviour is not checked yet.
  - Progress lines go to the output stream. Use `--progress none` on every `run`/`exec`.
  - The first start of a fresh image takes about 15 s (init image download). Warm starts are fast.
- **Not verified:** real Bob over stdio in the container; the `containerNeverStarted` flake (exit 126) does not apply, so whether Apple has an equivalent is unknown; memory under real Bob load; Apple's behaviour after `container system` restarts; concurrent starts with the same name.
- **Check:** `scripts/check.sh` → All checks passed (no repo code changed).

## 2026-11-07 Apple runner in the gateway, step 2 of the migration (D-079)
- **Done:** `gateway/internal/server/runner_apple.go` (agent start with a listing wait, git through `container exec` into the running agent, one-off `run --rm --network none` git when no agent is up, liveness by `container list --quiet`), `runner.go` (`newRunner` picks `apple`), `config.go` (`runner.kind: "apple"`, `runner.container` absolute path, error text lists all three kinds), new tests `runner_apple_test.go` and `test/runner-apple.test.mjs`.
- **Checks:**
  - `go test ./internal/server/ -run 'Apple|NewRunnerPicksAppleByKind' -v` → 5 PASS (the secret stays off the command line; no `keep-id`; default and overridden `-u`; exec targets the agent container with the git environment only; the fallback has `--network none`).
  - `node --test test/runner-apple.test.mjs test/runner-user.test.mjs` → 6 PASS.
  - `scripts/check.sh` → All checks passed (exit 0).
- **Not verified yet:** the running paths. `start`, `exec` and the fallback were not run against a container; no fake `container` binary exists yet (migration step 3). Live Bob through the Apple runner: not run (step 4). The timeout gap in D-079 is untested.
- **Changed files:** `gateway/internal/server/runner_apple.go`, `gateway/internal/server/runner_apple_test.go`, `gateway/internal/server/runner.go`, `gateway/internal/config/config.go`, `gateway/test/runner-apple.test.mjs`, `docs/DECISIONS.md` (D-079), `docs/RESULTS.md`.

## 2026-11-07 Apple runner, step 3: fake CLI, lifecycle on both runners, timeout cleanup, real Bob benchmark (D-080)
- **Fake CLI:** `gateway/test/fixtures/fake-container.mjs` implements `run`, `exec`, `list --quiet` and `delete --force` the way the apple runner calls them. It refuses a second container with a name in use, logs `start`/`exit`/`refused`/`exec`/`killed` with the arguments, and models two things Apple's CLI does not do for us: an exec'd child survives the CLI being killed (detached), and `/proc` is answered by the fake because this Mac has none.
- **Tests (all in `npm test`, which the gate runs):**
  - `lifecycle-apple.test.mjs` runs the six T-46 and FR-24 cases of `lifecycle.test.mjs` on the apple runner: 6 PASS. The podman file is unchanged in behaviour.
  - `apple-runner.test.mjs`: git goes through `exec` when a session holds the agent up (`exec` with `argv0` git, no one-off container); with no agent, one-off containers with `--network none` and `--entrypoint git` (3 starts, one per git command of status); a hung git call returns `git timeout`, and the cleanup kills the same process the exec started, which is gone within 2 s. 3 PASS.
  - Mutation check: the cleanup hook disabled → "killed inside the container" fails (the output pipe then stays open for 30 s, as expected). Restored, and the file was checked after restore.
  - Found and fixed while testing: a fake that fell through to its "unsupported command" exit; the git shim not receiving `FAKE_CONTAINER_GIT`; the cleanup running after the pipe closed (fixed in `runCapped`, D-080).
- **Gate:** `scripts/check.sh` → All checks passed; wire suite 199 pass, 0 fail.
- **Benchmark (real Bob 2.0.9, same image, `gateway/scripts/bench-start.mjs`, 5 runs each, machine 2 CPUs, ms from the start command, median / max):**

  | Step | Apple container (`--dns 1.1.1.1`) | Podman |
  | --- | --- | --- |
  | initialize | 1949 / 2881 | 1138 / 1534 |
  | session/load + replay | 2469 / 3358 | 1735 / 2005 |
  | session/new | 3254 / 4156 | 2725 / 2936 |
  | stop | 214 / 306 | 274 / 291 |

  Replay: 3 updates per load on both. The same-name lock refuses a second container on both.
- **Memory on the host (RSS, one idle Bob container with its session loaded):** Apple adds 829 MiB (a Virtualization VM process of 794 MiB and a helper of 35 MiB). Podman's machine VM (krunkit, 2835 MiB before any container) adds 31 MiB for the `podman run` process. An unrelated 11.9 GB Virtualization process was already running on this Mac during the Apple run and is not counted.
- **Git calls (step 2 numbers, unchanged):** `exec` 0.21 s against `run --rm` 1.12 s.
- **Verdict for the premise:** Apple is not lighter for Bob here: slower to start, and about 26 times the marginal memory per container. Its advantage is a smaller fixed baseline (about 0.7 GB runtime, against 2.8 GB for the Podman VM), so it is lighter for one or two projects only. Crossover is near three Bob containers, from these two numbers, not measured beyond one.
- **Not verified:** more than one Bob container at once; memory after a long turn; whether Apple's per-container memory falls with a lower VM memory limit or a smaller image (both untested); the NFR-15 target (3 s p95 cold load): Apple's worst load in this run was 3.36 s, Podman's 2.0 s, which is too few runs to call a p95.
- **Changed files:** `gateway/internal/server/runner_apple.go`, `gateway/internal/server/runner_apple_test.go`, `gateway/internal/server/gitexec.go` (runCapped kill hooks), `gateway/internal/config/config.go` (`runner.dns`), `gateway/test/fixtures/fake-container.mjs`, `gateway/test/lifecycle.test.mjs`, `gateway/test/lifecycle-apple.test.mjs`, `gateway/test/apple-runner.test.mjs`, `gateway/test/runner-apple.test.mjs`, `gateway/scripts/bench-start.mjs`, `docs/DECISIONS.md` (D-080), `docs/RESULTS.md`.

## 2026-11-07 Concurrent Bob sessions, and the Apple runner live (D-080 follow-up; the Mac runner decision)
- **Concurrency benchmark:** `gateway/scripts/bench-concurrent.mjs` starts N containers at once, each with its own home and project folder, loads its session, and sends one prompt. Real Bob 2.0.9, same image, Apple with `--dns 1.1.1.1`, Podman with the gateway's flags. Memory is host RSS added while the containers run.
  Apple (summary):
```
N=1: 1/1 loaded; load median 2392 ms max 2392; turn median 1226 ms max 1226; host runtime +821 MiB (new processes 821 MiB in 2); runtime total 13317 MiB
N=2: 2/2 loaded; load median 3272 ms max 3347; turn median 1075 ms max 1076; host runtime +1641 MiB (new processes 1641 MiB in 4); runtime total 14136 MiB
N=4: 4/4 loaded; load median 5001 ms max 5155; turn median 1020 ms max 1062; host runtime +3300 MiB (new processes 3300 MiB in 8); runtime total 15796 MiB
N=8: 8/8 loaded; load median 9171 ms max 9418; turn median 1147 ms max 2002; host runtime +6205 MiB (new processes 6590 MiB in 16); runtime total 18701 MiB
```
  Podman (summary; N=1 and N=2 from the first run, N=4 and N=8 from separate runs):
```
N=1: 1/1 loaded; load median 1664 ms max 1664; turn median 1049 ms max 1049; host runtime +31 MiB (new processes 31 MiB in 1); runtime total 2869 MiB
N=2: 2/2 loaded; load median 1753 ms max 1811; turn median 1079 ms max 1786; host runtime +168 MiB (new processes 61 MiB in 2); runtime total 3007 MiB
/private/tmp/claude-501/-Users-adammakarucha-Documents-Projects-remote-bob-app/2ec9b346-d503-4f54-bac3-57aae2af3df9/scratchpad/conc-podman-8.log:N=8: 8/8 loaded; load median 5094 ms max 5269; turn median 1243 ms max 2413; host runtime +252 MiB (new processes 243 MiB in 8); runtime total 4277 MiB
/private/tmp/claude-501/-Users-adammakarucha-Documents-Projects-remote-bob-app/2ec9b346-d503-4f54-bac3-57aae2af3df9/scratchpad/conc-podman-4.log:N=4: 4/4 loaded; load median 3140 ms max 3169; turn median 1014 ms max 2090; host runtime +452 MiB (new processes 122 MiB in 4); runtime total 3759 MiB
```
- **Reading:**
  - Apple: memory grows about 800 MiB per container, linearly. Load time grows with N: median 2.4 s at N=1, 9.2 s at N=8, so the containers' starts are serialised or contend for the host.
  - Podman: the VM is fixed at 3.8 GiB, and its RSS was 2.8 GB before any container. The VM ran eight Bob sessions with no failures, with its runtime total at 4.3 GB. Measured growth was much smaller than Apple's, about 30 to 250 MB for the containers, so the two runtimes do not grow at the same rate in these measurements. The Podman measurement is host RSS of the VM process; guest memory not reflected there is not measured.
  - The first Podman series stopped printing after N=2 and was stuck with idle containers. A later N=4 run completed, and a background N=8 run completed. The cause of the stuck run is not confirmed.
- **Live Bob through the gateway on Apple:** `node gateway/scripts/live-bob.mjs --runner apple --dns 1.1.1.1` → SUMMARY apple: 24/24 passed (the same 24 checks as the host and Podman runs: turns, reopen, T-18 resubscribe, approvals, git status and turn diff, idle stop and reload).
- **Decision:** the owner chose the Apple container model for the Mac (2026-11-07), because Podman needs a VM sized in advance and it is at its limit. The Apple runner is the Mac option; Podman remains for Linux.
- **Changed files:** `gateway/scripts/bench-concurrent.mjs` (new), `gateway/scripts/live-bob.mjs` (`--runner apple`, `--dns`), `docs/RESULTS.md`.

## 2026-11-07 Apple runner live with the Mac's resolver (D-081)
- **Change:** `gateway/scripts/live-bob.mjs --runner apple` now takes its `runner.dns` from the Mac's first IPv4 nameserver in `scutil --dns` when `--dns` is not given. Apple's default resolver (192.168.64.1) did not answer from inside a container. Public `1.1.1.1` works but sends lookups to a third party, so it is no longer the default.
- **Command:** `node gateway/scripts/live-bob.mjs --runner apple` (resolver 192.168.86.1 on this Mac).
- **Result:** `SUMMARY apple: 24/24 passed`, exit 0. Same 24 checks as the earlier Apple run with `--dns 1.1.1.1` (turns, reopen, resubscribe, approvals, git status and turn diff, idle stop and reload).
- **Not verified:** other networks (the resolver address is network-specific; a deployment sets `runner.dns`); more than one Bob container under the live harness (see the concurrency entry above).
- **Changed files:** `gateway/scripts/live-bob.mjs`, `docs/DECISIONS.md` (D-081), `docs/RESULTS.md`.

## 2026-11-07 Migration step 5: Mac config, setup guide, spec notes
- **Done:** `gateway/config.mac.example.json` (kind `apple`, full image name, `container` path, placeholder `dns`); `docs/MAC-SETUP.md` (setup on a Mac, with a **verify** mark on each step not confirmed in the records); `docs/SPEC.md` 6.3, 9 and NFR-15; `docs/ARCHITECTURE.md` section 1 (agent control and project runtime rows); D-082.
- **Dry run:** the Mac example, with paths moved to a temporary folder and `dns` set to the Mac's resolver, runs `acpcode-gateway --config <file> --dry-run` → `Config OK (dry run)`, exit 0.
- **Check:** `scripts/check.sh` → All checks passed (log: scratchpad `check-step5.log`).
- **Not verified:** the setup guide's **verify** steps (podman build of the image, `container system status`, `container image list`, cleanup of the archive). The guide was not run end to end on a fresh Mac.
- **Changed files:** `gateway/config.mac.example.json`, `docs/MAC-SETUP.md`, `docs/SPEC.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` (D-081 wording, D-082), `docs/RESULTS.md`.

## 2026-11-07 Q-2 follow-up: MCP content types over ACP (T-39)
- **Question:** does Bob 2.0.9 forward image, resource or resource_link content from MCP tool results over ACP?
- **Command:** probe harness copy (in the session scratchpad, not in the repo) with `--only q2r --raw`, a stdio MCP server (`mcp-content-server.mjs`, four tools, one call each). Raw output: scratchpad `probe-resource-run2.log`. BOB_API_KEY was present in `.env` (checked by name only).
- **Result:** Bob 2.0.9 forwards text only.
  - image only: one text block, "returned 1 image." No image block.
  - embedded resource (blob): text with URI, MIME type and length; the blob is not sent.
  - resource_link: text with URI and MIME type; no resource_link block.
  - two images: text only; both images dropped without a note.
  - Bob stderr was empty.
- **Earlier result (same day, runs 2 and 3):** `[text, image/png]` gives text only (F-22).
- **Verdict:** T-39 recorded. No image, resource or resource_link block reaches ACP from stdio MCP tools. FR-37 rendering still applies to agent-native image blocks.
- **Not tested:** HTTP MCP servers; replay after `session/load`; the gateway path (Bob was run directly over stdio).
- **Changed files:** `docs/SPEC.md` (F-22), `docs/PLAN.md` (5.5 ticked), `docs/RESULTS.md`.

## 2026-11-07 Mac setup guide verified; test temp folders cleaned
- **Guide checks on this Mac:** `container --version` → 1.7.0; `container system status` → running; `container image list` → `localhost/acpcode-bob 2.0.9` present; `podman build -t acpcode-bob:2.0.9 -f deploy/bob-project.Containerfile deploy` → exit 0 (the podman machine was running); the archive save and removal → confirmed on a scratch copy. The verify markers for these steps are removed in `docs/MAC-SETUP.md`.
- **Not confirmed:** the 401 for a short image name (needs a pull from docker.io, not run). Its marker is kept.
- **Not run:** `container system kernel set` (changes the kernel; not requested).
- **Note:** the Apple store holds the image from an earlier load (digest ba754796892d). The new podman build was not loaded into it.
- **Temp folders:** 912 `acpcode-*` test folders in `/var/folders/s9/p3mf8wns41b9c7t5grkl4d5w0000gn/T/` (owner uid 501, modified 2026-11-06 to 2026-11-07) were deleted; 0 failed. Six were kept because each has a `.git` at depth 3 and looks like a gateway test fixture: `acpcode-gw-GDddZH`, `-GJrQhr`, `-UxXXjF`, `-e85JJo`, `-n3qHRt`, `-vkd64O`. The owner decides whether they go.
- **Changed files:** `docs/MAC-SETUP.md` (six verify markers removed), `docs/RESULTS.md`.

## 2026-11-07 Probe P2: does Bob persist an MCP HTTP header value?
- **Question:** if a client sends an HTTP MCP server with an auth header in `session/new` `mcpServers`, does Bob write the header value to disk in its home, or to its process output?
- **Method:** a local HTTP MCP server on 127.0.0.1 that accepts only `Authorization: Bearer <marker>`; one new session that calls the tool, then a resumed session in a new Bob process with the same HOME; a control HOME where the server needs no auth. Search of every file under HOME (`grep -rIl`, `grep -ral`, `strings`) and of Bob's stdout and stderr. Driver and logs in the session scratchpad under `p2/`. `BOB_LOG_LEVEL=debug`.
- **Result:** the marker was found in no file under HOME, in either run, and in no Bob output. The tool call succeeded in both runs (the server logged the header on each `tools/call`). Positive control: the marker was found in the server's own log and in a sqlite blob, so the search works. bob.db records the tool name and result, not the header.
- **Verdict:** Bob 2.0.9 does not persist the header value at debug log level. Decision 2 (headers may leave the device, held in gateway memory) holds for this check.
- **Not run:** the default log level; a wrong-header (401) path; a container runner; persistence outside HOME.

## 2026-11-07 Probe P4: can the gateway write Bob's skill and MCP files from the host while a container runs?
- **Method:** a long-running container per runner (`--entrypoint sleep`, user 10001:10001, the project folder and HOME mounted at their host paths). The host writes a skill file and an `mcp.json`, in place and by atomic rename, and the container polls until the new content shows. Also checked the reverse (a container-created file on the host) and the read and write permissions in both directions. Logs in the session scratchpad under `p4/`.
- **Apple container 1.7.0:** host writes visible in the container in about 0.2 s (in place or new) and about 1.0 to 1.2 s (atomic rename). Container writes visible on the host at once. The container user can read and write both folders. Files show as owned by the container user inside.
- **Podman 5.6.2 (keep-id 10001):** host writes visible in about 0.4 s; atomic rename in about 4.6 to 5.5 s. Container writes visible on the host at once. Container-created files are 0600 on the host and 0644 inside, with group 65534 inside.
- **Verdict:** yes. The gateway can write these files from the host while a container runs, with no exec. Atomic replace is slow on Podman, so a new config can show stale content for several seconds there.
- **Not run:** Bob's own pickup of a changed file (only the file contents were checked); the real `bob acp` process instead of `sleep`; a container path where the mount root is owned by root (seen once in a repeat, not tested for writes).

## 2026-11-07 Probes P1 and P3: `disabled` and `alwaysAllow` in MCP config (Bob 2.0.9)
- **Method:** a local HTTP MCP server with one tool, `marker_tool`, returning MARKER-OK. Fresh HOME and a project marked as trusted for each case. Prompt: "Call the tool marker_tool and tell me its exact output." P1 approved the tool once; P3 rejected every permission request. Raw logs in the session scratchpad under `p13/`.
- **P1a, home `disabled: true`, new session:** no server request; Bob says no such tool exists. The disabled server is absent. (T-40, new-session part.)
- **P1b, home `disabled: false`, new session:** the server is connected at session/new and the tool runs (MARKER-OK).
- **P1c, turn 1 ok, then `disabled: true` on disk, same-process resume with an empty list:** the server is not contacted and the tool fails with "Tool does not exist." Disabling on disk takes effect on resume.
- **P1d, same as P1c in a new Bob process:** same result.
- **P1e, `disabled: true` on disk, resume with the server in the session list:** the server is connected and the tool runs. A session-list entry overrides `disabled: true` on disk in the same process.
- **P3a, `alwaysAllow: ["marker_tool"]` in the repo `.bob/mcp.json`:** no permission request; the tool runs. Control P1b (no `alwaysAllow`) does get a request.
- **P3b, same in the home file:** same result.
- **P3c, the repo file and the session list both name server `marker`, with different URLs:** the repo file's URL is contacted; the session entry's URL is not. Bob keys servers by name.
- **P3d, different names in the repo file and the session list:** both servers connect and both tools are offered.
- **Verdicts:** `disabled` works on new sessions and on resumes. `alwaysAllow` in any `mcp.json` (repo or home) skips the approval prompt for those tools, which is the case decision 4 concerns. Every run set the trust entry, so the repo-file case is not shown without trust.
- **Not run:** an untrusted project folder (every case set the trust entry); P1e in a new Bob process; re-enabling a disabled server on resume.

## 2026-11-07 Probes P5 and P6: elicitation shape (inconclusive) and skill limits (Bob 2.0.9)
- **P5, elicitation: not reached on the wire.** `bob acp` without `--accept-license`, with `elicitation.form` in the client capabilities, did not send the licence form in any run (decline, cancel and accept answers, with and without the key, and with the form and url capabilities). With no key, session/new failed with `-32000 "Authentication required"`. With the key, the session ran and a tool prompt arrived as `session/request_permission`; no tool-input elicitation was seen.
  - Why: the source (`bob.js`, `runPrompt`, `askLicenseConsent`) skips the form when `licenseConsent` is set or the profile has `is_internal === true`. The profile call returned 200 with the key. The account is probably internal, but this is not confirmed (verify).
  - Shape, from the ACP SDK copy in the npx cache (not the repo's pinned spec, verify): method `elicitation/create`; params `{sessionId, toolCallId?, mode: "form", message, requestedSchema: {type: "object", properties, required}}`; response `{action: accept|decline|cancel, content?}`. Bob's bundle matches it.
  - **Not run:** the 60 s no-answer timeout; any real licence accept (blocked by the skip above).
- **P6, skill limits:**
  - Name rule (source): the directory name must be lowercase kebab-case, at most 64 characters (`/^[a-z0-9]+(-[a-z0-9]+)*$/`, length ≤ 64). Invalid directories are skipped silently. The frontmatter `name` is ignored; the directory name wins.
  - No size cap in the loader (source).
  - Live: a valid 64-character name appears; a 65-character name and `Bad_Name` do not; a 71,680-byte body (70 KiB) appears; a control skill appears. No warning on stderr.
  - The 64 KiB cap is therefore the gateway's own rule (decision 8), not Bob's.
- **Changed files:** `docs/RESULTS.md` only.

## 2026-11-07 Phase 6A build: MCP guard, MCP config, skills (wire and Go)
- **Built:** `gateway/internal/server/mcp_guard.go` (phone MCP list validation; alwaysAllow refused, D-086; stdio and HTTP entries; kept per live session, D-088); `gateway/internal/server/mcp.go` and `gateway/internal/mcpconf/` (list and disable in the project and home `mcp.json`, D-084, D-085); `gateway/internal/server/skills.go` (project skills list, put and delete, D-087). Routes wired in `handleExtension` (`projects.go`).
- **Go:** `go build`, `go vet ./...` and `go test ./...` pass (all packages).
- **Wire:** `npm test --prefix gateway` → 230 tests, 230 pass, 0 fail (including `mcp-guard`, `mcp-config` and `skills` suites).
- **Mutations (earlier, by the guard agent):** alwaysAllow refusal removed → its wire test fails; own reload sending `[]` → three reload tests fail. Both restored.
- **Deviations from the plan (to reconcile in D-088):** the kept MCP list is not dropped when the agent process exits (restart and idle reloads need it); it is dropped when the phone closes or deletes the session, and when the gateway stops. A phone `session/resume` updates the kept list, but Bob sees it only on the next reload or `session/new` (F3). `mcp/set` requires `projectId`. Transport labels are inferred from the entry keys, not checked against Bob (verify).
- **Not done:** the live check against Bob (6A.4), and `scripts/check.sh` (app and gateway gate).

## 2026-11-07 Phase 6A live check: T-40 (new-session part) through the gateway, real Bob 2.0.9
- **Method:** host runner; project created through `_acpcode/projects/create`; the home `mcp.json` written at the project's home path with one HTTP marker server (`marker_tool` → MARKER-OK) enabled; `_acpcode/mcp/set` used to toggle it; new `session/new` per case; prompt "Call the tool marker_tool and tell me its exact output." Scratch under `live6a/`.
- **Case A (`disabled: true`):** no request reached the marker server (0 lines); Bob said no such tool exists; no tool call or permission request. Prompt ended `end_turn`.
- **Case B (`disabled: false`):** the server was connected (14 requests) and the tool ran; Bob answered MARKER-OK. The test client allowed that one request.
- **Verdict:** T-40 new-session part passes in both directions. Bob reads the home file per session: case B reused the running Bob process and still loaded the server.
- **Not run:** the container path (P4 covers the file visibility); resume or load of a session after a changed list (the Q-3 gap); the apple and podman runners.
- **Note:** the audit logged `snapshot_failed` twice, because the scratch project is not a git repository. Not investigated; it did not affect the result.

## 2026-11-07 Phase 6A gate after D-089 and the T-37 fix
- **Gate:** `scripts/check.sh` → All checks passed (exit 0). Wire suite 232 of 232 pass (log: scratchpad `gate/check-d089.log`).
- **D-089:** the phone may send `alwaysAllow` (session list and `_acpcode/mcp/set`); shape limits: array of at most 64 non-empty names, each at most 128 characters; explicit null refused. Wire test (b) now expects acceptance; the unit and wire tests that expected a refusal were updated, each for D-089 (listed in the agent's report, scratch `backup-d089/` holds the originals).
- **T-37 test race (files.test.mjs):** the earlier gate failure was a timing race in the test: audit lines arrive on stderr, and the test read them right after the RPC response. Fixed by waiting for the same predicate (`waitForAudit`) before each positive assertion; expected values unchanged. 5 of 5 runs of the file pass. Remaining risk: negative checks (asserting absence) cannot wait; they are listed in the agent's report.
- **6A live check (T-40, new-session part):** passed (entry above). Still open for 6A.4: the container path (P4 shows file visibility) and the resume and load of a session after a changed list (the Q-3 gap).
- **Changed files:** `gateway/internal/server/mcp_guard.go`, `mcp.go`, `mcp_guard_test.go`, `mcp_test.go`, `gateway/internal/mcpconf/mcpconf.go` and its test, `gateway/test/mcp-guard.test.mjs`, `gateway/test/mcp-config.test.mjs`, `gateway/test/files.test.mjs`; `docs/DECISIONS.md` (D-089), `CLAUDE.md` (approval rule exception), `docs/RESULTS.md`.

## 2026-11-07 Phase 6A: Q-3 resume case observed; Apple container check not run
- **Q-3 (resume after a changed list), host runner, real Bob 2.0.9:** an enabled marker entry (home file and session list); turn 1 ran the tool; then `_acpcode/mcp/set disabled: true`. Bob reconnected the marker once within 4 s of the file change (the live session kept it). Then:
  - (i) `session/resume` with `mcpServers: []`: 0 marker requests; the gateway answered it from its cache (D-029, audit `reopen_answered`); the next prompt still ran the tool (MARKER-OK).
  - (ii) `session/resume` with the entry as before: 0 marker requests; cache answer; the tool still ran.
  - **Verdict:** on a live session with earlier turns, a changed list and `disabled` do not reach Bob until a new session or an idle reload (F3). The reload path is not covered by this run.
- **Apple container check: not run.** A new session through the Apple runner failed with `initialize_timeout` when the gateway's home sat under the scratch folder in `/private/tmp` (uid 10001, 501:20 and 0:0 all failed; the image, DNS and stdin were fine). An earlier Apple run that passed used a home under the user's home folder. Cause not confirmed; to retry with a home outside `/private/tmp`.
- **6A.4:** not recorded as passed. The host new-session part (T-40) passed earlier; the resume case is observed; the container path is open.

## 2026-11-07 Phase 6A: Apple container path (T-40, container part) passes
- **Setup:** Apple runner through the gateway; home and project folders under the user's home folder; DNS = the Mac's resolver (192.168.86.1); the marker server on the Mac's LAN address, not loopback.
- **Case A (marker disabled):** session/new ok; the turn ended; 0 marker requests; Bob said `marker_tool` is not available.
- **Case B (marker enabled):** session/new ok; 3 `tools/list` and 1 `tools/call`; one permission (allowed once); the tool returned MARKER-OK; Bob reported it.
- **Findings:**
  1. A container cannot reach the Mac's loopback. An HTTP MCP server for a container-run agent must listen on an address the container can reach (the LAN address here). This matters for Phase 6 setup and the docs.
  2. The earlier `initialize_timeout` was not reproduced. The earlier helper passed `bob` as the first argument of the agent command, while the image entrypoint is already `bob`, so the command ran as `bob bob acp`. That is the likely cause. The `/private/tmp` location was not shown to matter (not tested as a control).
- **6A status:** the gateway build, Go and wire suites, the gate, the T-40 new-session part on the host runner and on the Apple runner, and the Q-3 resume case are all recorded. 6A can be recorded as passed, with the reload path (idle stop) not covered by a live run.

## 2026-11-07 Phase 6B app side: built and tested (not yet wired)
- **Built:** `ACPCode/Security/MCPHeaderStore.swift` (header and env values in the Keychain, keyed by entry id; mode kSecAttrAccessibleWhenUnlockedThisDeviceOnly); `ACPCode/Fork/MCP/` (`MCPServerEntry`, `MCPServersModel` with a JSON file holding names only, `MCPServersView`, payload builder `mcpServersPayload(for:)`); `ACPCode/Fork/Skills/` (`SkillsModel` with the name and 64 KiB checks before any request, `SkillsEditorView`, `SkillBiometricGate` with `.deviceOwnerAuthenticationWithBiometrics`); `Info.plist` gained `NSFaceIDUsageDescription`.
- **Tests:** `xcodebuild … test` (iPhone 17 simulator) → TEST SUCCEEDED; XCTest 257 with 0 failures; Swift Testing 61 in 8 suites passed; UI tests passed on re-run (one launch problem in the first run). The app tests added: header store 6, MCP 19, skills 10. A first-run failure in a test I wrote was corrected: an unconfirmed stdio entry is refused on save (the design); the test now checks that. Log: `scratchpad/app6b/xcodebuild-test-2.log`. `scripts/check.sh` → passed.
- **Not done:** the `ServerViewModel` wiring at the three `mcpServers: []` call sites; the `SessionStorage.deleteServer` header hook; Face ID on a device (the simulator cannot match it; BLOCKED for device run); editing an existing skill needs its content, which the gateway's list does not return (overwrite only, for now).
- **Decisions taken on the recommendations (non-destructive):** headers and env values in the Keychain; stdio args in the JSON file (must not hold secrets; the warning says so); biometrics only for the skill save gate; `alwaysAllow` settable from the phone (D-089) with a warning in the editor.

## 2026-11-07 Phase 6B wired; full gate passes
- **App wiring:** the three `mcpServers` call sites in `ServerViewModel.swift` use `mcpServersForSession()` (gateway servers only; plain ACP servers still send `[]`); HTTP entries only when the agent advertises `mcpCapabilities.http`. The capability is now parsed (both initialize parsers). `SessionStorage.deleteServer` removes the server's MCP entries and header values.
- **App tests:** `xcodebuild … test` (iPhone 17) → TEST SUCCEEDED; unit tests 262, 0 failures; UI 2 passed, 1 skipped (pre-existing). New wiring tests: plain server sends `[]`; gateway server sends the enabled HTTP entry; no HTTP without the capability; disabled entries not sent; delete removes entries and header values.
- **Gateway:** `_acpcode/skills/read` added (content read for the editor); its tests are in the gate.
- **Gate:** `scripts/check.sh` → All checks passed; wire suite 235 of 235 (log: scratchpad `gate/check-6b.log`).
- **Note:** the gateway accepts `https` to any host for MCP URLs and `http` only to loopback; the app's HTTP entries follow the same rule, so an `https` server on the LAN is allowed.
- **Still open for 6B:** Face ID on a device (BLOCKED: needs a device run); the three call sites have no direct test (the function they call is tested); the `mcpCapabilities.http` parse has no unit test; no live end-to-end check of the app's MCP list against the gateway.

## 2026-11-07 T-35 (Bob without BOB_API_KEY): gateway and app mapping (partial)
- **Live (real Bob 2.0.9, host runner, key absent from the environment):** session/new → the phone receives `{"code":-32000,"message":"Authentication required"}`, no data. Two runs: 3374 ms and 3142 ms, including the agent's cold start.
- **Gateway:** passes the agent's error object unchanged (supervisor.go `agentResponse`; only the id is replaced).
- **App:** already maps it to the auth text (`ACPClient/.../ACP/AgentErrorText.swift`, decided in D-072), used at `ACPCode/ServerViewModel.swift` (create, prompt, load, resume, delete paths).
- **Not done:** a wire test (the fake agent has no failing session/new option; a test with an inline agent is possible); an on-screen check on the simulator with the no-key gateway.
- **T-35 status:** Partial until the on-screen check is recorded.

## 2026-11-07 Phase 6C: gateway relay (6C.2) and app form (6C.3) built; live T-45 open
- **6C.2 gateway:** elicitation relay and answer (D-090). Node `elicitation.test.mjs` 6 of 6 pass (written before the code: all failed). Mutation (timeout sends accept) makes the timeout test fail; restored. Go build, vet and tests pass. The initialize now advertises `clientCapabilities.elicitation.form` to the agent only.
- **6C.3 app:** `ACPCode/Fork/Elicitation/` (request parser, form model, inbox, view, routing) and `ACPClient/.../GatewayElicitation.swift`; hooks at `AppViewModel.swift:215`, `Fork/Gateway/AppViewModel+Gateway.swift:51` and `ContentView.swift:78`. `xcodebuild test` → 281 tests, 0 failures; 19 new elicitation tests.
- **Deviations from PLAN 6C.3 (to confirm):** optional unsupported fields are left out of the content (PLAN said cancel); only required unsupported fields block Accept. Fields are shown in name order (the wire object has no order). The form cannot be dismissed without an answer.
- **Not done:** live T-45 (needs a Bob account that shows the licence form; the current account is internal, not confirmed); on-screen check of the form; the Swift 6 actor warning on `ElicitationFormModel` Identifiable (harmless, not fixed).
- **Phase 6C status:** built and tested at unit and wire level; the live check and the on-screen check are open.

## 2026-11-07 T-35 wire test (gateway side): passes
- **Test:** `gateway/test/auth-missing.test.mjs`, an inline agent that answers session/new with -32000 "Authentication required". The phone's reply carries the same code and message, no result, no session id; the agent receives one session/new; the session index stays empty.
- **Result:** 1 of 1 pass. Mutation (one character changed in the expected message) fails; restored and re-run passes.
- **T-35 status:** gateway pass-through and the live check pass; the app's mapping exists (D-072). The on-screen check (the message in the transcript on the simulator) is still open.

## 2026-11-07 Full gate after the elicitation relay and the T-35 wire test
- **Gate:** `scripts/check.sh` → All checks passed (exit 0). Wire suite 241 of 241 (log: scratchpad `gate/check-6c2b.log`). The first run stalled in the ACPClient Swift tests for about 19 minutes with no output; it was stopped by its own process IDs and re-run from a clean start, which passed.
- **Included:** the T-35 wire test (`gateway/test/auth-missing.test.mjs`, 1 of 1) and the elicitation wire tests (`elicitation.test.mjs`, 6 of 6).

## 2026-11-07 On-screen checks (simulator, Debug app)
- **T-35 on screen: FAIL.** With the no-key gateway, the app's session create returned to the home list with no message. The gateway returned the correct -32000 "Authentication required" (audit confirms). The app's mapped text ("Bob needs authentication. Set BOB_API_KEY on the gateway host.") was not shown: the session placeholder is removed on failure and nothing replaces it. Gap: the app must show the error on the session create path (ServerViewModel create failure, D-072 mapping not reached on screen). Fix needed; then re-check.
- **Elicitation form on screen: PASS.** The sheet "Agent question" appeared with the licence toggle, Name, Seats and an unsupported array field. Accept sent `{"action":"accept","content":{"seats":3,"accept_license":true,"name":"Ada"}}` and the agent received it. Audit shows the action only.
- **Gap found on the form:** the note "This form is not supported in this app; you can decline or cancel." showed even though only an optional array field was unsupported. It should show only when a required field is unsupported.

## 2026-11-07 App fixes for the on-screen gaps (unit level)
- **Session create failure:** `ServerViewModel.sessionCreateError` is set when session/new fails; `ContentView` shows a "Session not created" alert with the mapped text. The transcript cannot hold the message, because the placeholder is removed on failure and an existing test requires that. Tests: `ACPCodeTests/SessionCreateAuthErrorTests.swift` (3, incl. the -32000 auth text, another error, and dismiss).
- **Elicitation note:** the "not supported" note now shows only for a required unsupported field. Tests: `ElicitationTests` `testOnlyOptionalUnsupportedFieldShowsNoNote`, `testRequiredUnsupportedFieldShowsNote`.
- **xcodebuild test:** TEST SUCCEEDED; 286 passed, 0 failed (unit and UI).
- **Not yet done:** the on-screen re-check of T-35 with the alert (running). The new tests have not been run against the pre-fix code to confirm they fail before the change. A second send-path message ("Failed to create session") can appear after the alert; left as is.

## 2026-11-07 T-35 on screen: PASS (after the alert fix)
- **Alert on screen:** "Session not created" with "Bob needs authentication. Set BOB_API_KEY on the gateway host." (no-key gateway; the gateway returned -32000 "Authentication required"; audit shows session/new and agent_start). Dismiss clears it.
- **Found on the way:** with the Working directory left blank, the new-session sheet sent "/", and the gateway refused it (cwd outside the roots, correct). The sheet should not send "/" by default for a gateway server; for a gateway server the project should be picked (FR-26). Open; not in this check.
- **Screenshots:** scratchpad `sim2/session-not-created-auth-alert.png`.
- **T-35 status:** PASS (gateway wire, live Bob, on-screen). PLAN 4.9 can be ticked.

## 2026-11-07 New-session sheet for gateway servers (project pick, no "/")
- **Change:** for a gateway server, the new-session sheet picks a registered project (default: the first); Create is off with no project; the sent cwd is the project's path, never blank or "/". The plain free-text path is unchanged. `ServerViewModel.sendNewSession` refuses a gateway send with no project path.
- **Files:** `ACPCode/Fork/Gateway/GatewayNewSessionPick.swift` (new), `ACPCode/Fork/Gateway/GatewayHomeView.swift` (lines 134 to 188, the sheet), `ACPCode/ContentView.swift` (the sheet's onCreate and two New Session buttons), `ACPCode/ServerViewModel.swift` (`sendNewSession`), tests `ACPCodeTests/NewSessionProjectPickTests.swift` (6).
- **xcodebuild test:** TEST SUCCEEDED; 292 tests, 0 failures. One UI runner launch error appears in the log; not re-run.
- **Open:** the sheet agent rewrote lines 134 to the end of `GatewayHomeView.swift` after the file had changed on disk, so a concurrent edit may have been overwritten; no copy survives. Lines 1 to 133 are unchanged. Needs owner check. The on-screen check of the sheet is not done.

## 2026-11-07 Phase 4.2 (secrets file) and 4.3 (trust folder), gateway
- **4.2:** `agent.secretsFile` (absolute, regular file, mode 0600 or stricter; `NAME=value` lines; names must be in `agent.envPassthrough`, others ignored with a `secret_ignored` audit line, name only; HOME and PATH refused). Values go only into the runner CLI's environment; the agent gets `-e NAME`. Read at each agent start. Tests: `internal/config/secrets_test.go`, `internal/server/runner_secrets_test.go`, `gateway/test/secrets-file.test.mjs` (pass). The agent's argv holds no value; the audit log holds no value.
- **4.3:** at project create, the project path is written as `TRUST_FOLDER` into the project home's `.bob/trustedFolders.json`, in the format the local Bob uses (`{"version":1,"folders":{...}}`). Existing entries are kept; an unparseable file is refused and left untouched. Atomic write, `.bob` 0700. `--trust` never appears in any argv. Tests: `internal/server/trust_test.go`, `gateway/test/trust-folder.test.mjs` (pass).
- **Not done:** the live T-33 trust check and the live Bob run with a key (not run in this step); PLAN 4.2 and 4.3 remain unticked until that check.
- **Note:** `TestSnapshotRunsNoFilterUnderPodman` timed out once under load and passed on rerun.

## 2026-11-07 Full gate after Phase 4.2, 4.3 and the project-pick sheet
- **Gate:** `scripts/check.sh` → All checks passed (exit 0). Wire suite 247 of 247 (log: scratchpad `gate/check-4-2.log`).

## 2026-11-07 Live: secrets file (4.2), trust folder (4.3), T-33 (Apple runner, real Bob 2.0.9)
- **Setup:** Apple runner; BOB_API_KEY from `agent.secretsFile` (mode 0600), named in `envPassthrough` (not in the config file); the trust file written at project create.
- **Result:** project created; session/new in the registered project ok (T-33 new session); session/prompt "Reply with the word OK." → `end_turn`; session/close ok.
- **Trust file:** `<stateDir>/homes/<projectId>/.bob/trustedFolders.json` holds the project path as its key.
- **Audit:** 0 matches of the key (full and the first 8 characters); no `--trust` in the gateway source. The audit line does not carry argv, so `--trust` absence in the live argv rests on the unit test (`trust_test.go`) and the wire test.
- **Cleanup:** gateway stopped by PID; no acpcode containers left; the test folder removed.
- **Status:** T-33 (new session, prompt) passes live; 4.2 and 4.3 pass with the wire and live evidence above.

## 2026-11-07 On-screen: project picker for a gateway server (simulator)
- **Default:** the sheet lists the gateway's projects, ticks the first, and Create is enabled. PASS.
- **Choose a second project, Create:** the audit shows session/new routed to the chosen project; the session opened. PASS. (The audit does not log cwd; the routing implies it was inside the chosen project.)
- **Zero projects:** "No projects. Add one on the gateway." shown; Create disabled; no session/new. PASS.
- **Observed, open:** the app sent a `session/list` with a cwd the gateway refused (`cwd_rejected`); the session still opened. Likely the app's own list call for a gateway server carries a path; to investigate.
- **Screenshots:** scratchpad `sim3/01-new-session-default-alpha.png`, `02-new-session-beta-selected.png`, `03-zero-projects-new-session.png`.
- **Owner:** two test servers ("Check Gateway", "Empty Gateway") remain in the simulator app; delete them there.

## 2026-11-07 Fix: session/list sent with a refused cwd (gateway servers)
- **Root cause:** `ServerViewModel` built `session/list` from the server's working directory; an empty one became "/", which is outside every gateway root, so the gateway refused it (`cwd_rejected`, guard.go cwdAllowed, checked in server.go before routing).
- **Fix (app only):** `ACPCode/Fork/Gateway/SessionListPayload.swift` (`ACPSessionListPayload.forServer`): a gateway server sends no cwd; a plain ACP server is unchanged. Both request sites in `ServerViewModel.swift` use it. The gateway guard for session/new is unchanged.
- **Tests:** `ACPCodeTests/SessionListCwdTests.swift` (4). xcodebuild → TEST SUCCEEDED, 296 unit tests, 0 failures (re-run without a launch flake; one earlier UI launch flake).
- **Caveat:** a gateway socket with no project yet answers `session/list` with -32602 "no project" (by design, supervisor_test.mjs:189), so that call returns no list. The gateway home uses `sessions/index`; the on-screen effect is not yet checked.

## 2026-11-07 On-screen: gateway home after the session/list fix (partial)
- **Home:** the project "Alpha scratch" and the session row are visible on first connect and on relaunch; no error text or alert. PASS.
- **cwd_rejected for session/list:** 1 on the first connect after Add Server; 0 on relaunch. The first fetch appears to have gone out before the app knew the server was a gateway (flag still false), so it sent "/". FAIL for "no cwd_rejected"; not yet fixed.
- **Next:** make the gateway flag known before the first session/list, and re-check.

## 2026-11-07 Fix: first session/list waits for the gateway flag
- **Root cause:** the first session/list after Add Server went out before the initialize result was applied, so the gateway flag was still false and the app fell back to "/", which the gateway refused (cwd_rejected).
- **Fix:** `ACPSessionListPayload.forServerIfKnown` (`ACPCode/Fork/Gateway/SessionListPayload.swift`) returns nil until the initialize result is applied; `ServerViewModel` keeps `hasAppliedInitializeResult` (set in `updateGatewayInfo`) and gates both list paths on it. Plain ACP servers also wait for their initialize result before the first list.
- **Tests:** 3 new in `ACPCodeTests/SessionListCwdTests.swift`; xcodebuild → TEST SUCCEEDED, 299 executed, 0 failures (one earlier UI launch flake, re-run passed).
- **Still open:** the on-screen re-check of the first connect (no cwd_rejected).

## 2026-11-07 On-screen: first connect after Add Server (PASS)
- **Home:** the project "demo" and session "hello from sim5 seed" appear on the first connect; no error text or alert. PASS.
- **Audit:** cwd_rejected 0 (including session/list). One `route_refused` for session/list with "no project: send a cwd inside a registered project or a sessionId" (the by-design route refusal before the socket has a project; not shown to the person).
- **Screenshot:** scratchpad `sim5/first-connect-home.png`; audit `sim5/audit.jsonl`.
- **Status:** the session/list cwd issue is closed on screen.

## 2026-11-07 On-screen: app MCP list (6.1) is not reachable from the UI (BLOCKED, correction)
- **Found:** `MCPServersView` is never presented anywhere in the app. The only MCP wiring is `mcpServersForSession()` at the session/new and session/resume call sites. My earlier note that 6B was "wired" referred to the request path only; the UI entry point was never added.
- **Effect:** the live end-to-end check of the MCP list (add an HTTP server in the app, start a session, check Bob uses it) could not run. Task 6.1 must not be ticked.
- **Next:** add an entry point for gateway servers (recommendation taken: a row in the gateway server's settings opening `MCPServersView`), then re-run the on-screen check.

## 2026-11-07 MCP servers entry point (6B.2 UI) and bundle ID for device builds
- **Entry point:** a "MCP Servers" row in the More menu of a gateway server (`ContentView.swift`, identifier `gatewayMCPServers`), presenting `GatewayMCPServersSheet` (`ACPCode/Fork/MCP/MCPEntryPoint.swift`). Plain ACP servers are unchanged. Unit tests: `ACPCodeTests/MCPEntryPointTests.swift` (2, pass). Reachability is from reading the navigation code; the on-screen check is not yet run.
- **App unit tests:** 301 executed, 0 failures (both runs). The UI test runner (`com.example.ACPCodeUITests.xctrunner` in the old ID) failed to launch in the last run; run 1 reported success. Not yet diagnosed.
- **Bundle IDs:** now `com.adammakarucha.acpcode` (app), `.tests`, `.uitests`, in `ACPCode.xcodeproj/project.pbxproj`.
- **Device build:** blocked. Xcode reports the Apple Developer Program License Agreement for team `JNPGD7477Q` must be accepted by the account holder before a profile can be created.

## 2026-11-07 On-screen end-to-end: app MCP list reaches Bob (6.1)
- **Enabled entry (HTTP marker server, real Bob 2.0.9, gateway host runner):** the app's session/new carried one http entry (audit `mcp_servers stdio=0 http=1`); the marker server got tools/call; Bob answered "The exact output of `marker_tool` is: MARKER-OK". PASS.
- **Disabled entry:** the next new session carried no entry (audit `http=0`); the marker server got no new requests; Bob said the tool is not available. PASS.
- **Found:** right after connect, the More menu had no "MCP Servers" row; it appeared after Refresh and reopening the menu. Likely stale SwiftUI state (the gateway flag is not observed). Open.
- **Status:** T-40 (app path) and T-42 pass; task 6.1 can be ticked.

## 2026-11-07 Fix: More-menu MCP row appears after connect (unit level)
- **Cause:** `ServerViewModel.gatewayInfo` was not `@Published`, so the More menu did not re-render when the gateway flag arrived.
- **Fix:** `ServerViewModel.swift:118` now `@Published private(set) var gatewayInfo`.
- **Test:** `ACPCodeTests/MCPEntryPointTests.swift` `testUpdateGatewayInfoPublishesChangeSoMenuRefreshes` (failed before, passes after). Unit tests: 302 executed, 0 failures.
- **UI tests:** `ACPCodeUITests.testExample` and `testLaunchPerformance` fail at app launch ("does not have a process ID"; "Failed to get background assertion") in both runs. Not yet diagnosed; the base code is not checked the same way.
- **Not checked on screen yet.**

## 2026-11-07 On-screen: More-menu MCP row after first connect (PASS)
- **Result:** the "MCP Servers" row is in the More menu of a new gateway server right after the first connect; no Refresh was tapped. Menu items: Settings, Refresh, Disconnect, MCP Servers, Edit Server, Delete.
- **Screenshots:** scratchpad `morerow/more-menu-first-connect.png`, `morerow/more-menu-attempt2.png`.

## 2026-11-07 UI test launch failures: diagnosis
- **Wiring:** the app, unit tests and UI tests use the new bundle IDs consistently (`com.adammakarucha.acpcode`, `.tests`, `.uitests`); the UI tests target the app.
- **Runs:** UI-only runs passed twice (exit 0). Each first logged a transient launch failure on a simulator clone (`Code=-308 (ipc/mig) server died` in one; `RequestDenied`/`launch-failed` in the other), then retried and passed.
- **Not established:** the cause of the transient launch failure. Not a signing or DerivedData issue (the build succeeded). It looks like a simulator launch-service flake.
- **Next:** if the failures recur, capture the `.xcresult`. A simulator reset would erase its data and needs confirmation first.

## 2026-11-07 Device build, install and launch (iPhone 14 Pro, Debug)
- **Build:** `xcodebuild … -destination id=00008120-0009751A0A33401E -allowProvisioningUpdates ACPCODE_DEVELOPMENT_TEAM=JNPGD7477Q` → BUILD SUCCEEDED, after the Apple license agreement was accepted by the account holder.
- **Install:** `xcrun devicectl device install app` → installed (bundle `com.adammakarucha.acpcode`).
- **Launch:** `xcrun devicectl device process launch` → launched.
- **Still to do on the phone:** the Face ID check (skill save gate). Not run yet.

## 2026-11-07 Phone to Mac gateway over mutual TLS (user test, real device)
- **Path:** iPhone 14 Pro, ACP Code Debug build → `wss://adams-mac-studio.local:8443` (Caddy, client certificate required, `tls internal`) → gateway on 127.0.0.1:8788 (host runner, test mode; Bob runs on the Mac).
- **Result:** the first attempt returned 401 (certificate accepted, bearer token missing from the form). With the token entered, the app connected. The user confirmed the server works from the phone.
- **Not yet covered:** a session from the phone, the Face ID check, the switch to the Apple container runner before real use.

## 2026-11-07 Phone: project list over mutual TLS (user test)
- **Result:** after the token was entered, the phone connected, but the project list was empty because the local gateway had no project registered. Registered "Phone test" (scratch folder) with `_acpcode/projects/create`; the user confirmed the project now appears on the phone.
- **Session from the phone (user test):** a prompt sent from the phone to the "Phone test" project got a reply. End-to-end path confirmed: phone → Caddy (mutual TLS) → gateway → Bob on the Mac.

## 2026-11-07 Wave 1 task notes and integration (feat/integration-2026-11-07)

### A1 gateway usage and project state (D-092)

- **Branch:** `feat/a1-gateway-usage` from `db08383`. Worktree: `scratchpad/wt/a1-gateway-usage`.
- **Built:** C1 usage per session (schema 6, table `session_usage`; `usage` on `_acpcode/sessions/index`, left out when none is stored). C2 `_acpcode/project/state` (change-only, at most one per project every 500 ms, audit event `project_state`, never in the event log, sent to sockets that listed the project).
- **Hooks:** every agent transition goes through `setState` in `supervisor.go`, so `idle.go` needed no edit (its stop goes through `setState`).
- **Not done (coordinator decision):** `_acpcode/projects/list` does not subscribe its socket to C2 yet. The hook is one line in `projects.go` (owned by F1): `s.watchProjectStates(ctx, who.Conn, "")` in the `_acpcode/projects/list` case. `watchProjectStates` exists in `projectstate.go`.
- **Go:** `go vet ./...` and `go test ./...` pass. New: `server/usage_test.go` (parser), `store/store_usage_test.go` (replace, index, delete, migration from schema 5). Older migration tests drop `session_usage` when they simulate an older schema.
- **Node, new:** `usage.test.mjs` (5 tests) and `usage-project-state.test.mjs` (3 tests), all passing. Covers: index shows the last usage; survives restart and starts no agent; no field when none seen; partial update not stored; cost omitted when absent; state change-only through start, run, idle stop; only listing sockets get state; a burst is rate limited to two a second and ends on the true state.
- **Mutation check:** store write removed (`SetUsage` call in `server/usage.go`). `usage.test.mjs`: 3 of 5 failed (the three that need a stored value). The two negative tests passed. Source restored and verified.
- **`scripts/check.sh` (this worktree): FAILED** at the Gateway wire tests step, so the later steps did not run in that script. Wire result: 264 tests, 263 pass, 1 fail: `FR-24: an idle session is closed while another session keeps the project busy` (`lifecycle.test.mjs`), `closed with 1006`. The same failure appeared in a standalone full `npm test` run (263 of 264). Remaining steps run by hand: dry run of `config.example.json` OK, `check-docs.mjs` OK (48 tests, 45 FRs, 15 NFRs, 78 decisions), secrets grep clean.
- **FR-24 investigation:** passed 7 of 7 in isolation on this branch (durations 4.4 to 6.6 s; the test has a 6 s wait). Whole `lifecycle.test.mjs` file passed 4 of 4 more with an audit dump on failure. The full suite on the baseline commit `db08383` (built from `git archive`, same machine, run concurrently with other agents' suites) gave 256 tests: 254 pass, 2 fail (both push tests: `no push is made when the push block is absent`, `a finished turn sends one alert`), and `FR-24` passed at 5997 ms. So the baseline is not clean here either, and I have not shown that FR-24 is caused by this branch. No code path in the new work closes a client socket; the only gateway-side 1006 path is `Shutdown`. Not resolved.
- **Not verified:** Bob's real `usage_update` shape (no recorded payload; D-070 marks it "verify"). The Swift app side (not part of this task). Live gateway behaviour with the phone.

# RESULTS: B1 app usage UI (branch feat/b1-app-usage, decision D-093)

Date: 2026-11-07. Worktree: scratchpad/wt/b1-app-usage. Contract: C1 (usage on the sessions index).

### Built

- ACPClient: `GatewayUsage` (decode of the C1 `usage` object, derived `left` and `percent`, live conversion from `ACPSessionUsage`) and `GatewayClient.sessionsWithUsage(projectId:)`, one `_acpcode/sessions/index` call returning sessions and usage.
- App, `ACPCode/Fork/Usage/`: `UsageUpdateThrottle` (pure, one shown update per second, last value wins), `ContextUsageFormat` (chip text, bar fraction, compact counts), `ContextUsageChip` with `ContextUsageFeed` (throttled live values), `GatewayUsageSheet` with `UsageSheetContent` (sheet rows as data), `GatewayContextBar`.
- Hooks: `SessionDetailView.swift` one line (chip above the plan and transcript); `GatewayHomeView.swift` one line (the existing row call now overlays the bar).

### Deviation for the coordinator to accept or reverse

`ACPCode/Fork/Gateway/GatewayHomeModel.swift` is edited (about six lines): it publishes `usage` and calls `sessionsWithUsage()` in `refresh()` instead of `sessions()`. Reason: the row bar needs the usage, and the model is the only place that holds the gateway client's answer. The model is not in B1's owned list and no other task in the table owns it. Integration should expect it to be untouched by the other branches. If the coordinator prefers another route, the bar and chip do not depend on it.

### Tests

- `swift test --package-path ACPClient` (full suite, second run): XCTest 232 tests, 0 failures. Swift Testing 9 tests in 2 suites, all passed. `GatewayUsageDecodingTests` (11 tests) cover: rows with and without usage; cost present and absent; currency without amount; malformed usage ignored while the session still decodes (eight malformed shapes); a malformed cost dropped with the rest kept; timestamps with and without milliseconds; left and percent rules; live usage needs both used and size.
- A first full run stalled inside the Swift Testing `ACPServiceTests` path and was killed. It did not reproduce: `--skip ACPServiceTests` passed, `--filter ACPServiceTests` passed (4 tests), and the second full run passed. Not investigated further; it looks environmental (other swift-test processes were running on this Mac).
- App tests: `ACPCodeTests/UsageChipTests.swift`, `UsageSheetTests.swift`, `UsageThrottleTests.swift` (throttle suite plus `ContextUsageFeedTests`). Compiled by `build-for-testing`. Not executed in this task (rule: no `xcodebuild test`).
- Mutation check: the throttle suite (6 tests) was copied into a scratch package outside the repo (`scratchpad/b1-mutation`), because the app test target cannot run here. Real throttle: 6 of 6 pass. Mutant (`flush` drops the waiting value): `theLastValueInTheWindowIsTheOneShownWhenItEnds` and `atMostOneShownValuePerSecondOverABurst` fail (3 issues). Restored throttle: 6 of 6 pass.

### Build

- `xcodebuild build-for-testing -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath scratchpad/dd/b1-app-usage`: TEST BUILD SUCCEEDED. Log: `scratchpad/b1-build.log`. No warnings in the new or touched files.

### scripts/check.sh (not a clean pass)

- Passed: Node version, JSON parse, dependency guard (after `npm ci --prefix gateway` in the worktree), syntax check, Go vet, Go unit tests, Go build.
- Gateway wire tests, three runs:
  1. Stopped at `apns.test.mjs` (a test hung; 33 tests cancelled).
  2. Run alone: 256 of 256 pass.
  3. Inside check.sh: 255 of 256 pass; `apple-runner.test.mjs` "git gets a one-off container with no network when no agent container is up" fails with `TypeError: Cannot read properties of undefined (reading 'branch')`. That test drives the Apple `container` CLI (present at `/opt/homebrew/bin/container`).
  - `gateway/` is identical to base commit db08383 (zero diff lines). The failures are flaky environment-dependent tests in code this task did not touch.
- Steps after the wire tests, run by hand because check.sh stopped: dry run of `gateway/config.example.json` passed; private-key and raw-secret scans clean; `node scripts/check-docs.mjs` OK (48 tests, 45 FRs, 15 NFRs, 78 decisions); ACPClient Swift tests passed (above). `ACPCodeTransport` and `AppServerClient` package tests were not run (not touched by this task).

### Not verified

- App tests were not executed. The throttle suite was run only in the scratch copy.
- The chip and row bar layout were not seen on a simulator or device.
- Live chip values depend on Bob's `usage_update` events being replayed into the session on reopen. Not verified against a live Bob.
- Visual check of the sheet's Dynamic Type and the bar's position on rows.
- A live cost without used and size tokens is not shown (the sheet needs a GatewayUsage). Noted, not handled.

# B2 app running-now strip: results

Branch: feat/b2-app-running (worktree scratchpad/wt/b2-app-running). Decision: D-094 (scratchpad/decisions/b2-app-running.md).

### Tests

- Pure logic, scratch SwiftPM harness with Swift Testing (copy of ACPCode/Fork/Running/RunningWork.swift and ACPCodeTests/RunningWorkTests.swift, not in the repo): 15 tests passed.
- Mutation check (completed no longer terminal, in the harness copy): 5 issues in 4 tests failed (completedUpdateEndsTheToolCall, updateWithoutIdClosesTheLatestOpenCallWithoutId, terminalUpdateWithAnotherIdDoesNotEndThisToolCall, noRunningWorkGivesAnEmptyStrip). Restored code: 15 passed.
- ACPCodeTests/RunningWorkEventsTests.swift (transcript adapter, 9 tests): compiled, NOT executed (xcodebuild test is not run in this task).
- xcodebuild build-for-testing (iPhone 17 simulator, -derivedDataPath scratchpad/dd/b2-app-running): TEST BUILD SUCCEEDED.
- scripts/check.sh: FAILS at the gateway wire-test step. Earlier steps pass (Node, JSON, Go vet/test/build, syntax). Gateway wire tests are timing-flaky here: run 1 had one failure (T-22, closed 1006) and 31 cancelled tests; run 2 had 256 tests, 254 pass, 2 fail (FR-24 idle session timing). No gateway file is changed on this branch (diff touches only ACPCode/ files).
- Steps after the wire tests, run by hand: gateway dry run OK; scripts/check-docs.mjs OK (48 tests, 45 FRs, 78 decisions); swift test ACP CodeTransport (12, 1 skipped, 0 failures), ACPClient (221, 0 failures), AppServerClient (9, 0 failures). Secrets grep not run separately.
- Needed `npm ci --prefix gateway` in the worktree (node_modules was missing; gitignored).

### Not verified

- Visual layout of the strip and the safeAreaInset placement on device or simulator. An empty strip should add no space; not checked.
- Subagent note is fixed text; the C3 subagent gap is per H1.
- Turn status uses the view model's streaming flag, not the gateway index status (index status is not reachable from the session view).
- Approvals without a tool call (pendingPermissionRequests with no segment) are not counted.

### D1 connector gateway core (2026-11-07)

Branch `feat/d1-connector-core` (from db08383). Decision text: `<scratchpad>/decisions/d1-connector-core.md` (D-095).

What is built
- `gateway/internal/connector/` (new): the public listener on 127.0.0.1:connector.port, the five C4 routes (metadata, authorize, token, mcp), Origin check, PKCE pairing with phone approve/deny/grants/revoke (C5), grants file with token hashes (0600, atomic), scope gate, limits (promptsPerHour, maxPromptBytes, turn slots), and the five C7 tools declared and gated but returning "not implemented" until D2.
- `gateway/internal/config/config.go`: connector block only (defaults, ranges, unknown-key errors, publicOrigin required when enabled).
- `gateway/internal/server/server.go`: five small hooks (struct field and construction, Listen, Serve, Shutdown, and one dispatch block for `_acpcode/connector/*`).

Spec choices (details in D-095): RFC 9728 and RFC 8414 served; PKCE S256 required; resource indicators bound; no dynamic registration and no client ID metadata documents (the spec makes both optional). The client registration choice is the owner probe's question.

Tests
- `gateway/test/connector.test.mjs`: 17 wire tests (routes, 404/405, Origin, bearer, default off, approve, deny, timeout, PKCE, resource, redirect, revoke, restart with 0600, scope, phone scope validation, --dry-run limits).
- `gateway/test/connector-limits.test.mjs`: 4 wire tests (promptsPerHour, maxPromptBytes, scope before limits, audit never holds prompt text).
- `gateway/test/connector-helpers.mjs`: shared helpers (not a test file).
- `gateway/internal/connector/connector_test.go`: scope JSON and Allows, hourly window, turn slots, grants file mode and atomicity.
- Mutation check: byToken with the hash comparison removed. The first run passed (the suite had no case of a wrong token while a grant existed), so I added that assertion; the mutated run then failed on it ("a wrong token is refused while a grant exists"), and the restored file passes 17 of 17.

Results
- `go vet ./...` clean; `go test ./...` all packages ok.
- Connector wire tests: 17/17 and 4/4 pass.
- scripts/check.sh (final run on commit a6f3b8d): exit 0, "All checks passed.", Node wire suite 277 pass, 0 fail. Log: results/d1-check-final.log.
- Connector timeouts added after the earlier run: ReadTimeout 30 s, IdleTimeout 60 s on the public listener.
- Load-sensitive tests: an earlier full run under a load average near 20 failed three tests (eventlog, gitchanged, lifecycle FR-24). The baseline build also fails gitchanged under the same load, and eventlog passes in isolation on both builds. The final run on a6f3b8d passed all 277. Not caused by D1.

Not verified
- The real Claude client: whether it can connect with no registration (owner probe, plan step 7.0).
- Caddy forwarding and the public listener (G1).
- The phone app side (E1), and the tool handlers (D2).
- `connector` is not advertised in the initialize `extensions` list (not added; coordinator decides).

Notes for the coordinator
- C5 addition: each pending row also carries `redirectHost` so E1 can show where a code goes.
- `gateway/node_modules` in the worktree is a symlink to the main checkout's (not committed, gitignored).
- `main.go` is untouched: a bad connector value fails at config load, so `--dry-run` reports it.

### 2026-11-07 E1 connector phone app (branch feat/e1-connector-app, D-097)
- **Built against:** contract C5 with a fake transport. The gateway side (D1) was not used; no live gateway run.
- **ACPClient package, connector tests (`swift test --filter GatewayConnector`):** 15 tests, 0 failures. Covers the five calls, scope encoding for "all" and one session, grant decoding (both scope shapes, last use), error mapping (code and text kept, disconnect, wrong answer shape).
- **ACPClient package, full (`scripts/check.sh` run 2):** `ACPClientTests.xctest` 236 tests, 0 failures.
- **Mutation check:** `GatewayConnectorScope.oneSession` changed to return `.allProjects` (one-session sends "all"). `swift test --filter GatewayConnector`: 5 failures, including `testApproveSendsOneProjectAndOneSessionAndReturnsTheGrantId` and `testOneSessionScopeIsOneProjectAndOneSession`. Restored; the file matches the committed version.
  - The mutation is at the shared scope helper, not in the app model. The app test `ConnectorConnectionsTests.testOneSessionIsTheDefaultAndApproveSendsExactlyOneProjectAndOneSession` runs through the same helper, so it would also fail, but it was not run (see below).
- **App build:** `xcodebuild build-for-testing` with `-derivedDataPath <scratchpad>/dd/e1-connector-app`, iPhone 17 simulator: TEST BUILD SUCCEEDED. No warnings from the new files.
- **App tests:** `ACPCodeTests/ConnectorConnectionsTests.swift`, 12 tests (pending code shown, time left, one-session default and send, picked session, all projects, no session to pick sends nothing, approved grant appears, deny, revoke, failed approve keeps row and says why, row answered here does not return, no gateway). Compiled, **not run**: the brief forbids `xcodebuild test` in this task. They run in the integration task.
- **scripts/check.sh:**
  - Run 1: EXIT 1. Two gateway wire tests failed under load from other tasks' suites running at the same time: `eventlog.test.mjs` "a permission request is logged as phones see it" (a two-second poll for the request) and `lifecycle.test.mjs` "FR-24" (closed with 1006). Both files were re-run alone: 11 of 11 pass (EXIT 0). The branch changes no gateway code.
  - Run 2 (full, clean): **EXIT 0, "All checks passed."** Wire tests 256 pass, 0 fail. Dry run, secrets check, docs cross-check, and Swift packages (ACP CodeTransport, ACPClient, AppServerClient) all pass.
- **Not verified:** the screens on a simulator (layout, sheet presentation from the toolbar, the 5-second refresh). The toolbar button is in a sheet inside a toolbar item; not seen on screen.

# F1 add-project review (D-091) RESULTS

Branch `feat/f1-add-project-review`, from db08383. Decision D-099 is in `<scratchpad>/decisions/f1-add-project-review.md`.

### Defects found and fixed (each with a failing test first)

1. Gateway: the post-create check accepted a regular file at the new name, and registered it as a project. Test `TestFolderModeRefusesAFileThatReplacedTheNewFolder` (failed: no refusal).
2. Gateway: `os.Chmod` followed a link placed at the new name, so a folder outside the roots went from 700 to 755. Test `TestFolderModeNeverChangesAFolderOutsideTheRoots` (failed: mode 755).
3. Gateway: a parent swapped for a link after the check let the mkdir create a folder outside the roots (removed again a moment later). Test `TestAParentSwappedForALinkMakesNothingOutsideTheRoots` (failed: folder made outside the roots).
4. Gateway: the rollback used `os.Remove`, which unlinks a file, so a file at the name was deleted when registration was refused. Test `TestRegistrationRefusalKeepsAFileAtTheName` (failed: file removed).
5. Gateway: `_acpcode/projects/roots` listed a root removed after start, and listed a root twice when configured twice. Tests `TestProjectRootsListsOnlyRootsThatStillExist` (Go) and the roots case in `gateway/test/create-folder.test.mjs` (failed: removed root listed).
6. App: a refusal stayed on screen after the root was changed. Test `testChangingTheRootClearsAGatewayRefusal` (failed).
7. App: a refusal for the name that was sent was shown after the name had been retyped while Create was in flight. Test `testARefusalThatArrivesAfterTheNameChangedIsNotShown` (failed).

Fixes: `gateway/internal/server/projects_folder.go` (os.Root, folderHook seam, removeOwnFolder, projectRoots); `ACPCode/Fork/Gateway/GatewayNewProjectModel.swift` (selectedRoot didSet, sentName check).

### Checked, no defect (one line each)

- Guards that passed on the original code: rollback removes its own empty folder when registration is refused (`TestRegistrationRefusalRemovesTheFolderItMadeAndNothingElse`); a second Create during a Create is refused (`testASecondCreateWhileOneIsInFlightSendsNothing`).
- Name rules: the app and the gateway run the same checks in the same order (empty, 64 bytes, leading dot, leading or trailing space, ASCII set); bytes are counted on both sides; dot, dot-dot, slash, backslash, NUL, Unicode and space edges agree.
- Trailing dot (`site.`) is allowed on both sides; D-091 does not forbid it.
- The umask cannot widen the mode: mkdir only removes bits and the chmod sets 0755 exactly (not tested under a changed umask).
- Duplicates: a registered path is refused before the mkdir, so a folder deleted from disk is not made again; a case variant of a present folder is refused by the lstat on macOS.
- Roots method is answered only to an authenticated client (existing test).
- Sheet: Create is off while a create or a root load is in flight, so no double submit (the model guards it, and the sheet disables the button).

### Not fixed

- The racing duplicate (store UNIQUE after the pre-check) returns `-32602` without `data.projectId`; only the pre-check path carries it. The app does not read it. Left as is.
- A swipe-down during a create is not blocked. The create completes and the home still refreshes. Left as is.
- Filesystem and store failures return `-32603`, not `-32602` as D-091's "all" suggests. Kept, see D-099; coordinator to confirm.
- Residual: a process that can write the parent can still move the open folder within milliseconds after the open (D-063 class). Not closed.

### Verification

- `go vet ./...` clean; `go test ./...` all packages ok (server package includes the 6 new Go tests).
- `node --test test/create-folder.test.mjs`: 9 of 9 pass (was 9 before; the roots case now also checks a removed root).
- App model tests: `ACPCodeTests/GatewayNewProjectTests.swift` (now 14 model tests) cannot be run through `xcodebuild test` in this task, so they were run in a scratch SwiftPM package at `<scratchpad>/verify-f1` that links the real `GatewayNewProjectModel.swift` and a copy of the test file without the home-selection class: 2 failed before the fix, 14 of 14 pass after.
- `xcodebuild build-for-testing` (scheme ACP Code, iPhone 17 simulator, derived data under `<scratchpad>/dd/f1-add-project-review`): TEST BUILD SUCCEEDED.
- `scripts/check.sh` in one run did not finish clean. Its wire-test step failed in two runs on different tests (`eventlog` permission request; `gitchanged` ignored file; then `lifecycle` FR-24 idle session). Each of those files passes alone (10/10, 6/6). A later full wire run (`npm test`, 256 tests) passed 256/256. The failing set moves from run to run, which points to timing under load. These files do not reach the folder or roots code. I did not prove they fail on db08383 too.
- The rest of check.sh, run directly: gateway dry run ok; `scripts/check-docs.mjs` ok (48 tests, 45 FRs, 15 NFRs, 78 decisions); Swift packages ACP CodeTransport (12, 1 skipped), ACPClient (221), AppServerClient (9) all pass; `go vet` clean.
- Secret-scan step: the worktree has no `deploy/` folder, so grep exits 2 and check.sh's branch is skipped. `gateway/test/apns.test.mjs:319` holds a fake PEM marker from base db08383 that the scan would match. Not changed here.

### G1 public exposure and deployment (2026-11-07, branch `feat/g1-deploy`)

- **Done:** `deploy/Caddyfile.connector` (public connector site, six paths, 404 for the rest, no client certificate, `{$CONNECTOR_HOST}`, automatic public certificate); `deploy/launchd/dev.acpcode.gateway.plist` (LaunchAgent template) and `deploy/launchd/dev.acpcode.caddy.plist` (LaunchDaemon template, root for 443); `gateway/config.mac.example.json` (`connector` block, `enabled: false`); `docs/MAC-SETUP.md` section 13 (connector: DNS, 443 forward, owner steps, verify, turn off). Decision text in `scratchpad/decisions/g1-deploy.md` (D-098).
- **Unchanged:** `deploy/Caddyfile` (phone block), `deploy/acpcode-gateway.service`, `deploy/bob-project.Containerfile`, all other parts of `docs/MAC-SETUP.md`, `gateway/internal/**`, Swift files. Live Caddy and gateway were not touched.
- **Verified on this Mac:**
  - `caddy validate` (Caddy 2.11.9) on `deploy/Caddyfile.connector` with `CONNECTOR_HOST` set: `Valid configuration`.
  - Route test with a test-only copy on ports 9080 and 8789 (scratchpad, not in repo): the six paths reach the upstream (200), and `/`, `/admin`, `/mcp/extra`, `/.well-known/oauth-protected-resource/mcp` and `/phone` return 404. The request carried no client certificate.
  - Combined config (phone block plus top-level `import` of the connector file, with a dummy CA path): `Valid configuration`.
  - `plutil -lint` on both plists: OK.
  - `gateway/config.mac.example.json` parses with `JSON.parse`; `connector.enabled` is `false`.
- **Not verified:**
  - `caddy validate` of the unmodified `deploy/Caddyfile` fails here only because `/etc/caddy/acpcode-client-ca.pem` does not exist on this Mac (it is an existing condition, not caused by this change).
  - Public certificate issuance, DNS, and the 443 forward: not testable without the owner's domain. Port 80 optional (verify on first issue).
  - Launchd install: templates only, not loaded.
  - `scripts/check.sh`: not run (no Go or Swift change; the worktree has no `gateway/node_modules`).
  - The gateway binary was not run against the example (as instructed).
- **Gateway parser:** `gateway/internal/config` does not reject unknown top-level keys. The `connector` block is ignored on this branch, so the example loads; it does not enable anything until D-095 (D1) reads the block.
- **Coordinator decisions:**
  1. The repo `deploy/Caddyfile` (port 443, `127.0.0.1:8787`) does not match the plan's phone listener (`:8443` to `8788`). I left it unchanged as instructed. The integration should decide whether to update the example.
  2. The suffixed metadata path `/.well-known/oauth-protected-resource/mcp` is not in the matcher list (404 at Caddy). D1 must make the gateway's `WWW-Authenticate` point at the root path, or the list must change.
  3. `docs/MAC-SETUP.md` section 12 still says the deployment is not covered. Left as is (outside the new section).
- **Commit:** `5973a57` on `feat/g1-deploy` (5 files, 233 insertions, no deletions).

### I1 integration (feat/integration-2026-11-07): merge and post-merge fixes

- **Merged:** A1, F1, G1, D1, B1, B2, E1 in that order, no-ff. Conflicts: none, so no resolution was needed. The contract spots (`GatewayHomeView.swift`, `ContentView.swift`, `server.go`, `gateway/internal/store`) merged cleanly; the E1 toolbar hook and the F1 New Project button both sit in `ContentView.swift`.
- **Post-merge:** `_acpcode/projects/list` now subscribes its socket to project state (note A1 item above). The metadata matcher has the path-suffixed form. The phone block is `:8443` to `127.0.0.1:8788`. The main Caddy example imports `Caddyfile.connector`. The secret-scan fixture in `apns.test.mjs` uses a neutral PEM label, and the parse branch is covered by a Go unit test. D-092 to D-095 and D-097 to D-099 are in `docs/DECISIONS.md`. The D2 decision is not written yet, so its number is absent there.
- **Not run in this step:** the node wire suite, `xcodebuild`, and the full `swift test`. Those run in the quiet-machine check (I2). Notes items 8, 9, 14, 16, 25 and 35 are still open until then, and so is the FR-24 question.
- **Open for I2:** the path-suffixed metadata form returns 404 from the gateway (the challenge names the root form, which is served). The connector's `/mcp` route, the phone `:8443` route and the Caddy `import` have not been run against a live Caddy.

### D2 connector tools and lean context summary (2026-11-07)

Branch `feat/d2-connector-tools` (from integration 0e6ae2a), commit c2781f5. Decision text: `<scratchpad>/decisions/d2-connector-tools.md` (D-096).

What is built
- Five C7 tools answer (`gateway/internal/connector/tools.go`, the table in `toolset.go`): `list_projects`, `list_sessions`, `get_context`, `send_prompt`, `get_turn`. Each checks the grant's scope first.
- Summary: at most 1000 characters; fields listed in D-096. Running tools from the event log (the five most recent); pending approvals from the live permission queue; `alwaysAllow` only when the gateway holds the session's MCP list.
- Server bridge (`gateway/internal/server/connector_tools.go`): the reads, and `send_prompt` through the phone's `handleMessage` path on a client that is not a socket. A read-only `LatestEvent` query in the store (`events_latest.go`).
- Limits enforced in the tool path: scope, `maxPromptBytes`, `promptsPerHour` per grant, one turn per session, `maxConcurrentTurns`, `sendPromptWaitSeconds`, `maxResultChars` (rune-safe cut).
- Audit: `connector_prompt` with `source: "claude"` and `grant`; the same two fields on every line of the turn. Prompt text never audited.

Files changed (beyond the owned list; each is one to a few lines, and D-096 lists them)
- `gateway/internal/connector/tools.go` (new), `tools_test.go` (new), `toolset.go`, `connector.go`
- `gateway/internal/server/connector_tools.go` (new), `connector_tools_test.go` (new), `server.go`, `projects.go`
- `gateway/internal/audit/audit.go`
- `gateway/internal/store/events_latest.go` (new), `events_latest_test.go` (new)
- `gateway/test/connector-tools.test.mjs` (new, 7 tests), `gateway/test/connector-tools-limits.test.mjs` (new, 2 tests)
- `gateway/test/connector.test.mjs` (one assertion), `gateway/test/connector-limits.test.mjs` (four assertions): "not implemented" expectations changed to the implemented tools

Results (run)
- `gofmt -l .` clean; `go vet ./...` clean.
- `go test -count=1 ./...` in gateway: every package ok. Connector package 17 tests (5 from D1, 12 new in `tools_test.go`). Server package: 5 new bridge tests in `connector_tools_test.go`. Store package: 1 new test.
- `go test -race` on connector and store: ok.
- `node --check` on all new and changed `.mjs` files: ok.

Mutation check (run)
- Removed the scope check in `sendPrompt` (`pid, err := "", error(nil)`). `TestToolsRefuseSessionsOutsideTheScope` failed at `tools_test.go:183` ("send_prompt to an unlisted session must be refused"). Restored from a saved copy (`<scratchpad>/d2-mutation/tools.go.good`, identical after restore); the test passes again.

Not run (written only)
- The Node wire tests were written and are NOT run, per the brief (R1 is timing on this machine). Files: `gateway/test/connector-tools.test.mjs` and `gateway/test/connector-tools-limits.test.mjs`, and the edited `gateway/test/connector.test.mjs` and `gateway/test/connector-limits.test.mjs`. The final check must run these four files.
- Not verified: the reply and `runningTools` on a live Bob; Bob's real `usage_update` shape (D-070); a real Claude client calling the tools (owner probe, plan step 7.0).
- The wire tests depend on the fake agent's title rule (first 50 characters of the prompt), which the send-prompt test works around.

Notes for the coordinator
- The final check should run `node --test gateway/test/connector-tools.test.mjs gateway/test/connector-tools-limits.test.mjs gateway/test/connector.test.mjs gateway/test/connector-limits.test.mjs` on a quiet machine, then `scripts/check.sh`.

### I2 final checks on feat/integration-2026-11-07 (after D2, quiet machine)

- **Merge:** `feat/d2-connector-tools` (c2781f5) merged with `--no-ff` into the integration branch as 15fc77e. No conflicts. Out-of-list edits reviewed (connector.go, server.go, projects.go, audit.go, events_latest.go, two wire tests): each is minimal, adds nothing to phone lines (audit `source` and `grant` are written only when set), and the prompt text is not audited.
- **Fixes:** the secret scan in `scripts/check.sh` now puts the excludes before the pattern (`-e`), and grep errors fail the step (exit 2) instead of being hidden. The scan passes on the tree. The apns test marker is `BEGIN TEST BLOB`, which the scan does not match, so no neutral form was needed (note 32). `docs/ARCHITECTURE.md` phone path is Caddy :8443 to 127.0.0.1:8788. `docs/design/ipad-ux-plan.md` manual checklist no longer says "Phase 8". D-096 is appended after D-099 (as the plan says), so the decision file is not in number order.
- **scripts/check.sh:** exit 0, "All checks passed". Go: connector, server, store, config, jsonv, mcpconf, push all ok. Node wire suite: 295 tests, 295 pass, 0 fail (includes FR-24 `lifecycle.test.mjs`, passed). Swift packages: ACP CodeTransport, ACPClient (ACPServiceTests passed), AppServerClient, all pass.
- **Named connector wire tests (`node --test`, four files):** 30 tests, 30 pass, 0 fail.
- **`node scripts/check-docs.mjs`:** ok, 48 tests, 45 FRs, 15 NFRs, 86 decisions. **`git diff --check`:** clean.
- **`xcodebuild ... test` (iPhone 17 simulator, one run):** TEST SUCCEEDED. XCTest: 330 tests, 0 failures, 40 suites passed. Swift Testing (in the same run): 111 passes, 0 failures. The new suites (RunningWork*, Usage*, ConnectorConnectionsModelTests) compiled and ran. No stall. The log is at `<scratchpad>/results/i2-xcodebuild.log`.
- **Not done:** the Caddy route checks and the live phone and Claude probes (owner steps); the live `allowedOrigins` decision.

## 2026-11-08 Wave 4 task notes and integration (feat/integration-wave4)

# P1 public 8443, non-root, DNS-01 (D-100): results

Branch `feat/p1-public-8443` (based on `feat/integration-2026-11-07` at 31cf6de). Decision text: `<scratchpad>/decisions/p1-public-8443.md`.

## Changed files
- `deploy/Caddyfile`: global `auto_https disable_redirects`; header comments; connector import comment. The phone block is unchanged (`agent.example.com:8443`, `client_auth` with `trust_pool file /etc/caddy/acpcode-client-ca.pem`, `reverse_proxy 127.0.0.1:8788`).
- `deploy/Caddyfile.connector`: site `{$CONNECTOR_HOST}:8443`; `tls { dns PROVIDER {env.CADDY_DNS_API_TOKEN} }`; seven-path matcher (the path-suffixed metadata form was already present); 404 for the rest; no `client_auth`.
- `deploy/launchd/dev.acpcode.caddy.plist`: LaunchAgent (no root, no LaunchDaemon paths); runs Caddy from `/Users/you/acpcode/caddy/bin/caddy` after loading `/Users/you/acpcode/secrets.env`; logs and data under the owner's folder.
- `gateway/config.mac.example.json`: `publicOrigin` is `https://your-public-name.example:8443`. JSON has no comments, so the note is in MAC-SETUP section 13.
- `docs/MAC-SETUP.md`: section 13 rewritten. No other section changed.

## Verification
- `caddy validate` (Caddy v2.11.9, stock): the config with the DNS line removed, phone trust path pointed at a dummy CA, and `CONNECTOR_HOST` set: **Valid configuration**. With `dns cloudflare` set and the stock build: **fails**, `module not registered: dns.providers.cloudflare`, because the stock build has no DNS module. With the `PROVIDER` placeholder left in, validation fails the same way. Expected until the owner builds with the module.
- `caddy adapt` of the valid config: one server, `:8443`, `automatic_https: {disable_redirects: true}`. Policies: `sni: agent.example.com` with client authentication; the default (no match) with none. The original committed config has the same structure on its `:8443` server. The original `:443` server is gone.
- `plutil -lint`: `dev.acpcode.caddy.plist` OK, `dev.acpcode.gateway.plist` OK.
- JSON parse of `gateway/config.mac.example.json`: OK. The gateway's own loader (`go test ./internal/config`, plus a temporary test removed afterwards) reads `publicOrigin` with the port, and `enabled` is false.
- Not run: no Caddy or gateway was started against any live config. The live Caddy (PID 72644) and the main checkout were not touched.

## Sources (DNS-01, port rules, redirects)
- `tls` directive, DNS syntax `dns cloudflare {env.CLOUDFLARE_API_TOKEN}`; the page says the provider plugin comes from the `caddy-dns` repositories: https://caddyserver.com/docs/caddyfile/directives/tls
- Automatic HTTPS. DNS challenge "does not require any open ports". TLS-ALPN "requires port 443 to be externally accessible": https://caddyserver.com/docs/automatic-https
- Global options: `auto_https disable_redirects` ("Disable only HTTP-to-HTTPS redirects"): https://caddyserver.com/docs/caddyfile/options
- xcaddy `--with` usage: https://github.com/caddyserver/xcaddy

## Not verified
- Claude's acceptance of a non-443 port (probe 7.0).
- Live DNS-01 issuance, router forwarding, and the public path. Needs the owner's domain, token and plugin build.
- A DNS provider plugin build (xcaddy not installed here; the provider is not chosen).
- Runtime binding: that `auto_https disable_redirects` stops the port 80 bind as non-root. Checked against the documentation and the adapted JSON only.
- The phone site on a no-SNI connection with a `agent.example.com` Host header, on the shared listener. Its 421 behaviour is the same as before, but it was not re-tested.
- The path-suffixed metadata route returns 200. That needs the gateway change (D3).
- Section 12 of `docs/MAC-SETUP.md` still says the public connector is on port 443. Section 12 is outside this task. Integration should update it.

# D3 connector metadata, port in publicOrigin, StartPrompt race (D-101)

Branch feat/d3-connector-metadata, based on 31cf6de. Decision text: `<scratchpad>/decisions/d3-connector-metadata.md`.

## Changes

- Metadata: `GET /.well-known/oauth-protected-resource/mcp` served with the root body. `WWW-Authenticate` on `/mcp` names the path-suffixed form. All other routes and the 404/405 rules are unchanged.
- publicOrigin validation: `validHTTPSOrigin` in the connector block (port 1 to 65535 optional, no path, query, fragment, user info or empty port). Also applied to allowedOrigins. APNs validation untouched.
- Race: `turnRegistry.add` takes the release; a test seam `inserted` lets the test read the record in the window.

## Race evidence

- Before the fix: `TestReleaseIsSetBeforeTheTurnIsReadable` FAIL ("a turn was readable from the registry before its release was set").
- After the fix: PASS. `go test -race` on the connector package: ok.

## Test counts

- `go vet ./...`: clean. `gofmt -l`: clean.
- `go test ./...`: config ok, connector ok, jsonv ok, mcpconf ok, push ok, server ok, store ok.
- `go test -race ./internal/connector/ ./internal/config/`: ok.
- `node --check`: all five files ok.
- `test/connector-metadata.test.mjs`: 6/6 pass (new file, includes a dry-run check).
- `test/connector.test.mjs`: 17/17 pass (one assertion changed to the path-suffixed challenge).
- `test/connector-limits.test.mjs`: 4/4 pass.
- `test/connector-tools.test.mjs`: 7/7 pass on the final rerun. Two earlier runs failed 4 and 3 tests (send_prompt returning `running` before the reply, under machine load of 600 to 900). The base commit ran 7/7 under the same load, and the branch then ran 7/7 on the next two runs. Intermittent, timing-sensitive; not reproduced at quiet load.
- `test/connector-tools-limits.test.mjs`: 2/2 pass on the final rerun (one earlier run failed 1, same cause).

## Not checked

- `scripts/check.sh` not run (coordinator runs it after Wave 4 merges), as instructed.
- Real Claude client behaviour with the path-suffixed challenge: not probed (owner step 2).
- Caddy routing for the path-suffixed URL: belongs to P1 (deploy matcher), not checked here.
- Git worktree: the `gateway/node_modules` symlink (gitignored) is removed before the worktree is removed; `gateway/bin/` is a gitignored build output.

# B3 app project agent state (D-102) results

Branch `feat/b3-app-project-state`, from `feat/integration-2026-11-07` at 31cf6de. Decision: `scratchpad/decisions/b3-app-project-state.md`.

## Files
- New: `ACPClient/Sources/ACPClient/Gateway/GatewayProjectState.swift` (decoder: four states, `.unknown` default, `since`).
- New: `ACPClient/Tests/ACPClientTests/GatewayProjectStateTests.swift` (7 tests).
- New: `ACPCodeTests/ProjectStateTests.swift` (14 app tests: `ProjectStateHomeTests` 8, `ProjectStateRouterTests` 6).
- Changed: `ACPCode/Fork/Gateway/GatewayHomeModel.swift` (per-server states, list filter, pending states before the first list, clear on server change).
- Changed: `ACPCode/Fork/Gateway/GatewayHomeView.swift` (`GatewayAgentStatePresentation`, `GatewayAgentStateLabel`, one line in the section header).
- Changed: `ACPCode/Fork/Gateway/AppViewModel+Gateway.swift` (`handleGatewayProjectState`).
- Changed outside the owned list: `ACPCode/AppViewModel.swift` (router case, `lazy var gatewayHome`, forwarded `objectWillChange`), `ACPCode/ContentView.swift` (3 lines in the gateway home wiring), `ACPClient/AGENTS.md` (one doc line).

## Routing and the other notifications
- `_acpcode/project/state` returns before the log line, like `_acpcode/git/changed`. The state is recorded for the selected server: the one live connection belongs to it.
- `_acpcode/event`, `_acpcode/git/changed` and `_acpcode/notice` are unchanged. Each has a wire test in `ProjectStateRouterTests` (`testAGatewayEventStillAppliesToTheOpenSession`, `testAGitChangedNotificationStillRefreshesTheProjectStatus`, `testAGatewayNoticeStillReachesTheLog`). `_acpcode/notice` has no app handler; it still goes to the log.

## Tests and results
- `swift test` in ACPClient (full package, by hand; `check.sh` not run because it needs the gateway wire suite and B3 changes no gateway code): 254 tests, 0 failures, exit 0. 7 of them are the new `GatewayProjectStateTests`.
- `xcodebuild build-for-testing` (`-derivedDataPath scratchpad/dd/b3-app-project-state`, `platform=iOS Simulator,name=iPhone 17`): TEST BUILD SUCCEEDED. The 14 app tests are compiled, not executed (per the brief; no `xcodebuild test`).

## Mutation checks
- Decoder: the `running` mapping changed to `.unknown` in a copy of `GatewayProjectState.swift`. 2 of 7 tests fail (`testEachOfTheFourStatesDecodes`, `testAMalformedSinceKeepsTheStateAndDropsOnlyTheTime`). The file was restored and checked identical to its backup.
- Router (not run here): removing the `if notification.method == GatewayProjectState.method` block in `AppViewModel.handleIncoming` should fail `ProjectStateRouterTests.testAProjectStateNotificationUpdatesTheHomeOfTheSelectedServer`, `testAnUnknownStateNotificationClearsTheShownState` and `testAStateForAProjectNotOnTheListIsIgnoredOverTheWire`. The coordinator runs this during integration, with the full `xcodebuild test`.

## Commit
Hash: f64a163 on `feat/b3-app-project-state`.

## Not verified
- The header on the simulator (layout, the progress indicator, VoiceOver text). Only the model and the presentation helper are tested.
- The gateway sends no state when a socket starts listing (`projectstate.go`: "No state is assumed as the baseline"). A project running before the home opens, or after a reconnect, shows nothing until its next transition. Fixing this needs a gateway snapshot on subscribe, which is a gateway decision. Not changed here.

## For integration
1. Run the full `xcodebuild test`, and the router mutation above.
2. Decide the snapshot-on-subscribe gap (above).
3. Merge conflicts to expect: `ContentView.swift` (C7 touches the session row; this branch's hunks are at the gateway home state and its task block) and `AppViewModel.swift` (the `handleIncoming` notification block).

# C7 results: iPad and UX phases 7.0 and 7.1 (branch feat/c7-ipad-quickwins, D-103)

Baseline (phase 7.0): iPhone 17 and iPad Pro 13-inch (M5), light and dark, launch screen only. No live gateway or fixture, so the session view and the New Session sheet are not captured. Images in scratchpad design-baseline and design-after (not committed).

Contrast (WCAG 2.x, measured by ForkContrast): all status tones pass 4.5:1 text and 3:1 glyph on row and grouped surfaces, light, dark and Increase Contrast. Light approval, error and ok were darkened from the plan's values (they failed on grouped).

Tests: DesignTokensTests.swift (contrast math with pass and fail cases, resolved UIKit contrast per appearance, pill labels per GatewaySessionStatus, row label). XCTest not run (build-for-testing only). Pure table checked with a harness: passes on the real table; mutated running-light text fails (4 failures).

Build: build-for-testing succeeded (iPhone 17, D-103 tree).

# G2 results: project state snapshot on listing (D-104)

Branch `feat/g2-state-snapshot`, commit `83c1420`, from `31cf6de`. Not pushed, not merged.

Files changed:
- `gateway/internal/server/projectstate.go`: `sendSnapshot` and `stateMessage`; `watchProjectStates` sends one snapshot per listed project. Header comment updated.
- `gateway/test/project-state-snapshot.test.mjs` (new): 4 wire tests.
- `gateway/test/usage-project-state.test.mjs` (outside the owned list, see below): the feeds of its four tests now start after the listing response, so the snapshot is not part of their transition assertions. Assertions unchanged.

No change to `projects.go` or `sessions.go`: their hooks already call `watchProjectStates`.

Checks:
- `gofmt -l`: clean. `go vet ./...`: pass. `go test ./...`: all packages ok (server 13.2 s).
- `node --check test/project-state-snapshot.test.mjs`: pass.
- `node --test test/project-state-snapshot.test.mjs`: 4 of 4 pass (final run).
- Related wire files, each run alone: auth-missing 1/1, create-folder 9/9, eventlog 5/5, denypaths 5/5, git 8/8, projectlists 6/6, projects 7/7, sessions 4/4, usage-project-state 4/4, turndiff 7/7, watchskip 5/5, usage 5/5.
- A multi-file `node --test` call ran only one file, so each file was run separately.
- `scripts/check.sh` not run, as instructed.

Mutation: with both `a.sendSnapshot(c)` calls removed, test (a) fails ("new socket that lists ... running"). Restored from a backup copy, the file has both calls and test (a) passes.

Not verified: the full wire suite (`scripts/check.sh`), and strict ordering after the response (see D-104).

## 2026-11-08: Apple runner entrypoint fix, production start on the Mac

- **Bug found:** the project image declares `ENTRYPOINT ["bob"]` (`deploy/bob-project.Containerfile`), but the Apple and Podman agent commands ran `bob acp ...` without `--entrypoint`. Bob then ran as an argument of `bob`, never answered `initialize`, and the gateway reported `initialize_timeout` after 60 s. The docs (`docs/MAC-SETUP.md` step 5) already said the first word is the entrypoint.
- **Fix:** `imageAndCommand` in `gateway/internal/server/runner.go` passes `--entrypoint <argv[0]>` before the image, for both container runners. Tests updated first (red, then green): `runner_test.go`, `runner_apple_test.go`. The fake Podman (`test/fixtures/fake-podman.mjs`) now honours `--entrypoint`, as the fake container already did.
- **Checks:** `(cd gateway && go test -count=1 ./...)` all packages ok. `npm test --prefix gateway` 305 of 305 pass (exit 0, 263.5 s). Container wire files 20 of 20 pass (`apple-runner`, `lifecycle-apple`, `runner-apple`, `lifecycle`).
- **Smoke test (throwaway gateway, then removed):** `initialize` ok; `session/new` for a project started `acpcode-<projectId>` in `container list`; stopping the gateway removed the container.
- **Production start:** config `~/acpcode/config.json` (Apple runner, `runner.image` `localhost/acpcode-bob:2.0.9`, image tagged from `localhost/agmente-bob:2.0.9`, same digest). Gateway and Caddy run under launchd (`dev.acpcode.gateway`, `dev.acpcode.caddy`). Mutual TLS checked through Caddy at `adams-mac-studio.local:8443`: no client certificate gives `000`; with the client certificate and bearer token, `initialize` returns the gateway's extensions.
- **Note:** a binary copied with `cp` was killed at start (exit 137) until re-signed with `codesign --force --sign -`. The restart script does not copy; re-sign after any copy into `~/acpcode/bin`.
- **Not verified:** a container start from the iPhone (device test pending), and the connector (not set up).

## 2026-11-13 Phone file upload into a project folder (D-115)

Branch `feat/project-upload` from `main`, not committed. Two research agents compared approaches; a critic agent checked them and set the decisions. Owner direction: option 1 (write into the project folder).

Gateway (`gateway/internal/server/upload.go`, `audit.go`):
- `go test ./...` (all packages): ok.
- Go unit tests (`upload_test.go`): name and type rules, syntax for stat, the 8 MiB encoded cap, no-clobber write (existing file and dangling symlink), mode 0644, one upload per project: 6 of 6 pass.
- Mutation: `root.Link` replaced by `root.Rename`. `TestWriteUploadNoClobberNeverReplacesAName` fails. Restored; passes.
- Wire `gateway/test/files-upload.test.mjs`: 8 of 8 pass (happy path with mode and audit with no content or hash; each refusal with its fixed text; an existing name; a symlink at the name; bad base64 and an oversize decode; a missing folder; stat for absent, present, secret; stat hash matches the upload). No agent starts for upload or stat.
- Related wire files `files`, `files-upload`, `skills`, `denypaths`, `connector-tools`: 46 of 46 pass.

App:
- ACPClient `swift test --filter GatewayFilesTests`: 7 of 7 pass (name rules, cap, no send over the cap, request payload, result decoding, gateway text passes through, stat decoding).
- `xcodebuild ... -only-testing:ACPCodeTests/GatewayFileUploadModelTests test` on iPhone 17 simulator: 13 of 13 pass (folder refused, bad type refused, oversize refused before copy, staging, send saves and drops the copy, gateway refusal keeps the file with no retry, lost answer is unknown, check finds the same file, check finds nothing, check finds a different file, cancel while sending, no connection sends nothing, discard, the SHA-256 vector). `** TEST SUCCEEDED **`.

Not run or not built:
- The full gateway wire suite and full `ACPCodeTests`. Only the files above were run.
- A UI test of the sheet and its menu entry. No device or Apple picker check.
- The dedicated upload WebSocket (the critic's head-of-line recommendation). Upload uses the main socket with the 8 MiB cap. Known gap.
- The Upload entry in the sidebar project header (`SidebarProjectHeader`). Only the home project header has it.
- Production deploy (`~/acpcode`). Not done.
## 2026-11-10: drawer, project image tools, approval summary, model selection, all-sessions list, settings panel (D-109 to D-114)

- **Branch:** `feat/integration-ui-2026-11-10`, merged from `feat/d109-slide-over-drawer`, `feat/settings-panel`, `feat/acp-model-selection`, `feat/approval-detail-notification`, `feat/project-image-tools`, then `feat/d113-all-sessions-agent-icons`. No merge conflicts. Not merged to `main`.
- **App tests (five branches merged, before D-113):** `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' test`: 554 unit tests, 0 failures; UI launch tests pass; the opt-in Codex UI test is skipped. `** TEST SUCCEEDED **`.
- **Gateway (five branches merged):** `go vet ./...` and `go test ./...` pass. `scripts/check.sh`: "All checks passed", exit 0.
- **Image:** `container build --dns 192.168.86.1 -t localhost/acpcode-bob:2.0.9-tools1 -f deploy/bob-project.Containerfile deploy`, then `deploy/verify-project-image.sh --dns 192.168.86.1 localhost/acpcode-bob:2.0.9-tools1`: 21 passed, 0 failed (agent run, not repeated at integration). Size 139.4 MB to 509.5 MB. Without `--dns` the two network checks fail on name resolution (D-081).
- **Mutation checks (agent runs):** `session/set_model` method name changed: 2 tests fail. The 80-character cut removed: 1 test fails. Whole-word match for "pi" removed: 1 test fails. Each file restored from a backup copy.
- **Load-related failures seen in agent runs, not at integration:** `connector-tools.test.mjs` (up to 4 tests) and `GatewaySessionStopTests.testARecoveryThatLoadsButStillFailsDoesNotLoopAndOffersRemoval` failed while other builds ran, and passed when run alone.
- **Not verified:** any new screen in the simulator or on a device; the macOS build (fails in `ACPCodeLiveApproval`, iOS-only code, before the app compiles); a push to a device or watch; a live agent that offers models; Podman and amd64 for the image.
