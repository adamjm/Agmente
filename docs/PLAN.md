# Plan

Status key: [ ] not started · [x] done and checked · [!] blocked (reason in RESULTS.md)

Phase order follows dependencies, with no-credential work first (D-004). Each phase names the tests it closes. A phase is complete when each of its tests has a result in RESULTS.md. A FAIL is a valid result if it has a decision entry.

## Phase 0 — Scaffold check (no credentials)

Goal: the overlay sits at the fork root and the check gate passes. Closes T-1.

- [x] 0.1 Unzip the overlay at the fork root. Run `git status`. Confirm that only `CLAUDE.md` is modified and all other entries are new files.
- [x] 0.2 In `.gitignore`, replace the line `.claude/` with three lines: `.claude/*`, `!.claude/settings.json`, `!.claude/commands/` (D-011). Check: `git status --untracked-files=all .claude` lists `settings.json` and `commands/next.md`, and `git check-ignore .claude/settings.local.json` prints that path.
- [x] 0.3 Run `npm ci --prefix gateway`.
- [x] 0.4 Run `scripts/check.sh`. Record T-1.
- [x] 0.5 On macOS, confirm that `scripts/check.sh` runs the `ACPClient` and `AppServerClient` Swift package tests and that they pass.

Plan notes:
- The scaffold build applied the overlay to upstream commit `87f224e`, tested the 0.2 change, and ran 0.3 and 0.4 on Linux (Swift skipped). See RESULTS.md. Run them again in your fork.
- 2026-11-06 macOS fork run: 0.1 to 0.3 done. 0.4: env test fixed by D-012. 0.4 and 0.5 pass with Xcode 27.2 (RESULTS 2026-11-06).

## Phase 1 — Gateway admission and guard (no credentials)

Goal: no unauthenticated client can reach an agent. Closes T-2 to T-13.

- [x] 1.1 Config loader with validation; refuse a non-loopback host (FR-2, NFR-14). Check: T-5.
- [x] 1.2 Token auth before upgrade with SHA-256 hashes and constant-time compare (FR-1). Check: T-2, T-3.
- [x] 1.3 Reject requests with an `Origin` header (FR-3). Check: T-4.
- [x] 1.4 Per-address auth rate limit, with `X-Forwarded-For` trusted only from loopback when `trustProxy` is true (FR-8). Check: T-10.
- [x] 1.5 Agent caps per identity and total (FR-5). Check: T-7.
- [x] 1.6 Spawn only the configured command, with an environment allow-list (FR-4). Check: unit test `agent-process`.
- [x] 1.7 Guard: one JSON object per message, size cap, `cwd` inside roots (FR-6, FR-7, NFR-3). Check: T-6, T-8, T-9.
- [x] 1.8 Audit log with method names only (FR-9). Check: T-13.
- [x] 1.9 Measure NFR-1 and NFR-2. Check: T-11, T-12.
- [x] 1.10 Write `scripts/make-client-cert.sh`: create a client CA and one device certificate as `.p12`, with OpenSSL. Check: the script's `--dry-run` prints the commands; `openssl verify` passes on the output.
- [ ] 1.11 Deploy on the host: Caddy with `deploy/Caddyfile`, gateway with `deploy/agmente-gateway.service`. Check: `curl` without a client certificate fails the TLS handshake; with the certificate and no token it gets 401.
- [ ] 1.12 Point the current, unmodified Agmente app at the gateway with a token, using a local agent such as `bob acp` or another ACP CLI. Check: a prompt round-trips. Record the agent and version.
- [x] 1.13 Interim guard against two Bob processes on one task store (F-21, D-015): free the agent slot on the agent's `exit`, not on socket close; set `maxAgentsPerIdentity` and `maxAgentsTotal` to 1 in `config.example.json`. Check: gateway test "D-015: a closed socket keeps its slot until the agent has exited" passes, and fails against the old release point.

Stop condition: if T-12 p95 overhead is above 5 ms, add a decision entry and stop for review.

Plan notes:
- Tasks 1.1 to 1.9 were built and checked with the scaffold. See RESULTS.md.
- `deploy/` files are examples. Mark each directive "verify" until 1.11 passes.

## Phase 2 — iOS client hardening (macOS, no credentials)

Goal: the app keeps secrets in the Keychain and cannot send them in clear text. Closes T-14 to T-17.

- [x] 2.1 Add `Agmente/Security/KeychainStore.swift` (generic password items, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) with unit tests.
- [x] 2.2 Migrate `token`, `cfAccessClientId` and `cfAccessClientSecret` from Core Data to the Keychain at launch. Erase the Core Data values. Check: T-14.
- [x] 2.3 Add one scheme policy function: allow `ws` only for loopback, `.local` and RFC 1918 hosts; default to `wss` in `ServerManagementViews.swift` and `AppViewModel.swift`. Check: T-15.
- [x] 2.4 Cap frame and message size at 16 MiB in both `URLSessionWebSocketProvider.swift` files; close with 1009. Check: T-16.
- [x] 2.5 Decide in DECISIONS.md whether to extract one shared WebSocket package now or later. Reason: the transport is duplicated (review finding C6).
- [x] 2.6 Add optional SPKI pinning with `sec_protocol_options_set_verify_block`. Check: T-17.
- [x] 2.7 Import a client identity (`.p12`) to the Keychain and present it with `sec_protocol_options_set_local_identity`. Check: connect through Caddy from phase 1.11.
- [x] 2.8 Set `NSFileProtectionComplete` on the Core Data store and exclude it from backup. Check: unit test reads the file attributes.

