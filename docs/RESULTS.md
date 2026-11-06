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
| T-32 | PASS on Bob 2.0.9: `initialize` equals the fixture (also matched on 2.0.7 except the version) | 2026-11-06 |
| T-33 | PASS on Bob 2.0.9 (and 2.0.7): new, prompt, load, resume, list, delete all succeed | 2026-11-06 |
| T-34 | Recorded (differs from F-12): on 2.0.7 and 2.0.9, `session/load` and (2.0.9) `session/resume` during a turn are refused with `-32600`; the turn completes. A second Bob process is not refused (see Q-5 entry) | 2026-11-06 |
| T-35 | Partial: Bob's error recorded; app part not built | 2026-11-05 |
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