Plan notes:
- 2026-11-06 plan, awaiting owner approval. Code read: `SessionStorage.swift` (`fetchServers`, `saveServer`, `deleteServer`), `Persistence.swift`, `AppViewModel.swift` (`defaultScheme`, `validateServerConfiguration`), `ServerManagementViews.swift`, both `URLSessionWebSocketProvider.swift` files, `Agmente.xcdatamodel`, `Info.plist`. The Xcode project uses synchronized folders (`objectVersion = 77`), so new files under `Agmente/Security/` and `Agmente/Fork/` join the target without project-file edits.
- Order: 2.5, 2.1, 2.2, 2.8, 2.3, 2.4, 2.6, then 1.10, then 2.7. Reason: 2.5 extracts the transport that 2.4, 2.6 and 2.7 change. 2.2 and 2.8 both touch the store. 2.7 needs the certificates from 1.10.
- 2.5 (decided, D-017): extract the transport now. A new local package `AgmenteTransport/` holds one `NativeWebSocketConnection` (NWConnection, handshake, frame parser, 16 MiB cap, TLS options: SPKI pins and client identity). `ACPClient` and `AppServerClient` add it as a path dependency. Their `URLSessionWebSocketProvider` files become thin adapters to their own `WebSocketProviding`, `WebSocketConnection` and `WebSocketEvent` types, so neither package's public API changes. Then 2.4, 2.6 and 2.7 change one file. Tests move with the code to `AgmenteTransport/Tests`; the existing ACPClient and AppServerClient transport tests must still pass unchanged. `scripts/check.sh` runs `swift test` for the new package too.
- 2.1 `Agmente/Security/KeychainStore.swift`: generic-password items, service `com.agmente.server`, account `<serverId>/<field>`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable` false. API: `set`, `get`, `delete`, `deleteAll(serverId:)`. Tests in `AgmenteTests/KeychainStoreTests.swift` (app-hosted, so the simulator Keychain is available): round trip, overwrite, delete, and the stored accessibility attribute read back.
- 2.2 Migration in `Agmente/Security/ServerSecretMigration.swift`. It runs once at launch and on every `fetchServers`. For each `StoredServer` with a non-empty `token`, `cfAccessClientId` or `cfAccessClientSecret`, it writes the value to the Keychain, reads it back, then sets the Core Data attribute to nil and saves. The Keychain write comes first, so a crash in between leaves the secret in both places and never in neither. The changes are hooks in `SessionStorage` (`fetchServers` reads secrets from the Keychain, `saveServer` writes them there and stores nil, `deleteServer` calls `deleteAll`). The model keeps the attributes (no model migration), always nil. Check T-14 on a temp SQLite store. Extra check: after the erase and a WAL checkpoint, the store files do not contain the token bytes. This needs SQLite `secure_delete`, set in 2.8.
- 2.8 In `Persistence.swift`: `NSPersistentStoreFileProtectionKey: FileProtectionType.complete`, SQLite pragma `secure_delete = ON` (so erased secrets do not stay in free pages), and `isExcludedFromBackup` on the `.sqlite`, `-wal` and `-shm` files. Risk: with `complete`, the store cannot be opened while the device is locked, and `Persistence` calls `fatalError` on a load failure. Phase 3 push handling may open the store in the background. This task replaces the `fatalError` with an error state the app can recover from. If background access turns out to be needed, a D-n entry can choose `completeUntilFirstUserAuthentication`. Check: a unit test reads the protection and backup attributes. The simulator does not enforce data protection, so it is checked on a device later.
- 2.3 (revised, D-018, D-019) `Agmente/Security/TransportPolicy.swift`: `validate(url:localOnly:buildIsDebug:)`. `wss` is allowed unless "Local only" is on and the host is not local. `ws` is allowed only for loopback in Debug builds (`#if DEBUG`), or for loopback, `.local` and RFC 1918 when the server is marked "Local only". Everything else is refused, including Tailscale `100.64/10` and IPv6 unique-local `fc00::/7`. A new Boolean Core Data attribute `localOnly` (default false) goes in the same lightweight model version as `spkiPins` (2.6), created here. The add-server form gets a "Local only" toggle. While it is off, the scheme picker offers only `wss` (and `ws` in Debug). While it is on, it offers `ws` and `wss` and shows a warning that the token is sent unencrypted on the local network. Defaults become `wss` with "Local only" off (`ServerManagementViews.swift` lines 8, 41, 106-108, 360, 376; `AppViewModel.swift` lines 15, 22). The policy runs in `validateServerConfiguration` and at connect time in both view models, before `makeConnection`. A saved `ws` server that the policy refuses stays in the list and shows a clear error until edited. Check T-15: pure policy tests for each case, plus a recording mock `WebSocketProvider` showing zero `makeConnection` calls for refused URLs. Existing tests that use `ws://` hosts are updated in the same change, because FR-11 changes that behaviour, and each one is listed in RESULTS.
- 2.4 Both providers: `maxMessageBytes = 16 MiB`. `parseFrameFromBuffer` checks the declared length as soon as the frame header is read, before waiting for the payload, so a 17 MiB header never makes the buffer grow. Continuation frames check the reassembled total. On overflow: send close 1009, then throw. Check T-16 in each package against a loopback `NWListener` test server that sends a 17 MiB frame header. Pass: close code 1009, and the read buffer never grows past the cap plus one read chunk.
- 2.6 Optional per-server SPKI pins: a new optional Core Data attribute `spkiPins` (base64 SHA-256 of SubjectPublicKeyInfo DER; not a secret), so a lightweight model version. The providers get a TLS configuration through a new initializer, and `makeConnection(url:)` stays the same. The verify block runs normal trust evaluation (`SecTrustEvaluateWithError`) and also requires one certificate in the chain to match a pin. Pinning adds to trust; it never replaces it. SPKI DER is rebuilt from `SecCertificateCopyKey` plus the ASN.1 header for RSA 2048/4096 and EC P-256/P-384. Unit tests use public test certificates (no private keys) as fixtures. T-17 runs against a local TLS server started by a test script (`openssl s_server` with a throwaway certificate made at run time in a temp folder), with the result recorded. Advice: pin the issuing CA or keep two pins, because a Let's Encrypt leaf key may rotate on renewal (verify for Caddy).
- 1.10 before 2.7: `scripts/make-client-cert.sh` with OpenSSL (`/usr/bin/openssl` is present). Its output goes to a gitignored folder.
- 2.7 Import a `.p12` with the document picker and `SecPKCS12Import` (passphrase entered once, never stored). Store the identity in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and reference it per server by persistent reference. Present it with `sec_protocol_options_set_local_identity`. Check: connect through Caddy. Caddy v2.11.9 is installed on this Mac (owner, 2026-11-06). Until the host deploy (1.11), a local Caddy with the `deploy/Caddyfile` client-CA block and `tls internal` is used for this check.
- Tests per task: the new unit tests, then `swift test` for both packages, then the full `AgmenteTests`. 2.3 and 2.4 change the connect path, so `CodexServerViewModelTests` and `ViewModelSyncTests` must pass (CLAUDE.md upstream rule). 2.3 changes the add-server form default, so the relevant `AgmenteUITests` run too.
- Checked, no change needed: `Info.plist` already has `NSAllowsArbitraryLoads` false and `NSAllowsLocalNetworking` true. The token and client-secret fields are already `SecureField`.

## Phase 3 — Projects, sessions and git (no Bob credentials)

Goal: sessions keep running with the phone offline; git state is correct and safe. Closes T-18 to T-31. Uses the fake agent; APNs delivery (3.11) needs an APNs key.

Gateway:
- [x] 3.1 Extend `gateway/test/fixtures/fake-agent.mjs` with Bob's behaviours: turns that take time, `session/request_permission`, `session/load` and `session/resume` that are refused with `-32600` while a turn runs and that rebuild the session and replay coalesced history after the response when idle (F-12), session persistence across restarts, and a shared-store mode that loses the earlier writer's turn when two fake processes open one session (F-21).
- [x] 3.2 Choose the SQLite driver for the Go gateway in a D-n entry (D-007's `node:sqlite` no longer applies, D-021).
- [x] 3.3 Project registry and `_agmente/projects/*`. Check: T-25.
- [x] 3.4 Agent supervisor: start the project's container and Bob on the first request (FR-45, D-016); one agent per project, independent of sockets; start a replacement only after the old process emits `exit`; take an exclusive lock on the project's `HOME` (container name `agmente-<projectId>`) before spawn (D-015). Supersedes D-006. Check: two sockets for one project share one process; a second gateway on the same project is refused; re-run `gateway/scripts/probe-bob-races.mjs` and the second socket's load reaches the same Bob and is refused.
- [x] 3.5 Event log with sequence numbers. Check: T-20.
- [x] 3.6 `_agmente/sessions/subscribe` with replay. Check: T-18, T-19.
- [x] 3.7 Load and resume guard (FR-20). Check: T-21.
- [x] 3.8 `_agmente/sessions/index`.
- [x] 3.9 Approval queue with timeout. Check: T-22, T-23.
- [x] 3.10 Push payload builder. Check: T-24.
- [!] 3.11 APNs delivery with token-based auth (`.p8`). Check: T-48. The wire part and the Go unit tests pass against a fake APNs server (D-053 to D-055). BLOCKED: the device part needs a real `.p8` key, the Apple account and an iPhone (`BLOCKED:` in RESULTS; see docs/PUSH-TESTING.md Part E).
- [x] 3.12 Idle close (FR-24) and project stop when idle (FR-45): stop Bob, then the container; wait for exit before any restart. Check: T-46.
- [x] 3.13 Container exec runner for git with the safe flags, timeout and output cap. Check: T-26, T-27.
- [x] 3.14 `git/status`, `git/diff`, `git/log` with path allow-list and deny-list. Check: T-28, T-29, T-30.
- [x] 3.15 Turn snapshots and `git/turnDiff`. Check: T-31.
- [x] 3.16 File watcher and debounced `git/changed` (NFR-9).

App:
- [x] 3.17 Projects and sessions home screen; new-session sheet picks a project (FR-26).
- [x] 3.18 When connected to the gateway, `openSession` subscribes with `afterSeq` instead of sending `session/load`. Remove the `X-Client-Id` reattach.
- [x] 3.19 Approvals inbox and badge.
- [x] 3.20 Push registration and deep link to a session. (Deep link and permission and token capture done; sending the token to the gateway and push delivery are BLOCKED, see RESULTS and D-041.)
- [x] 3.21 Branch chip, Git tab, and turn diff in the file-change row (FR-31). (Built and unit-tested; not run against a live gateway in the simulator, see RESULTS and D-042.)

Stop condition: if T-21 shows the agent still receives a load during a turn, stop. Do not build app work on top of it.

Plan notes:
- 2026-11-06 plan, approved by the owner on 2026-11-06 (D-020 settles the pending-approval question). Code read: `gateway/src/*.js`, `gateway/test/fixtures/fake-agent.mjs`, the app's `openSession` and prompt pre-flight in `ServerViewModel.swift`. Checked: `node:sqlite` on Node v24.5.0 writes 10,000 events in 7 ms and reads them in 4 ms (in memory), and prints an `ExperimentalWarning`. Podman 5.6.2 runs.
- **Milestones, each ending in a report and a stop:** 3A sessions core (3.1 to 3.9, 3.12; T-18 to T-23, T-25, T-46). 3B git (3.13 to 3.16; T-26 to T-31). 3C push (3.10, T-24; 3.11 is BLOCKED: needs an APNs `.p8` key and a device). 3D app (3.17 to 3.21). The T-21 stop condition is checked at the end of 3A, before any app work.
- **Socket model (supersedes D-006, by a new D-n entry):** a phone socket no longer owns an agent. A socket is an authenticated client (identity, device). The gateway keeps one agent per project (3.4) and routes by project: `session/new` by its `cwd` (it must be a registered project's path or inside one), every other session method by `sessionId`. The caps count running project agents (`maxAgentsTotal`); a new limit, `maxConnectionsPerIdentity` (default 8), caps sockets.
- **Message ids:** several phones share one agent, so the gateway gives each forwarded request its own agent-side id, and maps the response back to the socket and id it came from. An agent-to-client request is sent to subscribers under a gateway id (see approvals).
- **`initialize`:** the gateway answers it. The result is the agent's capabilities, captured when the project's agent first starts, or the fixture before any agent has run, plus `_meta["agmente/gateway"] = { version, extensions: [...] }` so the app can detect the gateway. Toward the agent, the gateway sends its own `initialize`, with `clientCapabilities: {}` (no fs, no terminal: the phone has no project files). Agent requests other than `session/request_permission` get `-32601`.
- **Load and resume guard (3.7, FR-20, F-12, D-014):** the gateway knows which sessions are live in the current agent process. When the phone sends `session/load` or `session/resume` for a live session, the gateway answers it itself, with the cached `modes`. For the unmodified app, which then expects history, it replays the logged `session/update` events to that socket. After an agent restart, the gateway sends `session/load` once, with no turn running, and drops Bob's replayed history instead of logging it again (T-21). This also keeps the current app working until 3.18.
- **Event log (3.2, 3.5, D-007):** confirm `node:sqlite` (WAL, `synchronous=NORMAL`) in a D-n entry. Node 22.13 or later runs it without a flag, so `check.sh` raises its Node minimum from 22.12 to 22.13. Database: `<stateDir>/gateway.db` (new config key `stateDir`), tables:
  - `events(session_id, seq, ts, kind, message)`, one row per agent-to-client message for a session (updates, permission requests, the prompt response), plus gateway events (`turn_started`, `turn_ended`, `status`, `approval_answered`). `seq` starts at 1 per session and increases by 1.
  - `sessions(session_id, project_id, title, status, last_activity, created)`.
  - `reads(identity, session_id, last_seen_seq)`, for unread counts shared by all devices of one identity (FR-25).
  - `projects(id, name, path, default_mode, created)`.
  - `approvals(id, session_id, agent_request_id, tool_call, options, since, answered_by, outcome)`.
  - No retention limit yet; that is an open question.
- **Subscribe (3.6):** `_agmente/sessions/subscribe {sessionId, afterSeq}` registers the live listener first, then reads the replay. It sends `_agmente/event` notifications in `seq` order with no duplicates, and returns `{ headSeq }`.
- **Approvals (3.9, D-009):** each `session/request_permission` is logged and sent to subscribers as an event with a gateway `approvalId`. A phone answers with `_agmente/approvals/answer {approvalId, optionId | cancelled}`, or with a plain JSON-RPC response to the forwarded id (the current app). The first answer goes to the agent. A later one gets error "answered elsewhere" (as a method error, or as an `_agmente/notice` for a plain response). On timeout the gateway picks a reject option, or `cancelled`, never an allow. Timeout key `limits.approvalTimeoutSeconds` (NFR-10 default 43,200). A pending approval keeps the project running until it is answered or times out (D-020). Tests use short values.
- **Project lifecycle (3.4, 3.12, FR-45, D-015, D-016):** a `ProjectRunner` interface (`start(project) -> child`, `exec(project, argv) -> child`, `stop`). Two runners:
  - `podman`: container `agmente-<projectId>` (the lock), image from config, project folder and `HOME` volume mounted, `BOB_API_KEY` passed by name only.
  - `host`: for tests and local development only. It spawns the agent with `cwd` = the project and a per-project `HOME` under `stateDir`. Config refuses it unless `runner.allowHost` is true.
  The supervisor starts the agent on the first request, starts a replacement only after `exit`, stops after `idleSeconds` with no turn, approval or subscriber, and marks sessions `error` when the agent dies. T-46 uses a fake runner.
- **Registry (3.3, FR-17):** `_agmente/projects/create {name, path, defaultMode?}`. The path must be a directory whose `realpath` is inside a root (T-25). The gateway creates the project's `HOME` folder and writes `TRUST_FOLDER` for the project's path as the agent sees it (D-013).
- **Git (3B, FR-27 to FR-30, D-008):** every git command runs through `runner.exec` with the ARCHITECTURE 2.4 flags, a 5 s timeout and a 2 MiB cap. Paths come only from the last status, after `--`. Turn snapshots do not use `git add`: they use `git ls-files -z --cached --others --exclude-standard`, then `git hash-object --no-filters -w --stdin-paths`, then `git update-index --index-info` into a temporary `GIT_INDEX_FILE`, then `git write-tree`. With `--no-filters`, clean filters never run: T-27's marker then appears nowhere, inside or outside the container. That is stronger than the test asks, and the commands still run in the container (D-008). The deny-list for FR-30 is `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `id_rsa*`, `*secret*`, `.npmrc`, `.netrc`; a project can add to it, never remove from it. The file watcher (3.16) uses `fs.watch` with the 500 ms debounce and at most 2 per second.
- **New tests:** all in `gateway/test/` with the fake agent extended per 3.1 (slow turns, permission requests, refuse-while-running and rebuild-when-idle loads, persistence across restarts, and the F-21 shared-store mode). T-19 and T-30 also get bench scripts. T-27 needs Podman: it is skipped, never silently passed, where Podman is missing.
- **Revised 2026-11-06 by D-021 (gateway now in Go):** read `node:sqlite` below as "the Go SQLite driver chosen in 3.2"; the Node 22.13 minimum is not needed. Phase 3 gateway code is written in Go under `gateway/internal/`, and its tests are wire-level tests in `gateway/test/`.
- **Decision entries to add when approved:** sockets do not own agents (supersedes D-006); id remapping and gateway-answered `initialize`; load translation for the current app; the approvals answer method; `node:sqlite` confirmed (D-007); `ProjectRunner` and the dev-only host runner; turn snapshots with `--no-filters`; new config keys (`stateDir`, `runner`, `limits.maxConnectionsPerIdentity`, `limits.idleSeconds`, `limits.approvalTimeoutSeconds`).

## Phase 4 — IBM Bob live (needs licence and `BOB_API_KEY`)

Early probe (2026-11-06): 4.4 to 4.6 were run on Bob 2.0.7 and then 2.0.9 (now installed globally) with the key from `.env`, using `gateway/scripts/probe-bob.mjs`. 4.1 should pin `@ibm/bob@2.0.9` in the container. Findings that affect 3.4 and 4.3 (workspace = process cwd; on 2.0.9 a folder with no trust entry is trusted) are in RESULTS.md.

Goal: Bob runs safely behind the gateway. Closes T-32 to T-35.

- [ ] 4.1 Container image for a project: pinned `@ibm/bob` version, unprivileged user, read-only root where possible. Draft: `deploy/bob-project.Containerfile` (verify). Check: T-47 on the Linux host.
- [x] 4.2 Load `BOB_API_KEY` from a secrets file into the container environment only.
- [x] 4.3 At registration, write the project path as `TRUST_FOLDER` in the container's `$HOME/.bob/trustedFolders.json`, and start Bob with its process `cwd` set to the project (F-15, D-013). Never pass `--trust`. Do not rely on Bob's trust check to confine Bob. Check: T-33 passes in a registered project, and a `session/new` whose `cwd` is outside roots never reaches Bob (T-8). Q-6 is answered (RESULTS 2026-11-06).
- [x] 4.4 Probe `initialize` through the gateway. Check: T-32.
- [x] 4.5 Session lifecycle on Bob. Check: T-33.
- [x] 4.6 Answer Q-1 live. Check: T-34.
- [x] 4.7 App: handle `plan_update`, `plan_removed`, `session_info_update`, `usage_update` (FR-33).
- [x] 4.8 App: mode picker (FR-34).
- [x] 4.9 App: auth error (FR-35). Check: T-35.
- [x] 4.10 App: `session/delete` (FR-36).

Plan notes:

## Phase 5 — Images and HTML

Goal: the app shows agent images and HTML without new risk. Closes T-36 to T-39.

- [x] 5.1 Parse `image`, `resource` and `resource_link` content blocks in `SessionUpdateParsing` and the Codex path. (ACP only; Codex has no inbound image item, D-060.)
- [x] 5.2 Image view with ImageIO downsampling and MIME allow-list. Check: T-36.
- [x] 5.3 Gateway signed file URLs on a separate preview host. Check: T-37. (D-061 to D-064; 14 wire tests in `gateway/test/files.test.mjs`; Caddy routing of the files host is "verify" and not checked on the host.)
- [x] 5.4 HTML preview view. Check: T-38. (Passes; see RESULTS 2026-11-07. The test cannot tell the rule list from the content policy, each alone holds.)
- [x] 5.5 Answer Q-2 on Bob. Check: T-39.

Plan notes:

## Phase 6 — MCP and skills management

Goal: toggle MCP servers and tools, and manage skills, from the phone. Closes T-40 to T-45.

- [x] 6.1 App: client-owned HTTP MCP server list (FR-40). Answer Q-3. Check: T-42.
- [x] 6.2 Gateway: MCP config API (FR-41). Check: T-40.
- [ ] 6.3 Gateway: aggregating MCP proxy with per-tool toggles (FR-42). Check: T-41.
- [x] 6.4 Gateway: skills API (FR-43). Check: T-44. Answer Q-4: T-43.
- [ ] 6.5 App: skills editor with Face ID confirmation.
- [ ] 6.6 App: ACP elicitation forms (FR-44). Check: T-45.

Plan notes:

- Drafted 2026-11-07 in plan mode; no code changed. Read: SPEC FR-40 to FR-44, T-40 to T-45, Q-3, Q-4, F-16 to F-19, F-23, F-24, 6.2; ARCHITECTURE 1, 2.3, 2.5; DECISIONS D-009, D-013, D-015, D-024 to D-029, D-032, D-034, D-061 to D-064; RESULTS 2026-11-07 "Open questions on Bob 2.0.9". Code read: `gateway/internal/server/server.go` (routing and forward), `supervisor.go` (own load sends `mcpServers: []`, line 605), `projects.go`, `files.go`, `gateway/internal/config/config.go`; app `ServerViewModel.swift` (lines 986, 1353, 1451 send `mcpServers: []`), `Agmente/Security/KeychainStore.swift`, `Agmente/Fork/Gateway/`, `ACPClient/Sources/ACPClient/Gateway/GatewayClient.swift`.
- Q-3 and Q-4 are answered (RESULTS 2026-11-07; F-23, F-24). Task 6.1 "Answer Q-3" is done, and its remaining work is the app's list (FR-40). T-42 and T-43 have recorded results. Two gaps stay open: resume of a session with earlier turns was not tested (Q-3), and the Q-4 probe ran on the host runner only (probe P4).
- Finding F1: the gateway forwards phone `session/new`, `session/load` and `session/resume` params unchanged except `cwd` and `sessionId`. A phone-sent stdio entry in `mcpServers` would make Bob start a `command` inside the project container. The gateway must filter it (6A.1).
- Finding F2: the gateway's own load (D-032) sends `mcpServers: []`. F-23 says `[]` drops HTTP servers, so an idle stop or idle close silently removes the phone's servers. The gateway must keep each live session's list in memory and send that list in its own load.
- Finding F3: D-029 answers `session/resume` for a live session from the gateway's cache and never forwards it. A changed list therefore cannot reach Bob on a live session. It applies on the next `session/new` or after an idle reload (owner decision 3 covers the alternative).
- Finding F4: `alwaysAllow` in `mcp.json` skips the permission request for those tools. FR-41 as written would let the phone write a standing approval, which D-009 rules out. A repo's own `<project>/.bob/mcp.json` can already carry `alwaysAllow` (probe P3).
- Finding F5: the project folder and the home (`<stateDir>/homes/<id>`) are bind mounts at host paths on the host, Podman and Apple runners (D-025, D-079). The gateway can read and write config and skills there without `exec`: no repo code runs and no container starts. Whether a host write shows inside a running container is probe P4.
- Finding F6: Bob's MCP keys are per server (`disabled`, `alwaysAllow`, F-16). Per-tool toggles need the proxy (6.3).
- Owner decisions needed before 6A:
  1. One source of truth. FR-40 (phone-owned HTTP list, sent per session) and FR-41 (gateway-owned `mcp.json`) both exist. Recommended: the phone owns HTTP servers; FR-41 only sets `disabled` on servers already in `mcp.json`, and never writes an HTTP server to a host file. Writing `<project>/.bob/mcp.json` changes a git-tracked file, so it shows in `git/status`.
  2. Should MCP headers ever leave the device? Recommended: yes, over the existing TLS connection, only inside `session/new` or `session/resume`. The gateway keeps them in memory for the life of the session (F2) and never writes or logs them. A gateway restart forgets them, so the app resends on reopen. This holds only if probe P2 shows Bob does not persist them. If Bob does, the owner chooses between storing secrets in the container home and dropping authenticated HTTP servers.
  3. Is a per-tool toggle needed? Recommended: no. Build 6.2 (per-server `disabled`); mark 6.3 "deferred, not built" and T-41 "deferred" in RESULTS, not passed. The proxy would be a new listener the agent container can reach, on the tool-call path.
  4. Refuse `alwaysAllow` from the phone (recommended), so FR-41 offers only `disabled`.
  5. Refuse non-HTTP entries in phone `mcpServers` (recommended).
  6. Skill scope: project only (recommended first), or also `~/.bob/skills` in the home.
  7. Face ID: a UI gate only (recommended; see 6B.3), or a signature from a Secure Enclave key that the gateway checks (larger, needs a new D-n and a key registration method).
  8. Skill size cap below 70 KiB for T-44. Recommended 64 KiB, checked against Bob's own loader limit (probe P6).
  9. Elicitation: may the phone accept Bob's license (T-45), and may `--accept-license` leave `gateway/config.example.json` and `config.mac.example.json`? Both list it today.
- Probes before any code (host runner, disposable HOME, key values never printed, results in RESULTS as for Q-3 and Q-4):
  - P1 (T-40): `disabled: true` in `~/.bob/settings/mcp.json`: does a new session lack that server's tools? Does a session with earlier turns, resumed with a changed list, follow it? (the Q-3 gap)
  - P2: after an HTTP server with a marker header is used, grep the home (`bob.db`, logs) for the marker. Decision 2 depends on it.
  - P3: does a repo `<project>/.bob/mcp.json` with `alwaysAllow` skip the permission request, and does Bob merge it with a session `mcpServers` list?
  - P4: on Podman and on Apple, write a skill and flip `disabled` from the host; does Bob in a running container see it, and how fast?
  - P5 (6C): run `bob acp` without `--accept-license` with `clientCapabilities.elicitation.form`. Record the method name, params, answer shape and timeout. The ACP elicitation schema is not in `ACPClient/Docs` (verify against the ACP spec). Check whether tool inputs also use elicitation.
  - P6: Bob's skill size and frontmatter rules (F-17 gives the name rule only; verify).
- 6A gateway MCP config and skills (no app). Test first in each task: write the wire or unit test, see it fail, then change the code.
  - 6A.1 Guard and F2 fix. Wire (`gateway/test/mcp-guard.test.mjs`): a phone `session/new` with a stdio entry gets `-32602`; HTTP entries pass; the fake agent records the list it received (new test hook in `fake-agent.mjs`); after an idle stop the own load carries the kept list (fake runner). Go unit test for the filter. Code: `server.go` (route), `supervisor.go` (kept list), `idle.go`. Mutations: drop the filter, and send `[]` on own load. Each must fail.
  - 6A.2 List and disable (FR-41, T-40 wire part). New `gateway/internal/server/mcp.go` and `gateway/internal/mcpconf/`. Read both files through the host paths with the D-063 rules: realpath inside the project or home, no symlink in any component, 256 KiB cap, JSON only, never executed. `_agmente/mcp/set {projectId, name, disabled}` writes atomically (temp file in the same folder, `O_EXCL`, fsync, rename), mode 0600, and refuses a symlinked file. `alwaysAllow` is refused (decision 4). Rewriting drops comments (verify Bob accepts the output). Tests: `gateway/test/mcp.test.mjs`, Go unit tests for parse, write and symlink refusal. Mutations: accept `alwaysAllow`; follow a symlink.
  - 6A.3 Skills (FR-43, T-44). `_agmente/skills/list|put|delete {projectId, scope, name, content?}`. Name `^[a-z][a-z0-9-]{0,63}$` (F-17). Content is UTF-8 up to the cap in decision 8. Path `<project>/.bob/skills/<name>/SKILL.md` with the D-063 path rules, `O_NOFOLLOW` on each component, temp file and rename. Delete removes that one folder. Audit `skill_put` and `skill_deleted` with name, project and byte count only. Tests: `gateway/test/skills.test.mjs` with T-44's cases (`Bad Name`, `../x`, 65 characters, 70 KiB), Go unit tests for the name rules and the atomic write. Mutations: skip the name check; write through a symlink.
  - 6A.4 Live check. Run P1 and P4 on live Bob and record T-40 (new-session part) and the container path in RESULTS. T-42 and T-43 are already recorded; add a line that links them to this plan.
  - Stop 6A: report, the owner confirms decisions 1 to 5 and the probe results. Checks: `scripts/check.sh`, `npm test --prefix gateway`, `(cd gateway && go test ./...)`.
- 6B app MCP and skills screens (needs 6A.1 and decisions 1 to 2).
  - 6B.1 Headers in the Keychain. `Agmente/Security/MCPHeaderStore.swift` over `KeychainStore` (per server and entry, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Deleting a server deletes its headers (hook in `SessionStorage.deleteServer`). Tests in `AgmenteTests/MCPHeaderStoreTests.swift`: round trip, delete, and no header value in the Core Data file (the T-14 method).
  - 6B.2 MCP list (FR-40). `Agmente/Fork/MCP/MCPServersModel.swift` and `MCPServersView.swift`. Names, URLs and enabled flags are stored in a file with no secret; headers stay in 6B.1. The list is sent with `session/new` and `session/resume` at the three call sites (ServerViewModel 986, 1353, 1451), only when `mcpCapabilities.http` is set and the server is a gateway server. URLs follow the transport policy (`https`; `http` only under D-019). Tests in `AgmenteTests/ForkMCPTests.swift`: the payload holds only HTTP entries; headers appear in the payload and nowhere on disk.
  - 6B.3 Skills screen with Face ID. `Agmente/Fork/Skills/SkillsModel.swift`, `SkillsEditorView.swift`, `SkillBiometricGate.swift`. The gate calls `LAContext.evaluatePolicy` (`.deviceOwnerAuthenticationWithBiometrics`, or `.deviceOwnerAuthentication` if decision 7 keeps the passcode fallback). It stores nothing and needs no Keychain item. `NSFaceIDUsageDescription` is absent from `Agmente/Info.plist` and must be added (verify). The save request is sent only after the gate returns true. The gate is a UI control, not a server check: the gateway cannot see Face ID, and the audit line shows which device saved.
  - Tests: the model takes a `SkillSaveGate` protocol, so unit tests show no save without a true. A simulator UI test shows no request when the gate fails.
  - The simulator cannot test a real Face ID match, lockout, the passcode path on a locked device, enrolment changes, or Secure Enclave behaviour. It can set enrolment and matching from the Features menu (verify whether a headless trigger exists). A device run is needed for sign-off, and is marked BLOCKED until one is available.
  - Stop 6B: simulator checks and the report.
- 6C elicitation (FR-44, T-45). Needs P5 and decision 9.
  - 6C.1 Probe P5 first. Its shape goes into RESULTS and a new D-n entry before any code.
  - 6C.2 Gateway: advertise `elicitation.form` toward Bob (this replaces the `clientCapabilities: {}` rule in D-026 for this capability). Relay the agent's elicitation request to subscribers as an event, the same way as `session/request_permission` (D-031). The phone's answer goes back to the agent under the agent's id. The gateway never answers itself. A timeout sends decline or cancel, never accept. Wire test with the fake agent: relay, forwarded answer, timeout. Mutation: auto-accept, which must fail.
  - 6C.3 App: `Agmente/Fork/Elicitation/ElicitationFormView.swift` and a model. Only string, number, boolean and enum fields render; any other field is answered cancel. Unit tests for the parser; a UI test for the license form.
  - 6C.4 T-45 live: a test config without `--accept-license` (decision 9) and a disposable HOME. Record the result. The license is accepted only by the owner's tap.
  - Stop 6C.
- 6D is not planned. Build the 6.3 proxy only if decision 3 is overturned: it gets its own plan, a listener design and a D-n entry before code.
- New decisions to add when approved: D-084 MCP source and header handling (decisions 1, 2); D-085 config and skill files through the host mounts, no exec (F5); D-086 `alwaysAllow` refused and phone MCP entries limited to HTTP (decisions 4, 5); a note superseding part of D-032 (F2) and D-029 (F3); D-087 elicitation relay (6C).

Owner decisions, 2026-11-07:
- 1 (one source of truth): accepted as recommended.
- 2 (headers may leave the device): accepted as recommended, held in gateway memory only; depends on probe P2.
- 3 (no per-tool toggle): accepted; 6.3 deferred, T-41 deferred in RESULTS.
- 4 (alwaysAllow): OPEN. The owner asked to allow it because the environment is sandboxed. This conflicts with D-009 (the gateway never approves a tool call), so it is not built until the owner confirms the conflict in writing and a D-n entry records it. 6A.2 refuses alwaysAllow until then.
- 5 (non-HTTP entries from the phone): CHANGED by the owner, 2026-11-07. Stdio entries are allowed, with a warning in the app that the server must be configured. The command runs inside the project container as the project user (never on the host). The gateway never logs the entry's args or env values, and passes the env only to that container. Needs a new D-n entry (D-086 revised) before 6A.1 code.
- 6 (skill scope project only): accepted.
- 7 (Face ID as a UI gate): accepted.
- 8 (skill cap 64 KiB): accepted.
- 9 (elicitation licence, --accept-license left in example configs): accepted.
- Status 2026-11-07: 6A gateway done and recorded (RESULTS); 6B app side built and tested, wired; Face ID on a device BLOCKED; 6C.2 gateway relay in progress; 6C.3 app and 6C.4 live T-45 blocked on a non-internal Bob account (owner decision pending).

## Phase 7 — iPad and UX (accepted 2026-11-07, not started)

Source: `docs/design/ipad-ux-plan.md`, section 6. Each sub-phase is a stop: plan, owner approval, then build. It follows the Phase 8 integration, because it rewrites the screens that Phase 8 changes.
- [ ] 7.0 Baseline and harness (no UI change)
- [ ] 7.1 Tokens, status pill, accessibility quick wins (phone and pad)
- [ ] 7.2 Navigation model and shared state (no visible change on phone)
- [ ] 7.3 iPad shell: sidebar, content column, detail
- [ ] 7.4 Gateway status, "Needs you", connection and loading states (phone and pad)
- [ ] 7.5 Detail column: readable width, inspector, popovers, sheets
- [ ] 7.6 Transcript accessibility and Dynamic Type (UIKit rows)
- [ ] 7.7 Keyboard, pointer, menu bar, drag and drop
- [ ] 7.8 Stage Manager, resizing, scenes
- [ ] 7.9 Final QA, documentation, results

## Phase 8 — usage, running work, remote connector (2026-11-07)

Branches merged into `feat/integration-2026-11-07` (the merge commit is given after "merge"). Each box stays open until the full checks pass on the integration branch (I2: wire suite on a quiet machine, `xcodebuild test`, `scripts/check.sh`).
- [x] A1 Usage per session on the sessions index, and project agent state (D-092). Branch `feat/a1-gateway-usage` at 162bc514; merge 780c625. FR-24 (`lifecycle.test.mjs`) passed in the final quiet-machine check (2026-11-07 I2).
- [x] F1 Add-project review: seven fixes to folder creation (D-091, D-099). Branch `feat/f1-add-project-review` at 8c8a13ed; merge 5090b76.
- [x] G1 Public exposure: connector Caddy site, launchd templates, config example (D-098). Branch `feat/g1-deploy` at 5973a573; merge 7b8f423. Integration fixes: seven paths, `:8443` to `8788`, the Caddy import. Live Caddy not run.
- [x] D1 Connector gateway core: listener, OAuth, pairing, grants, limits (D-095). Branch `feat/d1-connector-core` at a6f3b8d4; merge 57fa65a. Its own check passed (277 of 277 wire tests).
- [x] B1 App usage UI: header chip, usage sheet, home row bar (D-093). Branch `feat/b1-app-usage` at 0b55cc74; merge 4344274.
- [x] B2 App running-now strip, derived from the event log (D-094). Branch `feat/b2-app-running` at 9b9b9c2f; merge 78e147f. Its app tests ran and passed in the final xcodebuild run.
- [x] E1 Connector phone app: approve, deny and revoke (D-097). Branch `feat/e1-connector-app` at 210fdb40; merge fb357f6. Its app tests ran and passed in the final xcodebuild run.
- [x] D2 Connector tools and lean context summary (D-096). Branch `feat/d2-connector-tools` at c2781f5; merge 15fc77e. Final checks: check.sh exit 0 (node wire 295 of 295), the four connector wire files 30 of 30 by name, xcodebuild test succeeded (330 XCTest tests, 0 failures).

## Backlog (set aside 2026-11-07)

Owner decision, 2026-11-07: Linux host work is moved to the backlog. Not started; re-open when a Linux host is available.
- [ ] 1.11 Deploy on the host: Caddy with `deploy/Caddyfile`, gateway with `deploy/agmente-gateway.service` (Linux).
- [ ] 1.12 Point the unmodified app at the gateway on the Linux host (needs 1.11).
- [ ] 4.1 Bob project container on Linux, T-47 cold start on the Linux host (`deploy/bob-project.Containerfile`, verify).

Set aside, not investigated (owner decision, 2026-11-07): the first concurrent Podman run stalled after N=2 with idle containers (RESULTS 2026-11-07, concurrency entry). Cause unknown.

Accepted, not met (owner decision, 2026-11-07): NFR-15 cold start at 3 s p95 under the Apple runner at concurrency. Single-project load meets the target; concurrent load does not (D-083).
