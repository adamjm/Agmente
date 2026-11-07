# Decisions

Append only. To change a decision, add a new entry that supersedes the old one. Do not edit old entries.

## D-001 Gateway in Node.js 22 with one dependency, `ws`
- **Date:** 2026-11-05
- **Decision:** Write the gateway in plain JavaScript (ES modules) for Node.js 22 LTS. Use the built-in test runner (`node --test`). Use `ws` as the only runtime dependency, pinned to an exact version.
- **Reason:** Bob ships as an npm package, so Node is already on the host. Node has no built-in WebSocket server. `ws` supports `noServer` mode, so the gateway can authenticate on the HTTP `upgrade` event before any WebSocket exists, and it supports `maxPayload`. Plain JavaScript avoids a build step in the check gate.

## D-002 ACP on the wire between phone and gateway
- **Date:** 2026-11-05
- **Decision:** The phone speaks ACP to the gateway. The gateway proxies ACP and adds methods named `_agmente/*`.
- **Reason:** The fork keeps its tested ACP client code. ACP reserves names that start with `_` for extensions.

## D-003 Mutual TLS at Caddy plus hashed bearer tokens at the gateway
- **Date:** 2026-11-05
- **Decision:** Caddy requires a client certificate. The gateway also requires a bearer token, stored in its config as a SHA-256 hash and compared in constant time.
- **Reason:** Two independent controls. A TLS misconfiguration alone does not open the agent. The config file holds no secret (NFR-14). The current app already sends `Authorization: Bearer`, so phase 1 works with the unmodified app.

## D-004 Phase order differs from the review roadmap
- **Date:** 2026-11-05
- **Decision:** Phases are 0 scaffold, 1 gateway, 2 iOS hardening, 3 sessions and git, 4 Bob live, 5 rendering, 6 management. In the review, Bob came before sessions.
- **Reason:** Phases without credentials come first. Phase 3 runs against a fake agent that copies Bob's captured capabilities and behaviour (F-11, F-12). Phase 4 then confirms the behaviour on real Bob.

## D-005 Gateway in a `gateway/` folder of the private fork
- **Date:** 2026-11-05
- **Decision:** Keep the gateway in `gateway/` in the fork repository, not in a separate repository. Put new app code in new files under `Agmente/Fork/` and `Agmente/Security/`.
- **Reason:** The fork is not going upstream. One repository keeps app and gateway changes in one commit. Upstream never touches these folders, so merges stay small.

## D-006 Phase 1 keeps one agent process per connection
- **Date:** 2026-11-05
- **Decision:** In phase 1 the gateway spawns one agent per authenticated socket and kills it when the socket closes.
- **Reason:** It matches `stdio-to-ws` without `--persist`, so phase 1 is a safe drop-in. Phase 3 task 3.4 supersedes this with one agent per project.

## D-007 Event log in SQLite through `node:sqlite` (proposed)
- **Date:** 2026-11-05
- **Decision:** Proposed: store the event log in SQLite with WAL, through the built-in `node:sqlite` module. Confirm or supersede in phase 3 task 3.2.
- **Reason:** No new dependency. Risk: `node:sqlite` prints an experimental warning in Node 22.23.4 (seen in the scaffold build). Fallback: `better-sqlite3`.

## D-008 Bob and git run inside the project container
- **Date:** 2026-11-05
- **Decision:** Each project runs in its own container as an unprivileged user. The gateway runs Bob and every git command there, never in its own process.
- **Reason:** Repository config can make git run programs (F-20), and Bob can write that config. Inside the container, such a program reaches only what Bob can already reach.

## D-009 The gateway never approves a tool call
- **Date:** 2026-11-05
- **Decision:** No gateway code path answers `session/request_permission` with an allow option. On timeout it selects a reject option, or answers `cancelled` if there is none. Bob never runs with `--auto-approve`.
- **Reason:** The phone's approval is the last control between the internet and a shell.

## D-010 The overlay replaces `CLAUDE.md` and keeps the upstream `README.md`
- **Date:** 2026-11-05
- **Decision:** The overlay ships a new `CLAUDE.md` and a new `FORK.md`. It does not overwrite `README.md`.
- **Reason:** The new `CLAUDE.md` must drive the phased workflow. It still points to `Agents.md` for iOS conventions, which the old file did. Keeping `README.md` avoids a merge conflict on every upstream change to it.

## D-011 Track the shared `.claude/` files in git
- **Date:** 2026-11-05
- **Decision:** Change the upstream `.gitignore` line `.claude/` to `.claude/*`, `!.claude/settings.json` and `!.claude/commands/` (PLAN task 0.2). Keep `.claude/settings.local.json` ignored.
- **Reason:** Upstream ignores the whole `.claude/` folder (`.gitignore` line 16 at `87f224e`). Without this change, `/next` and the permission rules never reach git, and a fresh clone loses them. Tested on the clone: the change tracks exactly `settings.json` and `commands/next.md`. A negation cannot re-include files under an ignored directory, so the folder pattern must become `.claude/*`.

## D-012 The agent env test allows `__CF_USER_TEXT_ENCODING` on macOS only
- **Date:** 2026-11-06
- **Decision:** In `gateway/test/agent.test.mjs`, the allow-list test accepts exactly one extra name, `__CF_USER_TEXT_ENCODING`, and only when `process.platform` is `darwin`. All other names must still be `PATH`. The gateway code does not change. Approved by the owner on 2026-11-06.
- **Reason:** macOS adds this variable (a uid and text-encoding value, no secret) to every child process, even under `env -i` (RESULTS 2026-11-06). The gateway does not pass it, so it is not a leak. On Linux, the deployment target, the test stays as strict as before.

## D-013 Bob's folder trust is not a folder control; the gateway confines Bob
- **Date:** 2026-11-06
- **Decision:** Revise F-15, Q-6 and PLAN 4.3 for Bob 2.0.9. The gateway does not rely on Bob's trust check. Bob stays confined by three controls: the gateway `cwd` guard (FR-6), starting Bob with its process `cwd` set to the project folder (task 3.4), and the project container (D-008). At registration the gateway still writes the project path as `TRUST_FOLDER` in the container's `$HOME/.bob/trustedFolders.json`, so projects keep working if Bob brings back the 2.0.7 default. It never passes `--trust`. Approved by the owner on 2026-11-06.
- **Reason:** Live probes and package source (RESULTS 2026-11-06) show three things. Bob checks trust against its process working directory, not `session/new` `cwd`. On 2.0.9 a folder with no trust entry is trusted. A `DONT_TRUST` entry matches only its exact path, so a deny-by-default list is not possible.

## D-014 Revise F-12 and record F-21: never two Bob processes on one task store
- **Date:** 2026-11-06
- **Decision:** F-12 now records what Bob does: `session/load` and `session/resume` are refused during a turn in the same process, and rebuild the session when it is idle. New finding F-21: two Bob processes that share a `HOME` can open the same session, and a completed turn can vanish from the stored history with no error. Q-1 and Q-5 are answered. FR-20 stays, with a new reason: an idle load rebuilds the session and replays history into the event log. Task 3.1 and T-21 now model the real behaviour. The gateway must never let two Bob processes use one task store. The design for that is a separate decision. Approved by the owner on 2026-11-06.
- **Reason:** Live probes on Bob 2.0.7 and 2.0.9 (RESULTS 2026-11-06) contradict the old F-12 (a load cancels the turn), and showed silent data loss with two processes (`gateway/scripts/probe-bob-races.mjs`, R2 and R3).

## D-015 One Bob process per task store, enforced in layers
- **Date:** 2026-11-06
- **Decision:** The gateway never lets two Bob processes use one task store (one `HOME/.bob/db/bob.db`). Layers:
  1. Each project runs in its own container with its own `HOME`, so each project has its own `bob.db`, apart from other projects and from the owner's own Bob (D-008).
  2. One supervisor per project (task 3.4). All sockets for a project share one Bob process. A replacement starts only after the old process has emitted `exit`, never just after a signal. FR-20 stops reloads of live sessions.
  3. An exclusive lock on the project's `HOME` before spawn, as a backstop against a second gateway or an orphaned Bob after a crash. With containers, a fixed container name `agmente-<projectId>` is the lock (verify: Podman refuses a second container with the same name).
  4. The gateway event log (FR-18) is the transcript the phone shows. Bob's replay is not the source of truth.
  Interim, until task 3.4: the gateway frees an agent slot on the agent's `exit`, not on socket close. `config.example.json` sets `maxAgentsPerIdentity` and `maxAgentsTotal` to 1. NFR-4 (4 and 16) stays the target for phase 3, when caps count per project and not per socket. Approved by the owner on 2026-11-06.
- **Reason:** F-21 shows silent loss of a completed turn when two Bob processes open one session. Bob keeps all sessions of a `HOME` in one SQLite file, and the phase 1 gateway can run two Bob processes: one per socket (D-006), plus a 2 s overlap after a socket closes while the old Bob handles `SIGTERM`. The interim changes close both paths in phase 1. They cost one phone connection at a time; a second gets 429.

## D-016 Start a project's container on demand and stop it when idle
- **Date:** 2026-11-06
- **Decision:** Registering a project only records it, creates its `HOME` volume and writes its trust entry (PLAN 4.3). The first request for the project starts its container `agmente-<projectId>` and Bob (FR-45). When every session in the project has been idle for the idle time (NFR-10 default 30 min), with no running turn, no pending approval and no subscriber, the gateway stops Bob, then the container, and waits for it to exit. A request during the stop waits, then starts a fresh container. If a container with the project's name is already running when the gateway starts (after a crash), the gateway stops it and waits for it to exit before starting its own. It never starts a second one (D-015). New target NFR-15: a cold start loads an existing session in at most 3 s p95 on the host. Approved by the owner on 2026-11-06.
- **Reason:** Idle projects then use no memory, and Bob's start-up is short. On a Mac Podman VM a fresh container loaded an existing session in 1.5 s median, 1.6 s max, against 1.4 s for Bob on the host (RESULTS 2026-11-06). The 3 s target leaves room for a larger history and a slower host. It must be confirmed on the Linux host (T-47). Cost: the first request after an idle period waits about 1.5 s, and a pending approval keeps a container running for up to 12 h (NFR-10).

## D-017 Hard fork: no upstream merges
- **Date:** 2026-11-06
- **Decision:** This fork never merges upstream changes in and never sends changes upstream. This supersedes the merge reasoning in D-005 and D-010. The gateway still lives in `gateway/`. New feature code still goes under `Agmente/Fork/` and `Agmente/Security/`, but upstream files may be changed freely when that is the cleaner design. R-3 is closed. For PLAN 2.5: extract the duplicated WebSocket transport into one local package, `AgmenteTransport`, now. Stated by the owner on 2026-11-06.
- **Reason:** The rule to keep upstream edits small existed only to keep hand merges cheap (D-005). With no merges, one transport means 2.4, 2.6 and 2.7 change and test one file instead of two copies.

## D-018 The app connects only to hosted `wss://` endpoints
- **Date:** 2026-11-06
- **Decision:** FR-11 now refuses `ws://` for every host. Tailscale is not a supported way to reach the gateway, and neither are other private-network paths. T-15 is revised to match. Whether Debug builds keep `ws://` for loopback (simulator testing) is still open. Stated by the owner on 2026-11-06.
- **Reason:** The owner reaches Bob only through the hosted gateway behind Caddy with TLS and a client certificate (D-003). Plaintext on a private network was a convenience, and it widened what the app would send a token over.

## D-019 `ws://` for Debug loopback and for servers marked "Local only"
- **Date:** 2026-11-06
- **Decision:** Narrows D-018, which made the app `wss://` only. `ws://` is allowed in two cases. (a) Debug builds, to loopback hosts, so the simulator can reach a gateway on the Mac. (b) A per-server "Local only" setting, off by default, which allows `ws://` to loopback, `.local` and RFC 1918 hosts in any build. A "Local only" server refuses every non-local host, even over `wss`, so a misconfigured entry cannot send its token to the internet. The form warns that the token travels unencrypted. Tailscale (`100.64/10`) stays unsupported. Stated by the owner on 2026-11-06. The owner's words were "local only"; that this covers RFC 1918 and `.local` as well as loopback is an interpretation, confirmed in plan approval.
- **Reason:** Local testing and home-network use without a TLS proxy. The scope is explicit per server, so the default stays hosted `wss` only.

## D-020 A pending approval keeps the project running until the approval timeout
- **Date:** 2026-11-06
- **Decision:** While a session has a pending `session/request_permission`, the project's agent and container stay running, up to `limits.approvalTimeoutSeconds` (NFR-10 default 12 h). The idle stop (FR-45) waits until the approval is answered or times out (then rejected, D-009). This confirms what D-016 said. The Phase 3 plan is approved. Stated by the owner on 2026-11-06.
- **Reason:** Stopping Bob with a permission request open would end the turn the phone was asked to approve. The owner accepts the cost: an idle project with a pending approval uses one running agent (about 310 MB measured for an idle `bob acp` 2.0.9 on this Mac) for up to 12 h.

## D-021 The gateway moves to Go; the wire-level suite is the contract
- **Date:** 2026-11-06
- **Decision:** Supersedes D-001. The gateway is a Go program (`gateway/cmd/agmente-gateway`, packages under `gateway/internal/`), built to `gateway/bin/agmente-gateway`, Go 1.24 or later. Its one runtime dependency is `github.com/coder/websocket` v1.8.15, pinned in `go.mod` and hashed in `go.sum`. The gateway tests are wire-level: they start the gateway as a separate process from `AGMENTE_GATEWAY_CMD`, write its config file, and talk to it only over HTTP and WebSocket, its CLI, and its audit log on stderr. No test imports gateway code. The suite stays in Node (`node --test`, `ws` as the test client, the fake agent), because Bob is a Node program and the fake agent copies Bob. `scripts/check.sh` builds the Go gateway, runs `go vet` and its unit tests, and runs the wire suite against both gateways. The Node gateway (`gateway/src/`) stays as the reference until the owner approves removing it. The token tool is now `agmente-gateway new-token <device-id> <identity>`; `gateway/scripts/new-token.mjs` stays until then. D-007 (`node:sqlite`) no longer applies: task 3.2 chooses a SQLite driver for Go in a new entry. Stated by the owner on 2026-11-06 ("rewrite the tests as wire-level checks, test node, then migrate it to golang now").
- **Reason:** The owner asked for a smaller, more robust daemon. Measured on this Mac (RESULTS 2026-11-06): idle RSS 12.9 MB for Go against 58 MB for Node; the same 53 wire tests pass on both; round-trip overhead p95 0.02 ms (Go) against 0.13 ms (Node). Go gives one static binary, checks types at compile time, and has mature SQLite drivers for phase 3. `coder/websocket` was chosen over `gorilla/websocket` because it is maintained (last release June 2026; gorilla's last is June 2024), has no dependencies of its own, allows concurrent writes, and enforces the read limit by closing with 1009 without buffering past the limit.
- **Differences from the Node gateway, by design:**
  1. Phone messages are re-serialized by an order-preserving encoder (`internal/jsonv`): key order kept, the last value of a duplicate key wins (as `JSON.parse`), and number literals are kept as written, so a large integer id is not rounded.
  2. Config strings must be JSON strings. Node's regex checks coerced a number such as `"id": 123` to text and accepted it.
  3. After the agent exits, the Go gateway waits (up to 1 s) until it has forwarded the agent's last output, then closes the socket. The Node gateway passes the same test without an explicit wait. In both, the slot is released only after the exit.
  4. The HTTP server reads headers within 10 s and caps them at 16 KiB.
  5. Agent stdout backpressure is a blocking WebSocket write, with no audit line. Phone-to-agent backpressure writes a `backpressure` audit line in both gateways.
- **Found by the wire suite, fixed in both gateways:** Node's `readline` ends a line at U+2028 and U+2029, and `JSON.stringify` leaves them raw. So one phone message could reach a `readline`-based agent as two lines, which breaks the "one line per message" rule of FR-7. The Node gateway now escapes both; the Go encoder always did. Whether Bob's own stdin reader splits on U+2028 is not verified.

## D-022 Remove the Node gateway
- **Date:** 2026-11-06
- **Decision:** Completes D-021. `gateway/src/` and `gateway/scripts/new-token.mjs` are deleted; the Go binary is the only gateway. The wire suite's default target is `gateway/bin/agmente-gateway`, and `scripts/check.sh` runs the suite once, against it. The Bob probes (`gateway/scripts/probe-bob.mjs`, `probe-bob-races.mjs`) now start the gateway as a process through the test harness (`spawnGateway`) instead of loading it in-process. Each gives the gateway its own working directory and a disposable `HOME`, which the agent inherits through `envPassthrough`. The race probe wraps Bob in `/bin/sh -c 'exec "$@" 2>>file'` in its own config to keep Bob's stderr, which the gateway discards. Node stays a dependency of the test suite, the fake agent and Bob. Stated by the owner on 2026-11-06 ("Yes, remove it").
- **Reason:** The Go gateway passed the same 53 wire tests and the check gate (RESULTS 2026-11-06). Two implementations would have to be kept in step for phase 3.

## D-023 Event log in SQLite through `modernc.org/sqlite`
- **Date:** 2026-11-06
- **Decision:** Supersedes D-007. The gateway's database is SQLite through `modernc.org/sqlite` v1.61.1, a pure-Go translation of SQLite (no cgo), pinned in `go.mod` and hashed in `go.sum`. It is the gateway's second runtime dependency. It brings nine indirect modules into the build (`modernc.org/libc`, `mathutil` and `memory`, `golang.org/x/sys`, `google/uuid`, `dustin/go-humanize`, `mattn/go-isatty`, `ncruces/go-strftime`, `remyoudompheng/bigfft`). The database is `<stateDir>/gateway.db`, in a folder created with mode 0700. Settings: `journal_mode=WAL`, `synchronous=NORMAL`, `busy_timeout=5000`, `foreign_keys=ON`, `BEGIN IMMEDIATE` for transactions, and one connection, so the gateway serializes its own writes and `seq` assignment cannot race. The schema follows the phase 3 plan notes (`projects`, `sessions`, `events`, `reads`, `approvals`) and its version is kept in `PRAGMA user_version`. The gateway refuses a database whose schema is newer than its own. The driver needs Go 1.26, so the gateway's Go minimum rises from 1.24 (D-021) to 1.26. Chosen by the owner on 2026-11-06 from four options: `modernc.org/sqlite`, `ncruces/go-sqlite3` (pre-1.0), `mattn/go-sqlite3` (cgo) and plain files without SQLite.
- **Reason:** It keeps the gateway one binary with no C toolchain, and it follows upstream SQLite releases. WAL keeps a committed event across a gateway crash or SIGKILL (NFR-7) without crash-safety code of our own. Measured on this Mac (RESULTS 2026-11-06): 10,000 events, one commit each, written in 0.55 s and read back in 26 ms (NFR-6 allows 1 s); after SIGKILL, all 500 acknowledged events were present with no gap. Cost: a probe binary with only the store and driver is 8.8 MB, so the gateway grows from 9.8 MB to roughly 17 MB (estimate). With `synchronous=NORMAL`, the last transactions before a power loss (not a process crash) can roll back; T-20 tests SIGKILL.

## D-024 Project registry: gateway-answered `_agmente/*` methods, `stateDir`, project homes
- **Date:** 2026-11-06
- **Decision:** PLAN 3.3. The gateway answers every `_agmente/*` request itself, after the message guard (FR-6, FR-7) and before anything is forwarded; none reaches the agent. An unknown `_agmente/*` method gets `-32601`, and an `_agmente/*` notification is ignored. Two methods exist so far:
  - `_agmente/projects/create {name, path, defaultMode?}` returns `{project}`. `name` is trimmed, 1 to 100 characters, with no control characters. `defaultMode` is optional and must match `^[a-z][a-z0-9_-]{0,31}$`. `path` must be absolute and exist, must be a directory, and its realpath must be a root or inside one (T-25). The realpath is stored, and a second project on the same realpath is refused with `data.projectId`. The id is 12 random lowercase hex characters, so `agmente-<projectId>` is a valid container name (D-015).
  - `_agmente/projects/list` returns `{projects: [{id, name, path, defaultMode}]}`, oldest first, with `defaultMode` null when unset.
  - Creating a project makes its `HOME`, `<stateDir>/homes/<projectId>` (mode 0700), and writes `.bob/trustedFolders.json` (mode 0600) with `TRUST_FOLDER` for the project path as the agent sees it (D-013). With the host runner that is the host path; task 3.4 decides the path and `HOME` for the podman runner (`/work` and a volume).
  - New required config key `stateDir`: an absolute path other than `/`. It holds `gateway.db` (D-023) and the project homes. The gateway exits non-zero when it cannot open the database there. The audit log gets one new field, `project` (a project id), used by the `project_created` event.
  - Any authenticated identity may create and list projects, because one person owns the gateway (SPEC 2, FR-25).
- **Reason:** SPEC 6.2 and the phase 3 plan notes. Answering `_agmente/*` in the gateway keeps the agent's input to ACP only. Writing the trust entry at registration follows D-013. A random id keeps project names out of container names and paths.

## D-025 One agent per project; sockets own no agent
- **Date:** 2026-11-06
- **Decision:** Supersedes D-006, and replaces the interim release rule of D-015 (the slot is now a project agent's, not a socket's). PLAN 3.4, as planned in the approved phase 3 notes.
  - **Sockets.** A socket is an authenticated client. Opening one starts nothing. The gateway caps open sockets per identity with the new limit `maxConnectionsPerIdentity` (default 8; HTTP 429 before upgrade). FR-5, NFR-4 and T-7 are revised to match. `maxAgentsPerIdentity` is accepted, so old configs still load, but it is no longer used. Everything sent to a socket goes through one queue per socket. Above 2 × `maxMessageBytes` + 1 MiB queued, that socket is closed with 1013 "client too slow", so a slow phone never blocks a shared agent. Closing a socket leaves its project's agent running.
  - **Projects.** One agent per project. It starts on the first request routed to the project; all sockets and identities share it. A request whose start would exceed `maxAgentsTotal` (running project agents) gets JSON-RPC `-32000` "agent capacity reached".
  - **Routing**, after the guard: by `params.sessionId` when the gateway has recorded that session (from a successful `session/new`, `session/load` or `session/resume`); else by `params.cwd` (the deepest registered project that is the cwd or contains it); else the project this socket used last. A `session/new` without a cwd, an unknown session, a cwd in no registered project, and a session sent with another project's cwd are refused with `-32602`. A socket attaches to a session when it sends a message for it, or when its `session/new`, `session/load` or `session/resume` succeeds. Session notifications go to the attached sockets; notifications without a session go to every socket that used the project.
  - **Exit.** When the agent exits, pending requests get `-32000` "agent exited", sockets stay open, and the sessions are no longer live. The next request starts a new agent, but only after the old process has exited. An agent line over `maxMessageBytes` stops the agent. Gateway shutdown stops every agent and waits for each to exit, up to the kill grace plus 1 s.
  - **Runners (`runner` config key).** `host` runs the agent on the gateway host with its working directory set to the project folder (D-013) and `HOME` set to `<stateDir>/homes/<projectId>`. Config refuses it unless `runner.allowHost` is true; it is for tests and development. Its lock is an exclusive `flock` on `<home>/.agmente.lock`, taken without waiting. The agent inherits the locked file, so the lock lasts while the agent lives, even after a gateway crash. `podman` runs `podman run --rm -i --name agmente-<projectId> --pull=never --init` with the project folder and the project home mounted at their host paths, so ACP paths need no translation. It also passes `-w <project>`, `-e HOME=<home>`, and `-e NAME` for each allow-listed variable, by name only. The container name is the lock (D-015). The podman runner is unit-tested for its arguments but not yet run live (verify in PLAN 4.1). Both runners always set `HOME`; the gateway's own `HOME` never reaches an agent.
  - **Audit.** `connect` no longer has a pid. New events: `agent_start` (project, pid), `agent_capacity`, `route_refused`, `response_dropped` and `client_slow`. `agent_exit` and `agent_error` now carry the project.
  - Approved with the phase 3 plan by the owner on 2026-11-06; the owner asked for task 3.4 on 2026-11-06.
- **Reason:** FR-16 and FR-45. F-21 showed that two Bob processes on one task store silently lose a completed turn. With one agent per project and a lock that the agent itself holds, there is only ever one process per store. Measured through the new gateway on live Bob 2.0.9 (RESULTS 2026-11-06): a second socket's load and prompt during a turn reach the same Bob and are refused (`-32600`); one Bob process ran; the stored history kept every completed prompt.

## D-026 The gateway answers `initialize`, remaps ids, and relays only permission requests
- **Date:** 2026-11-06
- **Decision:** PLAN 3.4, from the approved phase 3 notes.
  - **`initialize`.** A phone's `initialize` never reaches an agent. The gateway answers with the agent's last captured initialize result (`<stateDir>/agent-initialize.json`), or with Bob 2.0.9's result (F-11, embedded) before any agent has run, plus `_meta["agmente/gateway"] = {version, extensions}`. Today that is `{version: "0.3.0-dev", extensions: ["projects"]}`, so the app can detect the gateway. Toward each agent, the gateway sends its own `initialize` with `clientCapabilities: {}`, because the phone has no project files or terminal to offer. The agent must answer within 60 s, or the start fails.
  - **Ids.** Each forwarded request gets an agent-side number from the project's counter. The response is mapped back to the socket and the id it came from, so sockets that use the same ids never see each other's responses.
  - **Agent requests.** `session/request_permission` goes to the sockets attached to its session under a gateway id `agmente-perm-<n>`. The first answer goes to the agent with the agent's id; a later answer, or a response to an id the gateway never sent, is dropped and audited (`response_dropped`). If no socket is attached, the request stays pending; task 3.9 adds the queue, the log and the timeout. The gateway never answers a permission request itself (D-009). Every other agent request (`fs/*`, `terminal/*` and any other method) gets `-32601` from the gateway.
- **Reason:** Several phones share one agent (D-025), so the gateway must own the id space and the agent's handshake. Refusing `fs` and `terminal` keeps the agent from reading the phone or asking it to run anything.

## D-027 What the event log holds, and when it is written
- **Date:** 2026-11-06
- **Decision:** PLAN 3.5 (FR-18), from the phase 3 plan notes. The gateway writes these messages for a session to `events` in `gateway.db` (D-023). `seq` starts at 1 per session and increases by 1.
  - `update`: every agent `session/update` notification, as phones receive it.
  - `notification`: any other agent notification that names a `sessionId`.
  - `permission_request`: `session/request_permission`, under its gateway id (D-026), as phones receive it.
  - `turn_started`: a gateway event, `{"method":"_agmente/turn_started","params":{sessionId, prompt}}`, written when a phone's `session/prompt` is forwarded and before the agent sees it. It holds the prompt's content blocks, because Bob does not echo the user's message during a turn, so other devices learn it only from this event.
  - `turn_ended`: a gateway event, `{"method":"_agmente/turn_ended","params":{sessionId, stopReason | error}}`, written for the prompt's response. That covers an agent refusal and "agent exited", when the agent dies mid-turn.
  - Not logged: agent notifications without a `sessionId`, and responses to other requests.
  - Each event is committed before the message goes to any socket, so a phone never sees an event that is not in the log (NFR-7). If the write fails, the gateway audits `store_error` and still forwards the message.
  - Bob's replay after a `session/load` or `session/resume` is still logged as updates. Task 3.7 stops that (FR-20, T-21).
  - The wire tests read `gateway.db` read-only through `node:sqlite`, so the test suite needs Node 22.13 or later (`scripts/check.sh`, `package.json` engines).
- **Reason:** FR-18 and FR-19 replay from this log, so it must hold the user's prompt and how each turn ended, not only the agent's updates. Writing before forwarding makes "received by a phone" imply "logged". T-20 shows that this holds across a SIGKILL.

## D-028 Subscribe and replay: order, delivery and backpressure
- **Date:** 2026-11-06
- **Decision:** PLAN 3.6 (FR-19, NFR-6), from the phase 3 plan notes.
  - **Method.** `_agmente/sessions/subscribe {sessionId, afterSeq}`. `sessionId` must be a session the gateway has recorded; otherwise `-32602` "unknown session". `afterSeq` is a non-negative JSON integer and may be left out (0); anything else gets `-32602`. An `afterSeq` at or past the head replays nothing. A subscribe notification (no id) is ignored, as other `_agmente/*` notifications are (D-024). Subscribing starts no agent. Any authenticated identity may subscribe (SPEC 2, FR-25).
  - **Order on the socket.** First the response `{headSeq}`, then `_agmente/event {sessionId, seq, message}` for each logged event with `afterSeq < seq ≤ headSeq`, then live events with `seq > headSeq`. `message` is the logged message exactly as stored (D-027). Each seq arrives once and in order.
  - **How.** One gateway lock covers logging an event and delivering it. A subscribe registers its listener and reads `headSeq` under that lock, so each event is either at or below the head (read by the replay) or above it (delivered live), never both and never neither. Live events that arrive during the replay wait in the subscription and are sent after it. If they exceed the socket's queue limit, the socket is closed with 1013, as for any slow phone (D-025). The replay reads the log in pages of 512 events and releases the store's one connection before it sends a page, so a slow phone never holds up the event log. It sends with backpressure: it waits while the socket's queue is over half its byte or message limit, so a long replay neither closes the phone with 1013 nor crowds out live messages. If a page cannot be read, the socket is closed with 1011, so a gap is never left open.
  - **One subscription per socket and session.** A second subscribe for the same session on the same socket replaces the first: its replay stops, and live events then come once, from the new subscription. Closing the socket drops its subscriptions. There is no unsubscribe method yet. Subscriptions do not depend on the agent: they survive an agent exit and restart.
  - **No plain copies.** A socket subscribed to a session receives that session's agent notifications and permission requests only as `_agmente/event`, not also as plain messages. Sockets that are attached but not subscribed (the current app) still get plain messages, as before. Responses to a socket's own requests are not events and are sent as before. A subscriber answers a permission request with a plain JSON-RPC response to the gateway id inside the event's message (D-026).
  - **Store errors.** If an event cannot be logged (`store_error`, D-027), plain sockets still get the message, but subscribers do not, because it has no seq.
  - `_meta["agmente/gateway"].extensions` is now `["projects", "sessions"]`, so the app can detect subscribe.
  - **Size.** An event wraps a message of up to `maxMessageBytes` in about 100 bytes plus the session id. An agent line within 100 bytes of the cap can therefore produce an event slightly over 16 MiB, which the app (FR-12) would refuse. Not handled yet; agent lines that size are not expected.
- **Reason:** FR-19 and T-18 need replay then live with no gap and no duplicate. Registering under the same lock that orders the writes is the simplest rule that gives both. The response comes first, matching SPEC 6.2, so a phone knows the head before the replay starts. Paging and backpressure keep NFR-6 (T-19: 10,000 events) from tripping the slow-phone close, which the 4,096-message socket queue would otherwise do. Leaving out plain copies keeps a subscribed phone from seeing each update twice.

## D-029 Load and resume guard: the gateway answers reopens of live sessions
- **Date:** 2026-11-06
- **Decision:** PLAN 3.7 (FR-20, F-12), from the phase 3 plan notes.
  - **Live sessions.** For each project agent, the gateway keeps the sessions that are open in the current process: created by `session/new`, or loaded or resumed successfully. For each one it keeps the agent's result (for `session/new`, without `sessionId`). It tracks the current mode in that result from a successful `session/set_mode` and from `current_mode_update`. A successful `session/delete` or `session/close` removes the session from the set. When the agent exits, nothing is live.
  - **Reopen of a live session.** A `session/load` or `session/resume` for a live session never reaches the agent, whether a turn runs or not. The gateway answers it with the kept result. Then it sends that socket the session's history from the event log as plain messages, as the agent would after a load: each `turn_started` prompt as `user_message_chunk` updates (one per content block), each logged agent message as it was, and a permission request only while it is still unanswered. The gateway's turn markers are not sent. Live messages follow, with no gap and no duplicate. This uses the D-028 replay path with plain messages instead of `_agmente/event`. A socket subscribed to the session already has the events and gets only the response. Resume replays history too, because Bob 2.0.9 replays on resume as well (F-12), so the current app sees what it saw without the gateway.
  - **Reopen after a restart.** A load or resume for a session that is not live is forwarded once. Until the replay window ends, every other request for that session waits, including a second load. So the agent gets one load, and no turn runs during it. If the agent refuses, the error goes to the phone and the window ends. If it succeeds, the session is live, and the agent's replayed updates go to the requesting socket only: they are not logged and no other socket gets them. The gateway then sends the agent a read-only `session/list` as a fence. The window ends when the fence is answered, and the gateway drops that answer. This relies on the agent writing its whole replay before it answers the next request. The fake agent does; for Bob this is "verify". Requests that waited are then handled: a second load is answered from the log.
  - A load or resume sent as a notification (no id) is dropped and audited (`dropped`). New audit events: `reopen_answered` and `reload`.
  - This supersedes the D-027 note that Bob's load replay is logged.
  - **Limits.** History replayed by the gateway comes from the log only, so a session from before the gateway logged it (for example one created in Bob's CLI) shows only its newer turns when reopened while live. The kept result tracks the mode, not models or config options. During a reload window, an agent notification for that session that is not part of the replay is also kept out of the log.
- **Reason:** Bob refuses a load or resume while a turn runs, and an idle load rebuilds the session (MCP servers restart) and replays history into the log (F-12, F-19). Answering from the gateway avoids both, and the event log already holds everything Bob would replay. The fence is needed because a request sent after the load response can reach the gateway's forward path before the gateway has read the agent's replayed lines; a mutation that closed the window at the load response let replayed history into the log (T-21).

## D-030 Session index, status and read markers
- **Date:** 2026-11-06
- **Decision:** PLAN 3.8 (FR-21, FR-25), filling in the draft shape in SPEC 6.2.
  - **`_agmente/sessions/index {projectId?}`** returns `{sessions: [{sessionId, projectId, title, status, lastActivity, headSeq, unread}]}`, newest `lastActivity` first. `headSeq` is added to the SPEC draft, so a phone can subscribe or mark read without another call. `projectId`, when given, must be a registered project; otherwise `-32602`. The index is read from the database and the gateway's own state, so it starts no agent and works after a gateway restart. It lists the sessions the gateway has recorded (created, loaded or resumed through it), not every session in Bob's store.
  - **`title`** is the last title in an agent `session_info_update` for the session (Bob sends one after the first turn), or null.
  - **`status`**, first match wins: `awaiting_approval` while a permission request for the session is open; `running` while a `session/prompt` for it is with the agent; `error` when its last turn ended with an error (the agent exited mid-turn or refused the prompt); otherwise `idle`. Only `idle` and `error` are stored; the other two come from memory, because no turn or request survives a gateway restart. A completed turn sets `idle` again.
  - **`lastActivity`** is the time of the session's last logged event, or of the last time it was recorded (new, load, resume), when that is later. ISO 8601 UTC with milliseconds.
  - **`unread`** is the number of `turn_ended` events after the identity's read marker: turns that finished and that no device of this identity has marked read. Open approvals show in `status`, not in `unread`.
  - **`_agmente/sessions/read {sessionId, seq}`** (new method) sets the identity's marker to `seq`. It never moves back, and stops at the session's head. It returns `{lastSeenSeq}`. `seq` must be a non-negative JSON integer, and the session must be recorded; otherwise `-32602`. The marker is per identity, so every device of one identity shares it (FR-25), and other identities keep their own.
  - **Delete.** After the agent accepts `session/delete`, the gateway removes the session, its events and its read markers. A later subscribe or read for it gets "unknown session".
- **Reason:** FR-21 asks for status and unread without saying how either is defined. Counting finished turns gives the home screen one badge per thing to look at. The phone, not delivery, decides what is read, because a subscribed phone in the background receives events nobody has seen. Keeping running and awaiting status in memory means a gateway restart can never leave a stale `running`.

## D-031 The approval queue: answers, first wins, timeout and records
- **Date:** 2026-11-06
- **Decision:** PLAN 3.9 (FR-22, NFR-10), from the phase 3 plan notes. Builds on D-009, D-020 and D-026.
  - **Approvals.** Each agent `session/request_permission` becomes an approval with its gateway id `agmente-perm-<n>` (D-026), which is also its `approvalId`. It is logged and delivered as before (D-027, D-028), and stored in the `approvals` table with the tool call, the options and the time. Ids continue after the highest one stored, so they never repeat across gateway restarts.
  - **Answers.** A phone answers with `_agmente/approvals/answer {approvalId, optionId}` or `{approvalId, cancelled: true}`, which returns `{}`; or with a plain JSON-RPC response to the forwarded id, as the current app does. The method checks that exactly one of the two is given and that `optionId` is one of the request's options. A refused answer leaves the approval open. A plain response is forwarded to the agent as the phone sent it.
  - **First answer wins.** The first answer of any kind goes to the agent. A later method answer gets error `-32001` with the reason: "answered elsewhere", "timed out", "cancelled" or "the agent exited". A later plain response is dropped (audited `response_dropped`), and that socket gets `_agmente/notice {approvalId, message}` with the same reason. An unknown id gets `-32602` "unknown approval".
  - **Timeout.** After `limits.approvalTimeoutSeconds` (new key; NFR-10 default 43,200 s, 12 h) with no answer, the gateway sends the first `reject_once` option, else the first `reject_always` option, else `cancelled`. It never sends an allow option (D-009). A Go unit test covers this choice, and T-23 covers it on the wire.
  - **Other closes.** When a phone sends `session/cancel`, the gateway answers that session's open approvals with `cancelled`, as ACP asks of the client. When the agent exits, its approvals close without an answer. At startup, approvals left open by a gateway that died are marked closed.
  - **Records.** Each close writes `answered_by` (`<identity>/<device>`, `timeout`, `cancel`, `agent_exit` or `gateway_restart`) and the outcome sent, and logs a gateway event `approval_answered`, `{"method":"_agmente/approval_answered","params":{sessionId, approvalId, answeredBy, outcome}}`, so subscribers can close the request on every device. Phones that do not subscribe do not get it, like the other gateway events.
  - **`_agmente/approvals/pending`** returns `{approvals: [{approvalId, sessionId, projectId, toolCall, options, since}]}`, oldest first. The SPEC draft's `requestId` is named `approvalId`, as in the plan notes, and `projectId` and `options` are added.
  - `extensions` is now `["projects", "sessions", "approvals"]`.
  - Not in this task: the idle stop that a pending approval holds off (D-020) is task 3.12.
- **Reason:** FR-22 and T-22 need one answer per request, and every other device must learn the request is closed. Claiming the approval in memory, under one lock, is what decides the winner. Who claimed it is kept in memory until it is stored, so a losing answer always gets the reason; the T-22 race test found that gap. The timeout choice is a fixed rule over option kinds, so no configuration can make the gateway approve.

## D-032 Idle close, idle stop, and the gateway's own load
- **Date:** 2026-11-06
- **Decision:** PLAN 3.12 (FR-24, FR-45, NFR-10), from the phase 3 plan notes and D-016 and D-020.
  - **Busy and active.** A session is busy while a turn runs in it, an approval for it is open, a socket subscribes to it (with `_agmente/sessions/subscribe`, or through a reopen answered by the gateway, D-029), or a load for it is under way. Activity is any phone request, any agent line, or a busy session at a check. A running agent checks itself every quarter of the idle time (between 50 ms and 30 s), so a stop comes between 1 and 1.25 idle times after the last activity.
  - **Idle stop (FR-45).** When the whole project has been inactive for `limits.idleSeconds` (new key; NFR-10 default 1,800 s) and no request is pending, the gateway stops the agent: SIGTERM, then a kill after 2 s. For the podman runner that is `podman run`'s process, which passes the signal to the container; `--rm` removes it. Audit `agent_idle_stop`. The state becomes "stopping" under the lock that every forward takes, so no request reaches an agent after the decision. A request that comes meanwhile waits for the exit, then starts a new agent (D-015, D-025).
  - **Idle close (FR-24).** While the project stays up, a live session that has been inactive for the idle time is closed with `session/close {sessionId}`, if the agent's `initialize` offers `sessionCapabilities.close` (Bob 2.0.9 does; its behaviour is "verify"). The gateway drops the answer. Audit `session_idle_close`.
  - **The gateway's own load.** A `session/prompt`, `session/set_mode`, `session/set_model` or `session/set_config_option` for a session that is not live in the current agent (after a restart, an idle stop or an idle close) first makes the gateway send `session/load {sessionId, cwd: <project path>, mcpServers: []}` itself. It sends one load, with no turn running (FR-20), and the replay goes to no socket and not to the log. The request waits for the D-029 fence, then goes to the agent. If the load fails, the request goes anyway and gets the agent's error. Without this, the current app would get "Session not found" after every idle stop, because it opens a session only once per connection. Phone-chosen MCP servers are not passed; MCP is gateway-managed (phase 5).
  - The podman runner is now run end to end, against `test/fixtures/fake-podman.mjs` (T-46). That fake refuses a container name in use, as Podman does, and logs each start and exit. Real Podman is still "verify" (PLAN 4.1).
  - Not in this task: stopping a leftover `agmente-<projectId>` container at gateway start (D-016). Today a leftover holds the name, and the start fails with "agent failed to start" until it exits.
- **Reason:** D-016 and D-020 fix when a project may stop; this records how the gateway measures it. Taking the stop decision under the forward lock removes the one race that could send a request to a dying agent; a mutation that skipped it failed T-46. The gateway's own load is what lets idle stops stay invisible to the phones.

## D-033 A crash guard around each phone message
- **Date:** 2026-11-06
- **Decision:** Each phone message is handled inside a guard that recovers a panic. Then the gateway:
  - answers that request with `-32603` "internal error", if it has an id;
  - writes an audit line `panic` with the method and the panic's Go type, never message content;
  - closes that socket with 1011 once the answer has been written (at most 1 s), so the phone reconnects.

  Other sockets and the agents are not touched. A test-only hook (`panicHook`, set only by a Go unit test) makes a chosen method panic; the wire suite cannot trigger a panic, and no config or message can.
- **Reason:** In task 3.9 a nil read in `_agmente/approvals/answer` panicked. `net/http` recovered it, but the WebSocket handler had stopped reading, so the phone waited with no answer and no close (RESULTS 3.9). Closing instead of carrying on is the safe choice, because after a panic the socket's state is unknown. Limit: a panic while a lock is held would leave the lock held, and the guard cannot repair that.

## D-034 Git runs as a short-lived container per command, with fixed flags and environment
- **Date:** 2026-11-06
- **Decision:** PLAN 3.13 (FR-28, NFR-8, D-008). The runner interface gains `exec`. The gateway builds every git command; the client supplies only values that later tasks validate (a project, a path from the last status).
  - **Podman runner:** `podman run --rm -i --name agmente-git-<projectId>-<random> --pull=never --init --network=none`, the project folder and the project home mounted at their host paths, `--entrypoint git`, the project image. It does not use the agent's container, so git needs no running agent and cannot take the agent's name, which is the project lock (D-015). Cost: about 1 s per call on a Mac Podman VM (verify against T-30).
  - **Host runner** (tests and development only): the same command as the gateway user in the project folder.
  - **Flags:** `--no-pager --no-optional-locks -c core.fsmonitor=false -c core.hooksPath=/dev/null -c safe.directory=<project path>`. `safe.directory` names only the project folder: it belongs to the owner, not to the container user, and git refuses it otherwise. Diff commands add `--no-ext-diff --no-textconv` (3.14).
  - **Environment, whole:** `PATH`, `HOME` (the project home), `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, plus variables the gateway builds (`GIT_INDEX_FILE`). Nothing from the gateway's environment.
  - **Limits:** 5 s timeout (the process group is killed, and a podman container is removed by name), 2 MiB output cap (past it the output is cut, the process is killed, `truncated` is set), 64 KiB of stderr kept in memory and never put in an error message or the audit log.
- **Reason:** A repository can run programs through config (F-20, T-26). Fixed flags and an empty environment stop the known ones. The container keeps any that remain away from the host (T-27), and no network stops one from sending data out. A separate container per call is simpler than exec into the agent's container, which may be stopped (FR-45) or mid-stop.

## D-035 Git methods: shapes, the path allow-list and the deny-list
- **Date:** 2026-11-06
- **Decision:** PLAN 3.14 (FR-27, FR-29, FR-30), filling in the SPEC 6.2 draft. All three take `projectId` (unknown: `-32602`) and run through D-034's runner. A git failure is `-32000` "git timeout", "not a git repository" or "git failed"; git's own text is never sent. `extensions` now has `"git"`.
  - **`_agmente/git/status`**: `{branch (null when detached), upstream (null), ahead, behind, files: [{path, status, staged, added, removed}], hash, truncated}`. `status` is `modified`, `added`, `deleted`, `renamed`, `copied`, `type_changed`, `untracked` or `conflicted`. Untracked files are listed one by one (`--untracked-files=all`). `added` and `removed` are the line counts of the unstaged plus staged change, and null for untracked and binary files. `hash` is the SHA-256 of git's status output, the value `git/changed` will carry. It runs three git commands at once: status and two `--numstat` runs.
  - **Allow-list (FR-29).** The paths from the last status of a project, in memory, are the only paths a diff accepts: a path not in it, or any path before a status was run, gets `-32602`. A rename allows both names. The path goes after `--` and as a `:(literal)` pathspec, so a name like `-x` or `*.c` means only itself. `git/diff` with no `path` is the whole tree and needs no list.
  - **`_agmente/git/diff {projectId, path?, staged?}`** returns `{diff, truncated, hidden}`. `staged: true` is `--cached`; an untracked file is shown as a new file through `diff --no-index`. Always `--no-ext-diff --no-textconv --no-color`; output cut at 2 MiB sets `truncated`. `fromTree` and `toTree` come with 3.15.
  - **Deny-list (FR-30):** `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `id_rsa*`, `*secret*`, `.npmrc`, `.netrc`, matched case-insensitively against every path component. For a listed path the diff holds one line, `secret file changed: <path> (content hidden)`, and `hidden` has the name; git never produces its content. The whole-tree diff excludes the list in git and appends those lines for the changed files in the last status. Additions per project are not built yet.
  - **`_agmente/git/log {projectId, limit?, cursor?}`**: `{commits: [{hash, shortHash, author, date, subject}], nextCursor?}`, newest first, `limit` 1 to 200 (default 50), `cursor` an opaque offset. Author names are sent; emails are not. An empty repository gives no commits.
  - Git methods are answered in their own goroutine, with a recover that answers `-32603` (D-033's guard only covers the read loop).
- **Reason:** A phone must never choose what git reads (F-20, FR-29), and a secret must never leave the gateway because it changed (FR-30). Using the last status as the only source of paths makes the first rule structural. Excluding the deny-list in git, rather than cutting the text afterwards, means the content is never read into the gateway's memory.

## D-036 Turn snapshots: trees made without `git add`, in a store of the gateway's own
- **Date:** 2026-11-06
- **Decision:** PLAN 3.15 (FR-27), from the plan notes, with these details.
  - **When.** The start snapshot is taken after the turn's `turn_started` is logged and before the prompt goes to the agent, so the agent cannot change files first. It may delay the prompt by up to 20 s; on failure the turn goes on with no diff and the audit has `snapshot_failed`. The end snapshot is taken in the background after `turn_ended` is sent (30 s limit); `git/turnDiff` waits for it. Turns are numbered from 1 per session by counting `turn_started` events. Trees are stored in a new table `snapshots (session_id, turn, start_tree, end_tree)`, schema version 2; a version 1 database is migrated in place.
  - **How.** `ls-files -s -z` (tracked), `ls-files -z --others --exclude-standard` and `ls-files -z --deleted` give the paths; the gateway looks at each path's type itself with `lstat` and keeps only regular files, with mode 100755 if any execute bit is set, else 100644. `hash-object --no-filters -w --stdin-paths` hashes them; `update-index -z --index-info` builds a temporary index; `write-tree` writes the tree. No clean filter, smudge filter or `.gitattributes` program can run. Symlinks are left out, because `hash-object` would hash the file a link points to; pipes are left out, because hashing one would block; submodules are left out; paths with a newline are left out (`--stdin-paths` reads lines).
  - **Where objects go.** `GIT_OBJECT_DIRECTORY=<project home>/snapshots/objects` with the repository's own `objects` as `GIT_ALTERNATE_OBJECT_DIRECTORIES`. The repository's index, refs and objects are not touched. The temporary index is deleted after use.
  - **`_agmente/git/turnDiff {sessionId, turn}`** returns `{diff, truncated, hidden, fromTree, toTree}`; errors are `-32602` for a bad session or turn, and `-32000` "no snapshot for this turn" or "turn is still running". The diff uses `--no-ext-diff --no-textconv` and the same deny-list as D-035: secret files are named in `hidden` and in stub lines, never shown.
  - **`_agmente/git/diff`** now also takes `fromTree` and `toTree` (both, 40 or 64 hex digits). A `path` in that mode must be one of the files that differ between the trees.
  - **Limits.** A change made by anyone in the seconds after a turn ends counts in that turn. Two sessions that run in one project at once see each other's changes. Every file is hashed at each snapshot, so cost grows with the project. Inside Podman the snapshot folder must be writable by the container user (see RESULTS 3.15).
- **Reason:** `git add` runs clean filters from `.gitattributes`, which a hostile repository controls (F-20, T-27). Hashing with `--no-filters` removes that path completely, so the marker appears nowhere, which is stronger than the test asks. A separate object store keeps a read-only feature from writing into the user's repository.

## D-037 git/changed: a stat poll while a socket watches, notified by status hash
- **Date:** 2026-11-06
- **Decision:** PLAN 3.16 (FR-27, NFR-9). This replaces the plan note's `fs.watch`, which is a Node API.
  - **Who is told.** A socket that has called `_agmente/git/status` for a project gets `_agmente/git/changed {projectId, hash}` for it, until it closes. There is no subscribe method. One watch serves all sockets of a project; it starts with the first and stops when none is left (audit `git_watch_start`, `git_watch_stop`). With no watcher the gateway looks at nothing.
  - **How it looks.** Every 500 ms it walks the project folder with `lstat` and hashes each file's name, size, modification time and mode (folders are left out). It skips `.git` except `HEAD`, `index`, `packed-refs`, `MERGE_HEAD` and `refs/`, and folders named `node_modules`, `.venv`, `venv`, `__pycache__`, `target`, `.gradle`, `Pods`, `.build`, `DerivedData`, `.next` or `.cache`. The walk stops at 200,000 files. No new dependency.
  - **Debounce.** A change in the fingerprint only marks the project dirty. After the first interval with no further change (500 ms or more of quiet) the gateway runs git status. It sends a notification only if the status hash differs from the last one sent, so a change to an ignored file sends nothing. At most one check runs per 500 ms tick, so at most 2 notifications a second (NFR-9). Each check also refreshes the diff path allow-list.
  - **The status hash** now covers git's status text, both line-count outputs, and the size and modification time of every listed file, so any further edit to a listed file changes it, even one that keeps the status and counts. A `touch` changes it too.
- **Reason:** An OS file-event library (fsnotify) would be a third dependency, with a kqueue file descriptor per file on macOS and a watch per folder on Linux, and it still needs a skip list for heavy folders. A stat walk costs about 10 ms for 10,000 files on the host, runs only while someone watches, and behaves the same on both platforms. The price is up to a second of latency and no view into skipped folders, which `git/status` still sees. If that latency or cost matters, switching to inotify later changes only `watch.go`.

## D-038 Push payloads: a pure builder with no free text
- **Date:** 2026-11-06
- **Decision:** PLAN 3.10 (FR-23, NFR-11). `internal/push.Build(event, projectName, sessionID)` returns an APNs JSON payload: `aps.alert.title` is the project name, `aps.alert.body` is a fixed text per event (`Turn finished`, `Approval needed`, `Session failed`), `aps.sound` is `default`, `aps.thread-id` and the custom key `sessionId` are the session id, and the custom key `event` is `turn_ended`, `approval_needed` or `session_failed`. It has no parameter for a prompt, a session title or tool output. The name has control and format characters removed, is cut on a character boundary with an ellipsis until the whole payload is at most 256 bytes, and falls back to `Agmente` when empty. An unknown event, an empty or non-UTF-8 session id, or one too long to fit is an error. Nothing sends it yet; the token store, the registration method and APNs delivery are 3.11.
- **Reason:** The payload goes through Apple's servers and shows on a lock screen, so it must never hold content (NFR-11). Leaving out a text parameter makes that true by construction, not by a check. The project name is the one piece of the owner's data it shows, as the requirement says.

## D-039 App on a gateway: detect it, list from it, open by subscribing
- **Date:** 2026-11-06
- **Decision:** PLAN 3.17 and 3.18, as planned (the 3D plan, approved 2026-11-06), with one change.
  - **Detection.** The app reads `_meta["agmente/gateway"]` from `initialize` (version, extensions). Everything gateway-specific is behind it; a server without it, and Codex servers, behave as before.
  - **Home.** For a gateway with `projects` and `sessions`, the session list is the gateway's: sections per project from `_agmente/projects/list` and `_agmente/sessions/index`, a status badge, an unread count, and a project picker for a new session.
  - **Open.** A gateway session is opened with `_agmente/sessions/subscribe`, never `session/load` or `session/resume` (FR-20). The first open in a run clears the chat and replays from `afterSeq` 0; later opens and a resubscribe after a gap or a reconnect continue from the last event applied. Events are applied once and in order; events of a session that is not on screen are not applied, and opening it subscribes again.
  - **Changed from the plan:** the last event applied is held in memory only. The plan stored it per session in Core Data. A stored seq can run ahead of the saved chat, which would lose events after a crash; replaying from 0 on a cold start cannot, and costs under a second for 10,000 events. No data model version was added.
  - **Removed:** the `X-Client-Id` header and everything behind it (PLAN 3.18, F-3). Another ACP server that relied on it for `--persist` reattach no longer gets a reattach from this app.
  - **Echo.** The gateway sends this device's own prompt back as `turn_started`. The app notes the text it sent and skips that one event, so the message is not shown twice.
- **Reason:** The gateway already keeps the log and answers a reopen itself (D-029), so the app only needs to subscribe. Reusing the existing update path keeps rendering, parsing and storage as they were.

## D-040 Approvals in the app: inbox, banner, and answers through the gateway method
- **Date:** 2026-11-06
- **Decision:** PLAN 3.19 (FR-22, D-031).
  - **Inbox.** For a gateway server the app lists the gateway's open approvals (`_agmente/approvals/pending`) in a sheet opened from a banner at the top of the home. Each card shows the tool title, the command when the tool call carries one, the project and session, the age, and one button per option the agent offered, coloured by kind (allow green, reject red), plus "Cancel request" (`cancelled: true`).
  - **Answers.** Both the inbox and the in-session card answer with `_agmente/approvals/answer`. A `-32001` answer ("answered elsewhere", "timed out", "cancelled", "the agent exited") removes the approval and says why; any other failure keeps it, so the person can try again. An answer on its way blocks a second tap on the same approval.
  - **Never automatic.** Nothing in the app answers a request: not on arrival, not on refresh, not on a timer. Only a tap sends an answer (D-009).
  - **Freshness.** The gateway sends events only for sessions a socket subscribed to, and the app applies them only for the session on screen. So the inbox refreshes on open, on pull, on a permission or answered event for the open session, and every 15 s while the home is shown. Push (3.20 and 3C) will shorten that.
  - A server that is not the gateway keeps the plain response, unchanged.
- **Reason:** A person must see every waiting request wherever it started (FR-22, FR-25), and must be told when another device was first. Answering through the method, not a plain response, gives the app an error it can show; the plain response would be dropped by the gateway with the notice going to a socket that may not be looking.

## D-041 Deep link and push registration in the app: a link only navigates; the token stays on the device
- **Date:** 2026-11-06
- **Decision:** PLAN 3.20 (FR-23, FR-26), as far as it can go without an APNs key, an Apple account or a device.
  - **Link.** `agmente://session/<serverId>/<sessionId>`. The parser accepts only scheme `agmente`, host `session`, no user, password or port, exactly two path parts, a UUID server id and a session id of at most 200 characters with no slash or control character. Anything else is `invalid`.
  - **What a link does.** It selects the server it names and opens the session in the list. It never sends a prompt, answers or cancels an approval, creates a session or changes a setting. A server this device does not have gives a short notice and changes nothing. A session the gateway does not know shows the open session's own error.
  - **Notification tap.** The payload carries the session id only (D-038), so the tap opens that session on the selected server.
  - **Permission and token.** The app asks for notification permission only when the person taps "Allow notifications" in Settings. At launch it reads the status and, if allowed, asks Apple for a token again. The token is held in memory as hex and is not stored or sent.
  - **Not built (BLOCKED, RESULTS):** `_agmente/push/register` on the gateway (no method exists and none is added without approval), the `aps-environment` entitlement and Push capability (Apple account and signing), the APNs `.p8` key and delivery (3.11), and any check on a device.
- **Reason:** a link comes from outside the app, so it may only change what is on screen (D-009). A token sent to a server needs a gateway method and a decision on how the gateway stores it; that is the owner's call.

## D-050 A project can add to the secret deny-list at creation, never remove from it
- **Date:** 2026-11-06
- **Decision:** FR-30, the "Additions per project" left open in D-035.
  - **Input.** `_agmente/projects/create` takes an optional `denyPaths`: a list of at most 32 globs, each 1 to 100 characters. A bad entry or a bad type is `-32602` naming `denyPaths`, and nothing is registered. Duplicates (case-insensitive) are dropped. There is no way to set it later; an additive update method is not built (it would be a new method and a new D-n).
  - **Allowed entries.** ASCII letters, digits, space and `. _ - / *` only. Refused: an absolute path, an empty, `.` or `..` component (so a trailing or doubled `/`), `**`, `?`, `[ ]`, `\`, `:`, `!`, control characters, anything non-ASCII, and a leading or trailing space. Reason for so small a set: Go's `path.Match` decides which names the gateway reports as hidden, and git's pathspec glob decides which content git leaves out of a whole-tree diff. On this set the two agree (`*` never crosses `/`, no byte-versus-character difference, no negation, no escape). A looser set could make the gateway call a file hidden while git still printed its content.
  - **Meaning.** An entry with no `/` is matched, case-insensitively, against every path component, as the built-in list is (`*.db` hides `a/b/Data.DB`). An entry with a `/` is anchored at the project root and matched against the same number of leading components, so `config/prod.yml` hides that file only, and `vault/*` hides everything below `vault/`.
  - **Where it applies.** Exactly where the built-in list does: `git/diff` with a path (the stub line replaces the diff), the whole-tree and staged diffs (git excludes the paths; the changed files are named in `hidden` and in stub lines), `git/diff` with `fromTree` and `toTree`, and `git/turnDiff`. The effective list is the built-ins plus the project's: `isSecretFor` tests the built-ins first and `secretExcludesFor` starts from them, so no input removes one. A refusal of `!.env` or an empty entry is the only "removal" a client can attempt.
  - **Storage.** Schema version 3: `ALTER TABLE projects ADD COLUMN deny_paths TEXT` (a JSON array, NULL when none). A version 1 or 2 database is migrated in place and keeps its projects, with no additions. `projects/create` and `projects/list` return `denyPaths` only when it is not empty, so old clients and tests see no change.
  - **Not covered.** File names still appear in `git/status` (they always did); the hidden list is about content. The watcher's change fingerprint and status hash include a hidden file's size and time, as for built-ins.
- **Reason:** FR-30 and the phase 3 notes say a project can add to the list and never remove from it. Making that structural (built-ins always tested first, the input type cannot express a removal) is stronger than a check on the input.

## D-051 The container user maps to the gateway user: `--userns=keep-id`, no open folder modes
- **Date:** 2026-11-06
- **Decision:** Closes the open item in RESULTS 3.15 (and the "uid mapping" gap in 3.13). Under rootless Podman the user who runs `podman` is root inside the container by default, and the image's user (uid 10001, `deploy/bob-project.Containerfile`) is a sub-uid that owns nothing on the host. So that user could not write the project home (agent `HOME`, mode 0700), the snapshot folder (0700) or the project folder.
  - **Flags.** Every podman run the gateway builds (the agent and the git commands) now has `--userns=keep-id:uid=U,gid=G --user U:G`. This maps the gateway's own uid and gid to U and G inside the container, so the container user owns what the gateway user owns, and files it writes belong to the gateway user on the host. U and G default to 10001 (`config.DefaultContainerID`); `runner.containerUid` and `runner.containerGid` (optional, 1 to 65535, 0 refused because it would be root) set them for an image with another user.
  - **Modes.** Nothing is loosened. The gateway keeps creating the home, the snapshot folders and the trust file as 0700 and 0600. No world-writable folder is needed, so no other host user can read a project's secrets or the snapshot objects. The Go snapshot test no longer pre-creates the folders as 0777.
  - **Verified on this Mac only** (Podman 5.6.2, machine `podman-machine-default`, libkrun): the container user (uid 10001) writes 0700 folders for the home, the snapshot objects and the project; the files appear on the host owned by the gateway user (501); the same run without the flags gets "Permission denied"; the snapshot under a required clean filter works with 0700 folders.
  - **NOT VERIFIED, needs a Linux host:** the `keep-id:uid=,gid=` option on the Linux Podman version in use (Podman 5.6.2 here accepts it; the option needs a Podman new enough to have it, verify the minimum); a gateway that runs as a service user with sub-uid ranges in `/etc/subuid`; SELinux (a labelled volume may need `:z` or a label option, not added); Docker (no `keep-id`; not a supported runner); the idle stop and agent start with these flags on Linux (only the git and exec path was run live here, not a full Bob agent).
  - **Not done:** `--userns=keep-id` costs start-up time in some Podman versions because it builds a user-namespace mapping per run. Not measured; T-47 on the Linux host decides.
- **Reason:** The alternatives were worse. A 0777 snapshot folder lets any local user read or plant objects. A per-project `chown` needs root. `--userns=keep-id` is Podman's option for making a bind mount owned by the caller appear owned by the container user (podman-run man page; the `uid=`/`gid=` suboptions: verify the version that added them), and the live test shows it works with the modes the gateway already uses.

## D-060 Agent images: parse in ACPClient, decode only in the app, never fetch
- **Date:** 2026-11-06
- **Decision:** PLAN 5.1 and 5.2 (FR-37, NFR-13).
  - **Parsing.** `ACPSessionUpdateParser.mediaBlocks(from:)` (new file `ContentBlockParsing.swift`) finds `image`, `resource` and `resource_link` blocks in an update's `content`: a single block, an array, or `{"type":"content","content":{...}}` wrappers (tool-call content), at most 3 levels deep and 64 items. `ACPSessionUpdateHandler` emits them as a new `ACPSessionUpdateEvent.media` after the text or tool-call event, for `agent_message_chunk`, `tool_call` and `tool_call_update`. The parser keeps the base64 text and decodes nothing. Codex: the app-server client has image inputs only (prompt side) and no inbound image item, so no Codex change was made; nothing is shared between the two paths.
  - **Decode.** `Agmente/Fork/ForkMedia.swift`. Checks in order: MIME allow-list (png, jpeg, gif, webp, heic, heif; SVG and all else refused); base64 length for at most 20 MiB decoded (NFR-13); base64 decode; ImageIO header read: the sniffed type must be allowed and match the declared MIME; pixel size read without decoding, refusing over 100 million pixels or 20,000 px on a side (decompression bomb); then `CGImageSourceCreateThumbnailAtIndex` with a 2048 px cap on the longest side (NFR-13 allows 4096; 2048 keeps the bitmap near 16 MB). Only the downsampled bitmap is kept. A refusal shows a visible placeholder row with the reason.
  - **resource_link.** Shown as a non-loading row (title, URI as plain text, MIME and size). The app never fetches it; signed file URLs are task 5.3. A `resource` that is not an image blob shows a placeholder.
  - **Chat hook.** `AssistantSegment` gets a transient `media` field (kind `message`, `text` holds a fallback such as `[image]`). It is not persisted, so a restored chat shows the fallback text. `ChatEntry.Kind.media` and `ForkMediaRowView` render it.
  - **Known limit.** Decoding runs on the main actor at ingest. It is bounded by the 20 MiB and 100 MP limits (50 MP PNG: about 0.5 s in the simulator test, RESULTS). Moving it off the main actor is a later change.
- **Reason:** F-9: Agmente dropped these blocks. Agent images are untrusted input, so each limit refuses before the next, more expensive step.


## D-042 Git in the app: lazy chips, read-only sheets, turn number from the chat
- **Date:** 2026-11-06
- **Decision:** PLAN 3.21 (FR-31, D-035, D-036, D-037). Shown only when the gateway's `initialize` lists the `git` extension.
  - **Branch chip.** In a project's header on the gateway home and in the session toolbar: branch (or "detached"), ahead and behind, and a dot when the working tree has changes. A chip calls `_agmente/git/status` once when it first appears, and again only on `_agmente/git/changed` with a hash different from the one held, after a reconnect (the gateway forgets which sockets watch), and when the Git tab is opened or refreshed. There is no timer, because every status starts a git container (D-034) and the first call also starts the gateway's watch for the project (D-037). The chip keeps the last status when a later refresh fails; a project that is not a repository shows no chip on the home.
  - **Git tab.** A sheet with Changes and History. Changes lists each file with its status letter, a staged flag and line counts; a tap loads `git/diff` for that path. The app sends a path only if it is in the last status it holds (the gateway enforces this too, FR-29). For a staged file the diff view offers Unstaged and Staged, and starts on Staged. History pages with the cursor, 50 at a time, and drops a commit it already shows. Secret files (`hidden`) show "Content hidden" and no lines. States: loading, error with retry, not a repository, truncated, no changes.
  - **Turn diff.** A "Turn diff" button in the file-change row calls `_agmente/git/turnDiff`. The turn number of a message is the count of user messages up to it (the gateway counts `turn_started` events from 1, D-036). This holds when the chat was built by replaying the session from the start, as the app does on a gateway (D-039). It is wrong if the chat holds local-only user messages or lacks early history; the sheet title shows the turn number so a person can see which turn was asked for. "No snapshot for this turn" and "turn is still running" have their own states.
  - **Not done:** no write action of any kind (SPEC 2). The app has no git command, and no code path starts a git call except a status refresh and the taps above.
- **Reason:** Polling would start a container per project every few seconds. The change notification already exists. Deriving the turn from the chat needs no gateway change; the cost is the stated assumption.

## D-052 Push token registration: one token per identity and device, stored by the gateway, no delivery
- **Date:** 2026-11-07
- **Decision:** The first half of PLAN 3.11, which needs no Apple credentials. Approved by the owner on 2026-11-07 ("lets do the build without apple creds").
  - **Methods.** `_agmente/push/register {deviceToken, environment}` returns `{}`. `deviceToken` is 64 to 200 hex digits (APNs tokens are 32 bytes today; the range leaves room), stored in lowercase. `environment` is `sandbox` or `production` and is required, because a token only works against the APNs host of its own environment. `_agmente/push/unregister` returns `{}` and is not an error when there is no token. A bad value is `-32602` naming the field and stores nothing.
  - **Who.** The token is keyed by the authenticated identity and device (the token config's `identity` and `id`), never by anything the phone sends. A device can set and remove only its own. A second register replaces the first.
  - **Storage.** Schema version 4: table `push_tokens (identity, device, token, environment, updated)`, primary key `(identity, device)`. A version 1, 2 or 3 database is migrated in place. `Store.PushTokens(identity)` exists for delivery to read; nothing reads it yet.
  - **Secrecy.** The token is not returned, not logged and not put in the audit log. The audit has `push_registered` and `push_unregistered` with identity and device only.
  - **Extension.** `extensions` is now `["projects","sessions","approvals","git","push"]`. The app sends a token only to a server whose `initialize` lists `push`, and only while notification permission is on and a token is held.
  - **App.** `GatewayClient.registerPush` and `unregisterPush`; `PushGatewaySync` decides whether to send; the app sends when the token arrives and when a gateway connects. `environment` is `sandbox` in Debug builds and `production` otherwise. That is a guess from the build configuration (a development-signed Release build would be wrong); the device test checks it.
  - **Not built (BLOCKED):** delivery to APNs (3.11 second half): JWT signing with the `.p8` key, HTTP/2 to `api.sandbox.push.apple.com` or `api.push.apple.com`, removing a token that APNs reports as invalid, retry. The `aps-environment` entitlement and Push capability. Steps are in `docs/PUSH-TESTING.md`.
  - **Unregister on switch-off** is not wired in the app: turning notifications off in iOS Settings leaves the gateway holding a token that APNs will later reject. Delivery must delete a token on `BadDeviceToken` or `Unregistered`.
- **Reason:** The owner asked for everything that can be built and tested without Apple. Registration is a plain stored value and can be tested end to end on the wire. Keying by the authenticated device keeps one device from changing another's token.

## D-065 A project's own skip list for the git watcher (`watchSkip`)
- **Date:** 2026-11-07
- **Decision:** Extends D-037, which fixed the watcher's folders to a built-in list. FR-27, NFR-9.
  - **Input.** `_agmente/projects/create` takes an optional `watchSkip`: at most 32 entries, each 1 to 100 characters of ASCII letters, digits, space and `. _ - /`. No `*` (so no glob), no `..`, `.` or empty component, no leading or trailing `/`, no leading or trailing space, no absolute path. A bad entry or a bad type is `-32602` naming `watchSkip`, and nothing is registered. Duplicates (case-insensitive) are dropped. The check is `validatePathList`, shared with `denyPaths` (D-050) with globs off.
  - **Meaning.** A bare name skips a folder of that name at any depth, as the built-in names do. An entry with a `/` skips only the folder at that path from the project root. Matching is exact.
  - **Only adds.** The skipped folders are the built-in names plus the project's entries. No input removes a built-in.
  - **Effect.** The stat poll does not walk a skipped folder, so a change inside it starts no check and sends no `git/changed`. `git/status` still lists those files, and the diff paths are unchanged. The watcher reads the project again on each tick, so `addWatchSkip` (D-066) applies to a running watch.
  - **Root.** The project folder itself is never skipped. Before this change, a project whose folder was called `target` or `Pods` had its whole watch skipped, because the built-in name check also ran on the root.
  - **Baseline.** A new watch now starts from the folder fingerprint taken before its `git/status` runs (`watchBaseline`), instead of running one check on its first tick. The first tick used to run git status unconditionally, and git status lists untracked files in skipped folders, so a skipped change made in the first second after a status changed the hash and sent one notification. A change after the baseline is seen by the fingerprint; a change before it is already in the status. Cost: one extra walk on the first `git/status` of a project that has no watch. Not measured on a 200,000-file folder.
  - **Storage.** Schema version 5 (D-067).
- **Reason:** A project can have a large folder the built-in list does not know (generated data, a cache). Exact names and root-anchored paths are the smallest rule that covers it, and the same validator as the secret list keeps the input rules in one place.

## D-066 Additive updates: `addDenyPaths` and `addWatchSkip`
- **Date:** 2026-11-07
- **Decision:** Builds the additive update that D-050 deferred. A project can get entries after it is created.
  - **Methods.** `_agmente/projects/addDenyPaths {projectId, denyPaths}` and `_agmente/projects/addWatchSkip {projectId, watchSkip}`, each returning `{project}`. Both are answered by the gateway (D-024) and start no agent.
  - **Refusals (`-32602`, nothing changed).** A missing `projectId`. A missing list, or a list that is not a JSON array of strings (`null` is refused, not read as empty). An unknown project: "unknown project". Any entry that fails the create rules for that list: the whole request is refused. A merged total over 32 entries: refused whole, with "holds at most 32 entries". The built-ins are not counted.
  - **Merge.** Case-insensitive, the spelling already stored is kept, duplicates are dropped, new entries are appended in the order sent. An empty list is accepted and changes nothing.
  - **Never removes.** The input type cannot express a removal. Built-ins are not in the stored list, so they cannot be removed by any request: the effective list is still built-ins first (`isSecretFor`, `secretExcludesFor`, D-050).
  - **Takes effect at once.** There is no cache of the effective list. `git/status`, `git/diff`, `git/log`, `turnDiff` and the watcher (each tick) read the project from the database, so the next call after the response uses the new list.
  - **Atomic.** The read, merge and write run in one transaction (D-067), so two adds at once cannot lose each other's entries.
  - **Audit.** `project_updated` with the project id. The entries are not logged.
  - **Not built.** Removing an entry (by design), and renaming or moving a project. An entry that is wrong has to be removed by editing the registry, which is a change for the owner and a new D-n entry if it is ever needed.
- **Reason:** A project registered before a secret pattern or a heavy folder was known could not get one without a new registration, which needs a new path. Making the update a merge with a cap, and making removal impossible in the input type, is the same argument as D-050: a client cannot weaken the list it adds to.

## D-067 Schema version 5, and one transaction for a project's lists
- **Date:** 2026-11-07
- **Decision:** Storage for D-065 and D-066.
  - **Schema version 5:** `ALTER TABLE projects ADD COLUMN watch_skip TEXT`, a JSON array, NULL when none. A version 1 to 4 database is migrated in place and keeps its projects, with no skip list. The migration tests that rebuild an old shape (versions 1, 2 and 3) now also drop `watch_skip`, as the version 4 change did for `push_tokens`. The schema 4 migration test is in `store/store_watch_test.go`.
  - **Reads.** Every project read uses one column list and one scanner (`projectColumns`, `scanProject`), so both lists are read the same way everywhere. `denyPaths` reads did not change.
  - **Update.** `Store.UpdateProjectLists(ctx, id, fn)` runs the read, the change by `fn`, and the write in one transaction. The store has one connection and `BEGIN IMMEDIATE`, so two updates run one after another. If `fn` fails, nothing is written. An unknown id returns nil without calling `fn`.
  - **No new table.**
- **Reason:** The additive methods read a list, merge and write it back. Without one transaction, two requests could each read the same list and the second write would drop the first's entries. The store already serialises writes, so the transaction costs nothing extra.

## D-053 APNs delivery: token auth with the standard library, a bounded queue, and one cleanup and retry rule
- **Date:** 2026-11-07
- **Decision:** The second half of PLAN 3.11, built without an Apple account. Supersedes nothing; it completes D-052's "not built" list except the entitlement, the device test and the real key.
  - **Auth.** `internal/push` signs an ES256 provider token (`BuildJWT`): header `{alg: "ES256", kid: <keyId>}`, claims `{iss: <teamId>, iat: <unix time>}`, the signature in raw 64-byte r||s form (RFC 7518 section 3.4). It uses only `crypto/ecdsa`, `crypto/x509` and `crypto/sha256`, so no dependency is added. The key is a PKCS#8 PEM P-256 `.p8`. The token is cached and rebuilt once it is 50 minutes old (`RefreshAfter`), inside the 20 to 60 minute window that PUSH-TESTING Part E gives from Apple's APNs provider documentation. That page was not re-read in this session: verify the window before the key is used.
  - **Transport.** `POST <base>/3/device/<token>` over HTTP/2 with `net/http` (`ForceAttemptHTTP2`, TLS 1.2 minimum, 15 s timeout), headers `authorization: bearer <jwt>`, `apns-topic`, `apns-push-type: alert`, `apns-priority: 10`, body from `push.Build` (D-038). The host is `sandbox` or `production` by the token's own `environment` (D-052). Defaults `https://api.sandbox.push.apple.com` and `https://api.push.apple.com`, overridable in the config.
  - **Answers (`push.Decide`, the whole policy).** 200 is sent. 410, or reason `Unregistered`, `BadDeviceToken` or `DeviceTokenNotForTopic`, deletes that token, but only while the stored token is still the one that was sent (`DeletePushTokenIfEqual`), so a stale answer cannot remove a fresh registration. 403 `ExpiredProviderToken` rebuilds the JWT and sends once more; a second such answer is a failure. 429 and 5xx are retried at most two times, after 500 ms and then 1 s. Anything else is `push_failed` with APNs' status and reason. A transport error is `push_failed` with reason `transport`; its error text is never kept, because it contains the URL and so the device token.
  - **Queue.** The agent path only enqueues, with a non-blocking send to a channel of 64 jobs. A full queue drops the push and audits `push_dropped`. One worker goroutine sends, with a context that `Shutdown` cancels. The server lock is never held during a send, and the event log's lock is held only to read one session's subscribers.
  - **Key and config.** `push` is optional; without it nothing is queued and no request is made (SPEC 6.3). The key file is refused at startup, and by dry run, when it is readable by group or others, is not a regular file, or does not parse as a P-256 PKCS#8 key. Errors name the file and the problem, never the key bytes (NFR-14). See D-055 for the config keys.
  - **Audit.** `push_sent` (identity, device, project, status, event), `push_failed` (status, reason), `push_token_removed` (status, reason), `push_dropped` (event), `push_enabled` at startup. None has a token, a key, a JWT or a payload.
  - **Tests.** The wire suite runs a fake APNs server on HTTP/2 over TLS in `test/apns-fake.mjs`: a throwaway P-256 key and certificate made at run time (Node's OpenSSL for the key; the certificate by `openssl req`, since LibreSSL's EC certificates use explicit curve parameters that Go rejects). The test checks the path, headers, topic, a provider token whose signature verifies against the public key, the payload size and content, the removal rules, the retry counts and the JWT refresh. Go unit tests cover the JWT, the key-file rules, `Decide` and the retry and refresh loop.
  - **Not verified:** Apple's live behaviour (the fake answers what Apple's documentation lists; the real answers are a device test, PUSH-TESTING Part E); whether Apple accepts a token from this key until a real `.p8` is used; the real key's permission handling on the host (verify with `ls -l` on the host).
- **Reason:** Standard library JWT and HTTP/2 keep the gateway at two dependencies (D-021, D-023). A bounded queue keeps a slow Apple from ever slowing a turn (NFR-1 and the agent path). One answer table makes the cleanup rule testable without a device.

## D-054 Push triggers, foreground suppression and the fan-out rule
- **Date:** 2026-11-07
- **Decision:** FR-23, PLAN 3.11.
  - **Events.** A turn that ends cleanly sends `turn_ended` ("Turn finished"). A turn that ends with an error sends `session_failed` ("Session failed") instead; that covers the agent exiting mid-turn and a refused prompt. A `session/request_permission` sends `approval_needed` ("Approval needed"). Each push is queued once per event, at the point the event is logged. A session id is required, so an approval with no session sends nothing.
  - **Who gets it.** Every stored token, from every identity. The gateway has one owner and every device of one identity sees the same projects (FR-25), so each device of the gateway is a target. The payload carries the project name, the session id and the event, nothing else (D-038).
  - **Foreground suppression.** A device whose socket is subscribed to that session (`_agmente/sessions/subscribe`, D-028) at the moment of sending gets no push. The check is per device: the same identity and device id. Another device of the same identity, and a subscription to another session, do not suppress it. A plain attached socket (no subscription) does not suppress either, so the rule is "the app is showing this session", not "a socket is open".
  - **Ordering.** The worker reads the subscribers when it sends, not when the event is logged, so a phone that subscribes after the event is logged still counts as foreground.
  - **Not done.** No retry of a push that was dropped from the queue; no collapse of pushes for one session (APNs `apns-collapse-id` is unset, so each event is kept by Apple up to its limit, as PUSH-TESTING Part F says).
- **Reason:** The owner's test is that the phone is told when it is away and not when it is looking (PUSH-TESTING Part E, steps 3 and 6). Checking at send time, not at log time, is the only way the rule holds when a phone reconnects during a turn.

## D-055 Push config: paths and ids only, a key-file rule, and a test-only trust file
- **Date:** 2026-11-07
- **Decision:** SPEC 6.3 gains one optional block, `push`. Its keys are `keyFile` (absolute path to the `.p8`), `keyId` (10 characters), `teamId` (10 characters), `topic` (the app's bundle id), and the optional `sandboxURL` and `productionURL` (https URLs with a host and no path, query or user). The config holds no key material and no secret. Unknown keys are refused.
  - **Test-only key.** `caFile` (absolute path) names a PEM CA that the gateway trusts for APNs requests, in addition to the system roots. It exists so the wire suite can point the gateway at a fake APNs server with a throwaway certificate. It is documented as test-only; a deployment leaves it out. The URL overrides are for the same purpose.
  - **Key-file rule.** Refused at start and in dry run when the file is group- or world-readable (any of mode `0o077`), is not a regular file, or does not parse as a P-256 PKCS#8 key. A file that is readable only by its owner is accepted (`chmod 600`).
  - **Config example.** `gateway/config.example.json` leaves the `push` block out, because dry run reads the key file and the example has no key. The block is described in SPEC 6.3 and in PUSH-TESTING Part E.
  - **Dry run** prints the push settings as ids and paths (`keyFile`, `keyId`, `teamId`, `topic`, the two hosts, `caFile`), or `"push": "off"`.
- **Reason:** A config that names a key by path keeps the secret out of the file (NFR-14). The owner-only rule is the usual one for private keys, and the gateway checks it itself because a readable key on a shared host is the failure this rule exists for. The test CA is the only way to point a real TLS client at a test server without changing the process's trust store.

## D-061 Signed file URLs: the files host, the token, and the key
- **Date:** 2026-11-07
- **Decision:** PLAN 5.3 (FR-38, NFR-12), filling in SPEC 6.2 `_agmente/files/url {projectId, path}` and the ARCHITECTURE 2.5 flow.
  - **Config.** A `files` block: `host` (required, lowercase host name, no port, no scheme), `ttlSeconds` (1 to 300, default 300, NFR-12), `maxBytes` (1 to 2^30, default 20 MiB), `secretFile` (optional, an absolute key file). Absent means the feature is off, and `_agmente/files/url` answers `-32000` "file URLs are not enabled". `extensions` now has `"files"`. A `key` or `secret` inside the block is refused: the key never sits in the config file (NFR-14).
  - **Key.** From `secretFile` when set: a regular file with no group or other permission bits (chmod 600 or stricter), at least 32 bytes, trailing CR and LF dropped. Otherwise 32 random bytes from `crypto/rand`, per process: URLs stop working on a restart, which is acceptable at a 300 s lifetime. The error text never shows the key. Dry run shows the key source, never the key.
  - **Token.** `base64url(payload) "." base64url(HMAC-SHA256(key, payload))`, with payload the JSON `{"p": projectId, "r": relative path, "e": expiry in Unix seconds}`. The MAC is compared with `hmac.Equal`. The token is at most 2048 bytes and has exactly one dot.
  - **URL.** `https://<files.host>/f/<token>`. The gateway listens on plain loopback behind Caddy (ARCHITECTURE 3), so `https` is the scheme the phone uses, not what the gateway speaks. Caddy must route `files.host` to the gateway with the same listener (verify in deploy; not built here).
  - **Host.** A request is on the files host when its Host header, without any port, equals `files.host` (case-insensitive). Only there does `/f/` reach the file handler. Any other Host gets the normal path: `/f/...` is a 404 and never reaches the handler (D-062). An upgrade on the files host gets 403 with audit `reject` reason `files_host`, so the ACP socket is never answered there.
  - **Errors at signing.** `-32602` with a fixed message for path, outside_root, not_found, not_regular, secret, type and too_large (D-063). The signing audit is `file_refused` with the same reason.
- **Reason:** The architecture puts file previews on a host separate from the ACP endpoint, so a hostile page cannot reach the ACP socket or its cookies. A stateless HMAC token needs no store and no cleanup. A key file lets an operator keep the key across restarts without putting it in the config (NFR-14). Keys and tokens never reach the audit log.
- **Not verified:** whether Caddy's client certificate requirement (D-003) applies to the files host. A WKWebView or image loader cannot present a client certificate unless the app does. This is a deployment question for phase 5.4 and the device test; the gateway does not depend on the answer.

## D-062 What the file handler serves, and the response headers
- **Date:** 2026-11-07
- **Decision:** PLAN 5.3, FR-38, FR-39 (the headers the preview needs), T-37.
  - **Methods.** GET and HEAD only. Any other method is 405 with `Allow: GET, HEAD` and audit `file_refused` reason `method`. HEAD sends the same headers and no body.
  - **Paths.** Exactly `/f/<token>` with one token segment, on the files host. Anything else is 404 with no audit line.
  - **Types.** Allow-list by lowercase extension: png `image/png`; jpg and jpeg `image/jpeg`; gif; webp; heic `image/heic`; html `text/html; charset=utf-8`; css; js `text/javascript`; json `application/json`; txt and md `text/plain; charset=utf-8`; svg `text/plain; charset=utf-8`. SVG is text, so a script in it never runs in the preview. A file with any other extension is refused at signing (reason `type`).
  - **Headers, on every response.** `X-Content-Type-Options: nosniff`, `Cache-Control: no-store`. On a served file also `Content-Disposition: inline` and `Content-Length`. On HTML only, `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:`. No `Set-Cookie`, no CORS header, and the request's cookies and other headers are never read.
  - **Size.** A file over `files.maxBytes` is refused (413, reason `too_large`), both at signing and at serving. The body is copied with the size taken from the open file, so a file that grows after the check is never sent past the cap.
  - **Refusals.** HTTP 403 for a bad token, an expired URL, a path that fails the serve-time check, and a changed file; 404 for a missing file; 405 for a method; 413 for size. Each refusal is audited as `file_refused` with a reason from this fixed set: `method`, `token`, `expired`, `project`, `path`, `outside_root`, `not_found`, `not_regular`, `secret`, `type`, `too_large`, `changed`.
  - **Expiry.** A URL whose expiry is at or before now is refused. The check is at serving, every time.
- **Reason:** A preview is a page the agent wrote, so it is untrusted (ARCHITECTURE 3, item 5). The type allow-list and nosniff stop a file being sent as something the browser runs. The CSP stops HTML from loading anything except what the preview allows. No cookies means a hostile page on the files host has nothing to ride on.
- **Not built here:** the app's WKWebView policy (FR-39, T-38) and whether the app's image loader uses these URLs (PLAN 5.4 and 5.5).

## D-063 Paths: syntax, deny-list, and the realpath checks at signing and at every serve
- **Date:** 2026-11-07
- **Decision:** PLAN 5.3 (FR-38, FR-30, D-035, D-050).
  - **Syntax** (`validRelPath`). Not empty, at most 1024 bytes, valid UTF-8, no leading `/`, no control character (Unicode category Cc) and no backslash, and no empty, `.` or `..` component. A trailing `/` is refused. Non-ASCII names are allowed.
  - **Deny-list** (`isSecretFor`, the same function as the git methods, D-050). Checked twice: on the path as the phone named it, and on the path the file really has after symlinks are resolved. So a link named `.env` to a harmless file is refused as a secret, and a harmless name to a `.env` file is refused too. No new matching code.
  - **Containment.** The project's realpath is resolved, then the path's realpath (`EvalSymlinks`, so a symlinked final component and symlinked parent folders both count). The result must be the project root or inside it (`isInsideRoots`). A link to `/etc/passwd`, or a folder link to a folder outside, gives `outside_root`.
  - **Kind.** `os.Stat` of the real path must be a regular file: a folder, pipe or device gives `not_regular`. A broken link gives `not_found`.
  - **At every serve.** The token's path is checked again with all of the above, and the file is opened. Then the path is resolved a second time and must still be inside the project, not secret, and must name the same file as the open descriptor (`os.SameFile`). A change between the two checks gives `changed`.
  - **Residual.** A race inside the few microseconds between the second resolution and the `os.Open` can still change which file a path names. It is narrowed by the post-open `SameFile`, and not closed. Closing it fully needs a directory-fd walk (`openat` with `O_NOFOLLOW` at each component), which Go's standard library does not offer for this case without more code. Not built; recorded here.
- **Reason:** FR-38 names symlinks and parents. A check at signing alone is the TOCTOU hole the owner asked to test, so the serve-time check repeats the same function. Reusing the deny-list function keeps one matching rule for every surface (D-050).
- **Verified:** wire tests for `../`, absolute, `a//b`, backslash, NUL, newline, a symlink to `/etc/passwd`, a folder link to outside, a symlink swapped after signing (to outside and to `.env`), a secret-named link, a folder, a named pipe, a missing path, `.env`, a `denyPaths` entry, and an unsupported type. Mutation checks in RESULTS.

## D-064 Audit for file events, and the tests for the files block
- **Date:** 2026-11-07
- **Decision:** PLAN 5.3, FR-9, NFR-14.
  - **Events.** `file_url_issued` {project, path} when a URL is signed. `file_served` {project, path, client} when a body starts. `file_refused` {project or none, path when valid, reason from the D-062 set, status}. A refused token gets no project or path, because nothing in it is trusted.
  - **Fields.** The audit line gets one new key, `path`: a project-relative path, never absolute, never a token and never file content. Audit tests check that no line holds the token, a file's content or a key.
  - **Config tests.** `config/files_test.go`: defaults, a bad host, a ttl over 300, a key inline, a key file with group or other bits (the error does not show the key), a key shorter than 32 bytes. The dry-run test checks that a ttl of 301 and a key in the config are refused with the field name.
  - **Go unit tests.** Token round trip; a changed payload, a changed signature, a truncated or split token, a token from another key, an oversize token and missing claims are refused; the path rules; the type allow-list.
  - **Wire tests:** `test/files.test.mjs` (14 tests, T-37 and the rest of PLAN 5.3). The HTTP side uses `node:http` with a chosen Host header, so the wire tests reach the same listener as the phone. `supervisor.test.mjs` now expects `files` in the extension list.
- **Reason:** The phone can ask for any file in a project, so the audit trail is the record of what was reachable, and it must not become a place where secrets are copied.

## D-070 Plan, session title and usage updates: parsed defensively, shapes marked "verify"
- **Date:** 2026-11-07
- **Decision:** PLAN 4.7 (FR-33).
  - **Plan.** `plan` (ACP's kind, schema `entries: [{content, priority, status}]`) and `plan_update` (Bob's name) both become `ACPSessionUpdateEvent.planUpdate(entries:)`, capped at 200 entries. Entry text is read from `content` (string or `{text}`), then `title`, `text` or `description`. Status `pending`, `in_progress`, `completed`; any other value is kept as `unknown` and shown as pending. An empty list hides the plan. `plan_removed` clears it. **verify:** Bob 2.0.9 sends `plan_update` and `plan_removed`; no fixture or recorded payload shows their shape, so the list keys (`entries`, `plan`, `items`, `steps`) are a guess.
  - **Title.** `session_info_update` gives `sessionInfo(title:)`, trimmed. An absent or empty title leaves the last one in place. The gateway already reads the same field for its index (D-030).
  - **Usage.** `usage_update` is read from `used` or `usedTokens`, `size` or `contextSize`, and a cost as `cost: {amount, currency}` or `costAmount`/`costCurrency`. Negative, non-finite or string values are dropped; a currency over 8 characters is dropped. **verify:** no recorded Bob `usage_update`; the keys are unconfirmed. An update with no usable field emits nothing.
  - **Where shown.** The plan is a collapsible checklist above the transcript (`SessionPlanView`); usage is a small line under the composer (`SessionUsageFooter`); the navigation title uses the agent's title when present, else the session summary's.
  - **Unknown fields never fail.** Every parser returns an empty or nil result for an unexpected shape.
- **Reason:** The ACP schema names the plan shape, but Bob's own kinds and the usage shape are not in any fixture. Reading defensively keeps the app up when Bob changes a key, and "verify" marks what a live run must confirm.

## D-071 Start mode from the project's default, sent as `_meta["bob/mode"]`
- **Date:** 2026-11-07
- **Decision:** PLAN 4.8 (FR-34).
  - **Start mode.** When a new session is created on a gateway, the app calls `_agmente/projects/list`, finds the deepest project whose path is the session's cwd or contains it, and sends its `defaultMode` as `_meta["bob/mode"]` on `session/new`. No matching project, no default, or a failed lookup sends no `_meta` and starts the session as before. A lookup failure never fails the session. Only gateway servers send it: `bob/mode` is a Bob key and the gateway fronts Bob only.
  - **Mode picker.** Unchanged in behaviour: the picker shows only when the session reports `availableModes` (it sits in the composer row), it calls `session/set_mode` through the existing path, and `current_mode_update` updates it. The gateway already tracks the mode for reopens (D-029).
  - **Gateway.** Forwards `_meta` on `session/new` as it does every param; a wire test (`gateway/test/start-mode.test.mjs`) shows the fake agent starts in the sent mode and in `agent` without `_meta`. No gateway code changed.
  - **Not done:** a per-project picker of the default mode (only the stored value is read).
- **Reason:** The owner set the default per project (D-024 `defaultMode`), and Bob reads `bob/mode` at session start (plan notes). Looking the project up at creation keeps the cache and the gateway the only source of the value.

## D-072 Authentication required: its own text, no key entry in the app
- **Date:** 2026-11-07
- **Decision:** PLAN 4.9 (FR-35, T-35). `ACPAgentErrorText` maps JSON-RPC error `-32000` whose message contains "Authentication required" to the fixed text "Bob needs authentication. Set BOB_API_KEY on the gateway host.". Any other error keeps its own text. It is used wherever a session create, load, resume or prompt error reaches the transcript (`ServerViewModel` failure paths and `formatPromptError`). The app offers no field for a key, and it never sends one.
- **Reason:** RESULTS 2026-11-05 records Bob's answer with no key. The fix is a setting on the gateway host, so the app says so rather than asking for a secret. Matching on the code and the message together keeps other `-32000` errors unchanged.
- **Not verified:** the text on screen. T-35 needs a Bob run with no key shown in the app; the mapping is unit-tested only.

## D-073 `session/delete` on the agent first, then the device; a failure keeps the session
- **Date:** 2026-11-07
- **Decision:** PLAN 4.10 (FR-36).
  - **Capability.** `sessionCapabilities.delete` in `initialize` sets `AgentCapabilityState.deleteSession`. Bob 2.0.9 advertises it (fixture `bob-initialize-2.0.9.json`).
  - **Flow.** "Delete Session" (existing confirmation dialog) sends `session/delete {sessionId}` when the capability is set and the session exists on the agent (not a placeholder that was never created). On success the session is removed from the list, its chat and its storage, as before. On an error, or when not connected while the capability is set, nothing is removed locally and an alert shows the text from `ACPAgentErrorText`. Without the capability, or for a placeholder, the local removal is unchanged.
  - **Gateway.** Forwards `session/delete` and, when the agent accepts it, removes the session from its index, events and read markers (D-030, `sessions.test.mjs`). No gateway change.
- **Reason:** Deleting only locally would leave the session on Bob and in the gateway index, where it still shows. Removing locally only after the agent accepts means a refusal never hides a session that still exists.

## D-074 Agent HTML runs in a sandboxed web view with no network and no bridge
- **Date:** 2026-11-07
- **Decision:** PLAN 5.4 (FR-39, T-38). `Agmente/Fork/Preview/AgentHTMLPreviewController.swift` (the `WKWebView` owner and its delegates), `AgentHTMLPreviewSheet.swift` (the sheet and the representable) and `AgentHTMLSchemeHandler` in the controller file. Layers, each of which alone stops a network load or a script bridge:
  1. `WKWebsiteDataStore.nonPersistent()`; `isInspectable = false`; link previews off.
  2. A compiled `WKContentRuleList` (`block` on `.*`, then `ignore-previous-rules` for `agmente-preview:`, `about:` and `data:`), added to the user content controller before the first load. If it does not compile, nothing loads (fail closed).
  3. The Content-Security-Policy in the document (D-075).
  4. JavaScript off by default. `WKWebpagePreferences.allowsContentJavaScript` is set for each navigation from the view's scripts setting. Turning scripts on loads the document again under the new policy.
  5. `WKNavigationDelegate` allows one main-frame load of the base URL and in-page fragments. Every other navigation is cancelled. A tapped link is passed to the sheet as text and never opened.
  6. `WKUIDelegate`: no new windows, alerts and confirms auto-answered, no file picker, camera and microphone denied.
  7. No `WKScriptMessageHandler`, so the page has no bridge to the app.
  - The base URL is `agmente-preview://page/`. The scheme handler fails every request. The document is supplied with `loadHTMLString`, so the handler serves nothing; the spec's "serves the document" is met by `loadHTMLString`, not by the handler.
  - Geolocation: WebKit on iOS has no delegate for it. It is not blocked by code; the app has no location usage text, so it is not expected to be prompted (unverified on device).
- **Reason:** Agent HTML is untrusted input (ARCHITECTURE trust boundary 5). No single layer is trusted: the test measures what each one does (RESULTS 2026-11-07).

## D-075 The preview document: policy first, structural tags removed from agent HTML
- **Date:** 2026-11-07
- **Decision:** PLAN 5.4 (FR-39). `AgentHTMLSecurity.wrap(_:scriptsEnabled:)` in `Agmente/Fork/Preview/AgentHTMLDocument.swift` builds the document string.
  - The policy is `default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'`, and `script-src 'unsafe-inline'` is added only when scripts are on. `base-uri` and `form-action` are added to the brief's policy: they do not fall back to `default-src`, so without them a base tag or a form could still reach the network.
  - The policy is the first element of the head, before any agent content. The agent's HTML goes in the body.
  - Every `<!doctype>`, `<html>`, `<head>`, `<body>`, `<base>` and `<meta>` tag in the agent's HTML is removed, so an agent cannot set a base URL, a second policy, a refresh, a charset or a new document structure. `<link>` is left: its loads are blocked by the policy and the rule list (D-074). Removal repeats until nothing matches, so a tag that appears only after another is removed is removed too (`<<base href>base href>`).
  - Agent HTML over 1 MiB is refused (`maxSourceBytes`).
  - Limit: the removal is textual, not an HTML parse. A `<meta` or `<base` string inside agent JavaScript or a comment is also removed. That changes the agent's text, never its network access.
- **Reason:** The unit tests in `AgentHTMLDocumentTests` check: one policy even when the agent sends its own, no base tag, the `</head>` trick, nested tags, and the policy's scripts setting. The policy is enforced by WebKit, not by the removal; the removal is a second layer that keeps the document as the code describes it.

## D-076 Chat wiring: fenced html blocks and `text/html` resources get a preview row; nothing is fetched
- **Date:** 2026-11-07
- **Decision:** PLAN 5.4 (FR-39, D-060).
  - A fenced ```` ```html ```` (or `htm`) block in an assistant message gets its own row after the message text, with an "HTML preview" button (`HTMLFenceScanner`, at most 8 blocks per message). The row is built in `ChatEntryMapper` from the message text, so it is also present after a restored chat.
  - A `resource` block with MIME `text/html` (parameters allowed) becomes `ForkMediaItem.Content.html`: the `text`, or the base64 `blob` decoded as UTF-8. Both are size-capped at 1 MiB (the base64 length at its own cap). A malformed or oversized one is a placeholder row. A `resource_link` is still a plain row and is never fetched (PLAN 5.3 is the gateway's signed URL work).
  - The button opens `AgentHTMLPreviewSheet` through `ChatEntryActionHandlers.onPreviewHTML`, in both `SessionDetailView` (ACP) and `CodexSessionDetailView`. The sheet has the scripts toggle (off by default), the label "Sandboxed preview: no network", a line showing a tapped link as text, and Done.
  - The chat row shows no HTML source; only the sandboxed preview displays it.
  - ACP and Codex share the mapper and the row, which is a view of content, not protocol logic. Codex has no inbound media (D-060), but its markdown can hold an html fence, so Codex gets the same row.
- **Reason:** The brief's places where agent HTML can appear. Taking the text from the message keeps one code path for both protocols and for restored chats.

## D-077 T-38 runs in the real web view against a loopback probe; the probe must see a control request
- **Date:** 2026-11-07
- **Decision:** PLAN 5.4 check (T-38), `AgmenteTests/AgentHTMLPreviewTests.swift`.
  - The hostile page sends requests through `fetch`, `XMLHttpRequest`, an external `<img>`, a relative `<img>` under a hostile `<base>`, a stylesheet `<link>`, an `<iframe>`, a form submit (after a timer), `window.open`, `location =` top navigation (after a timer), and a `<meta http-equiv="refresh">`. The `<meta>` also tries to replace the policy.
  - The probe is a POSIX TCP listener bound to `127.0.0.1` on an ephemeral port (no dependency). It counts accepted connections and bytes. Pass means 0 accepted connections, with scripts off and with scripts on.
  - The page loads in a `WKWebView` in a `UIWindow` in the unit-test host. Each load waits at most 15 s. After it finishes, the test waits 3 s for timers and requests.
  - A control test loads the same page in an unrestricted `WKWebView`, and must see at least one connection. Without it, zero counts could mean the probe is blind. The control polls for up to 15 s, because a cold WebKit start can take several seconds.
  - Mutation checks are recorded in RESULTS 2026-11-07. Removing the rule list alone, or allowing all navigation alone, does not fail T-38 (each is covered by another layer). Both together fail the scripts-on case. All three layers removed fail both cases.
- **Reason:** T-38 has to exercise the real engine, and only a control proves the detector works. Recording which layer catches what is more useful than a single pass.

## D-078 A subscriber leaving counts as activity for the idle stop
- **Date:** 2026-11-07
- **Decision:** Refines D-032. When a socket closes, each session it was subscribed to is touched (the project's and that live session's last-activity time are set to now) before the idle check can see the project without a subscriber. The idle time then runs from the moment the subscriber left. The check interval and everything else in D-032 stay as they were.
- **Reason:** D-032 said a stop comes between 1 and 1.25 idle times after the last activity, but a subscriber was only counted as activity at the periodic check (every quarter of the idle time). A subscriber leaving just after a check was therefore followed by a stop after as little as 0.75 idle times. Four agents saw `T-46 a subscriber keeps the container running` fail under load for this reason, and an A/B on the untouched base failed 2 of 5 runs. Found by the test, not by a new requirement; the test was not changed.

## D-079 Apple `container` runner beside Podman; git through `container exec` into the agent's container
- **Date:** 2026-11-07
- **Decision:** Adds `runner.kind: "apple"` (config keys `image`, optional `container`: an absolute path to the `container` CLI, optional `containerUid`/`containerGid`). Podman stays as the Linux runner and as the Mac fallback; `host` stays for tests. The `runner` interface does not change; `appleRunner` (`gateway/internal/server/runner_apple.go`) implements it.
  - **Agent.** `container run -i --rm --progress none --name agmente-<projectId> --init -u U:G`, with the project folder and home mounted at their host paths, the same allow-listed environment rule as Podman (names only), and the image. The container name is the lock (D-015). Before start the gateway refuses if `container list --quiet` already lists the name. `start` returns once the name is listed as running.
  - **Git.** When the project's agent container is up, every git command runs as `container exec -i -u U:G -w <project> -e <git env> agmente-<projectId> git ...`, so it never starts a container of its own. When no agent is up (after an idle stop, before the first start), git gets a one-off `container run --rm --network none`, as Podman does. The git environment is the same whole environment as D-034, never the agent's allow-list.
  - **No `keep-id`.** Apple container has no user-namespace mapping. The bind-mounted 0700 folders are writable by uid 10001 (checked in RESULTS 2026-11-07), so no mode is loosened.
  - **Never inspect.** `container inspect` and `container list --format json` print environment values. The runner uses only `container list --quiet` and `run`/`exec`/`stop`.
  - **Progress.** Every `run` passes `--progress none`, so progress text never reaches the stream the gateway reads.
- **Reason:** The owner chose `container exec` for git on 2026-11-07. Measured on this Mac (RESULTS 2026-11-07): 0.21 s per git call through `exec`, against 1.12 s for `run --rm`, and warm starts of about 1.2 s. Memory is lighter than the Podman VM for a few projects (734 MiB plus about 35 MiB per idle container, against 2.8 GB for the Podman VM with the same containers), but that is idle `sleep` only; real Bob memory is measured in step 3.
- **Not decided here:** whether the Apple runner becomes the Mac default (after the live run and the benchmark); the Podman 126 retry is not applied to Apple (no equivalent failure seen).
- **Known gap:** a timed-out `container exec` may leave the git process running inside the agent container, because killing the CLI does not signal the process inside. Git runs with a 5 s limit; the fix is to find and kill the process by name (to be tested in step 3).

## D-080 Apple runner: timeout cleanup inside the container, `runner.dns`, and the benchmark result
- **Date:** 2026-11-07
- **Decision:** Completes D-079 in migration step 3.
  - **Timeout cleanup.** A git call that times out or exceeds the output cap is killed inside the agent container, not only as the CLI. Each exec'd git carries a random `AGMENTE_EXEC=<id>` in its environment. The gateway runs a `sh` script in the container that finds processes whose environment holds that marker (through `/proc`, which procps does not need) and kills them. The cleanup runs at the moment of the kill, before the output is drained: a process the CLI kill does not reach keeps the output pipe open, and cleaning up after the pipe closes would wait for it. `runCapped` takes optional kill hooks for this; the Podman and host callers pass none.
  - **`runner.dns`** (optional IP address, Apple runner only). It is passed as `--dns`. Without it, on the Mac tested, the container's default resolver (192.168.64.1) did not answer, so Bob could not reach its service (Bob's own log: `fetch failed`). With `1.1.1.1` both the lookup and the HTTPS call worked. A set value sends lookups to that server unencrypted; the owner chooses it.
  - **Image name.** Apple `container` resolves a short image name as a Docker Hub name. The Apple runner needs the full name the image is stored under, for example `localhost/agmente-bob:2.0.9`, in `runner.image`.
  - **Result, not "lighter" for Bob.** See RESULTS 2026-11-07 (step 3): with real Bob, Apple's cold start is slower than Podman's by about 0.7 s, and one idle Bob container adds about 830 MiB of host memory on Apple, against about 31 MiB on top of Podman's shared VM. Podman's VM holds about 2.8 GB before any container starts. The migration's premise, that Apple is lighter, holds only for a few projects and only for the idle baseline. Decision for the owner: whether to keep Podman as the Mac default until the per-container memory is reduced (the VM's memory limit, the image size and Bob's footprint are candidates), or to switch anyway. Not decided here; the Apple runner is opt-in through config.
- **Reason:** The timeout gap would leave a git process running in the agent container after a timeout, and the test for it failed until the cleanup ran at kill time. The DNS problem stopped Bob on the Mac, so it is a required setting there. The benchmark numbers are the reason the premise changed.

## D-081 Apple runner DNS: the Mac's own resolver, not a public one
- **Date:** 2026-11-07
- **Decision:** Supersedes the DNS choice in D-080 (`1.1.1.1`). `runner.dns` is set to the Mac's own IPv4 resolver, the address `scutil --dns` lists first (on the Mac tested, the home router, `192.168.86.1`). Tested from inside the container: the resolver answers, and the HTTPS call to Bob's API returns HTTP 400 from the endpoint (reachable, unauthenticated request). The vmnet default (`192.168.64.1`) did not answer, and the Mac's IPv6 resolver did not either. The live harness (`gateway/scripts/live-bob.mjs --runner apple`) takes this default when `--dns` is not given. The address is specific to a network: a deployment sets its own `runner.dns`.
- **Reason:** A public resolver receives every lookup from the containers in clear text. The Mac's own resolver is already the one the Mac trusts, so no new party sees Bob's hostnames. The value is not hard-coded in the config example, because it differs between networks: the example carries a placeholder (D-082).

## D-082 Mac config: a separate example file for the apple runner
- **Date:** 2026-11-07
- **Decision:** `gateway/config.mac.example.json` is the example for a Mac on the `apple` runner. `gateway/config.example.json` stays the Linux example on `podman`. Both have the same shape, so a deployment copies one file and changes the paths, the token and the runner block. The Mac example uses `localhost/agmente-bob:2.0.9` (the full image name), `runner.container` set to `/opt/homebrew/bin/container`, and a placeholder `runner.dns` (`192.168.1.1`) that must be replaced with the Mac's own resolver (D-081). The setup steps are in `docs/MAC-SETUP.md`.
- **Reason:** One example per runner keeps each file valid as written (`--dry-run` passes on the Mac example with the paths changed to a temporary folder). A single file with both runners would make the user delete half of it, and a wrong runner in the config would only show at start.

## D-083 NFR-15 accepted as a miss under the Apple runner at concurrency
- **Date:** 2026-11-07
- **Decision:** The owner accepts that NFR-15 (cold start at most 3 s p95) is not met when several projects start at once on the Apple runner. Measured: single project about 2.4 s median; 8 concurrent projects about 9.2 s median (RESULTS 2026-11-07, concurrency entry). The single-project case meets the target. No further work on start cost is planned for now.
- **Reason:** The Apple runner was chosen because Podman's fixed VM was at its memory limit (D-079). Reducing concurrent start cost is a separate investigation that the owner has not asked for.

## D-084 MCP servers: the phone owns HTTP and stdio entries; `mcp.json` only gets `disabled`
- **Date:** 2026-11-07
- **Decision:** The app keeps its own list of MCP servers (FR-40) and sends it in `session/new` and `session/resume`. Entries may be HTTP or stdio (owner decision 5). The gateway never writes an HTTP server into `mcp.json`. FR-41 (`_agmente/mcp/set`) only sets `disabled` on a server that already exists in `mcp.json`, and refuses `alwaysAllow` (D-086). MCP headers travel only inside `session/new` or `session/resume`, are held in gateway memory for the life of the session, and are never written to disk or logged (P2: Bob does not persist them at debug level).
- **Reason:** One owner for each server avoids two sources that disagree. Writing HTTP entries into a git-tracked `.bob/mcp.json` would show in `git/status`. P1 and P3 showed that a session entry overrides `disabled` on disk and that repo and session entries merge by name.

## D-085 Bob's config and skill files: written from the host, never through exec
- **Date:** 2026-11-07
- **Decision:** The gateway reads and writes `<project>/.bob/mcp.json`, `<home>/.bob/settings/mcp.json` and `<project>/.bob/skills/<name>/SKILL.md` directly on the host, through the project folder and the home (the bind mounts). It never runs `container exec` or any repo code for these files. Each path passes the D-063 rules: realpath inside the project or home, no symlink in any component, and a size cap. Writes are atomic (temp file in the same folder, `O_EXCL`, fsync, rename). The mode is 0600.
- **Reason:** P4 showed that host writes show inside a running container within about 1 s on Apple and about 5 s on Podman (atomic replace), and that the container user can read and write the files. A write needs no container start.

## D-086 `alwaysAllow` is refused; stdio entries from the phone are allowed with a warning
- **Date:** 2026-11-07
- **Decision:** Two parts, from the owner's answers on 2026-11-07.
  1. Stdio entries from the phone are allowed (owner decision 5, changed). The app shows a warning that the server must be configured. The command runs inside the project container as the project user, never on the host. The gateway never logs a stdio entry's arguments or env values, and passes its env only to that container.
  2. `alwaysAllow` is refused by the gateway, in both the phone's list and `_agmente/mcp/set`. This keeps D-009. The owner asked to allow `alwaysAllow` because the environment is sandboxed. That would have the gateway approve tool calls in advance, which D-009 forbids. Not built until the owner confirms the override in writing; a new decision supersedes this entry if they do.
- **Reason:** P3: `alwaysAllow` in either `mcp.json` skips the permission prompt for those tools. The phone's approval is the last control before a shell.

## D-087 Skill files: name rule, size cap and scope
- **Date:** 2026-11-07
- **Decision:** Skills are project-scoped only (owner decision 6). The name is lowercase kebab-case, at most 64 characters (`^[a-z0-9]+(-[a-z0-9]+)*$`, the rule Bob applies to the directory name, P6). The content cap is 64 KiB, the gateway's own rule (owner decision 8); Bob has no size limit (P6). Frontmatter `name` is not used; the directory name is the name. Audit events `skill_put` and `skill_deleted` carry the name, project and byte count only.

## D-088 The gateway keeps each live session's MCP list and uses it on its own load
- **Date:** 2026-11-07
- **Decision:** The gateway keeps, per live session, the `mcpServers` list the phone last sent, in memory. When it sends its own `session/load` (after an idle reload or an agent restart, D-032 and D-029), it sends that list, not `[]`. Changes the gateway's own load, which currently sends an empty `mcpServers` (`supervisor.go`, the load call). An empty list would drop HTTP servers (F-23). D-029 and D-032 are otherwise unchanged.
- **Reason:** The gateway's idle stop would otherwise silently remove the phone's servers.

## D-085a Amendment: file modes for Bob's config and skill files
- **Date:** 2026-11-07
- **Decision:** D-085 said mode 0600 for every atomic write. Amended: `mcp.json` files keep 0600 (they hold server URLs and flags, never header values). Skill files (`SKILL.md`) use 0644, because they hold no secrets and Bob, which runs as the container user, must be able to read them under every runner (P4). Folders are 0700 for `.bob` in the home and 0755 for skill folders.
- **Reason:** The skill agent found that 0600 on a host file owned by the owner's uid may not be readable by the container user under every runner; the probe did not test that case directly. 0644 is the conservative choice for non-secret content.

## D-088a Reconciliation: the kept MCP list lives until the session is closed or the gateway stops
- **Date:** 2026-11-07
- **Decision:** D-088 said the gateway keeps the list for each live session. As built (6A.1): the list is kept until the phone closes or deletes the session, or the gateway stops. It is not dropped when the agent process exits, because restart and idle-stop reloads need it. It is never written to disk (D-084). A phone `session/resume` updates the kept list; Bob sees the change on the next reload or `session/new` (F3).
- **Also as built:** the phone's entries are validated strictly. Unknown keys are refused; an entry without `type` is stdio; `http` is allowed only to loopback (D-019). `alwaysAllow` is refused (D-086).
- **Reason:** The restart path needs the list to survive the agent process. The strict validation keeps the new surface small.

## D-089 Owner override of D-009 for MCP `alwaysAllow` from the phone (option c)
- **Date:** 2026-11-07
- **Decision:** The owner chose option (c) of the decision-4 brief in writing: "Lets go with (c)". This supersedes D-009 for one case only: the phone may send `alwaysAllow` for an MCP server's tools, in the session's `mcpServers` list and through `_agmente/mcp/set`, so those tools run without the phone's approval prompt. The gateway passes the list through after validation. It still never approves a tool call on its own, and the approval queue (FR-22, D-031) is unchanged for every other request. This supersedes the refusal in D-086 (part 2). CLAUDE.md's rule "The gateway must never approve a tool call" is amended to name this exception.
- **Known effect, recorded by the owner's choice:** a tool named in `alwaysAllow` runs with no prompt. Probe P3 showed this from a project file, a home file and the session list (verify the session list). Any writer of those files can grant it: the phone, the owner by hand, a git clone that tracks `.bob/mcp.json` (verify), and Bob itself, since the container user can write both (P4). The sandbox (one container per project, its own folder and home mounted, allow-listed environment only) limits the damage to that project. It does not stop writes to the project or network access from inside the container.
- **Reason:** the owner judged the environment sandboxed and accepted the risk after the brief (decision4-brief.md, options a to c).
- **Revisit:** if a cloned repo is ever run on this gateway, or a non-owner device is added (FR-25), this decision must be reopened first.

## D-086a Superseded in part by D-089
- **Date:** 2026-11-07
- **Decision:** D-086 part 2 (refusal of `alwaysAllow` from the phone) is superseded by D-089. Part 1 (stdio entries allowed with a warning) stands.

## D-090 Elicitation: the gateway relays the agent's form to the phone and never answers it
- **Date:** 2026-11-07
- **Decision:** The gateway advertises `clientCapabilities.elicitation.form` to Bob (the `{}` rule in D-026 changes for this one capability; `url` is not advertised). An agent `elicitation/create` in form mode is relayed to the subscribers of its session as `_agmente/event` with a gateway id `agmente-elic-<hex>`. The phone answers with `_agmente/elicitation/answer {elicitationId, action, content?}`; the first answer goes to the agent under the agent's own id, a later answer gets -32001 "answered elsewhere" (the approvals rule, D-031). On timeout (the approval timeout, D-031) the gateway sends `{action: "decline"}`, never accept and never content. An open elicitation keeps the agent running for idle purposes (D-020 rule). Content is forwarded only with `accept`; its values must be string, number, boolean or arrays of strings. Audit records the action only.
- **Reason:** FR-44 needs Bob's licence and elicitation forms in the app. The gateway must not answer them itself (D-009 spirit) and a timeout must refuse, not agree.
- **Unverified:** the request shape comes from the ACP SDK copy in the npx cache, not the repo's pinned spec (verify). No live Bob elicitation has been seen (T-45 is blocked on a non-internal account).
- **Known gaps:** only subscribed sockets receive the request; `session/cancel` does not answer an open elicitation; the session index does not show awaiting_approval for elicitations; non-form modes are refused.

## D-091 Folder creation from the phone: `createFolder` on `projects/create`, a roots list, and the folder rules
- **Date:** 2026-11-07
- **Decision:** Owner decision A: the phone makes a new project folder inside a configured root (`projects.roots`). Picking an existing folder is unchanged (D-024, D-030).
  - **Request.** `_agmente/projects/create` takes an optional `createFolder` (a JSON boolean; anything else is `-32602`). Absent or `false` is the path-based call, unchanged. `true` makes `<path>/<name>` and registers it. In folder mode `path` is the parent folder and `name` is both the new folder's name and the project's name. Chosen over a separate method so the request keeps its shape and the registration, duplicate check, HOME, trust entry and audit event are the same code (`registerProject`).
  - **Roots.** New read-only method `_agmente/projects/roots` returns `{roots}`: the configured roots that exist, as realpaths. The phone needs it to know where a folder may go. It is not added to `extensions`; an older gateway answers `-32601`, which the app shows as the error text.
  - **Name rules.** 1 to 64 bytes, ASCII letters, digits, space, dot, hyphen and underscore only. Not starting with a dot. Not starting or ending with a space (a refinement the owner did not list; trimming is refused rather than done). The name is used exactly as sent. A slash or backslash is not in the set, so a valid name is one path component. ASCII only, so two spellings that differ by Unicode normalisation cannot name two folders on macOS.
  - **Parent rules.** Absolute, and clean: no trailing slash, `.` or `..`. Its realpath must equal the path sent, so a symbolic link anywhere in it is refused, including a root configured through one (roots are resolved at start; configure them as real paths). The realpath must be a directory, and a root or inside one.
  - **Name must not exist.** Checked with `lstat`, so a file, a folder, a symbolic link, even a dangling one, counts. A project already registered at the target path is refused before anything is created (a folder deleted from disk is not made again).
  - **Creation.** `mkdir` then an explicit `chmod 0755`, so the umask cannot change the mode. The created path is checked again after creation (realpath equal, inside a root); a failed check removes the new folder. If registration fails, the folder this call made is removed (an empty folder only).
  - **Registration and audit.** The same as for an existing folder. The audit event is `project_created` with `folderCreated: true`; a path-based create has no such field.
  - **Errors.** All `-32602`, with the text in `projects_folder.go`. A refusal changes nothing.
  - **App.** A New Project sheet from a toolbar button on the gateway home (`GatewayNewProjectModel`, `GatewayNewProjectSheet`). The name is checked with the same rules as it is typed; nothing is sent until Create. After success the home refreshes and selects the new project; the New Session sheet starts on the selected project. The selection is held in memory only.
- **Reason:** SPEC 2 and FR-17 allow the owner to register projects from the phone within roots. The rules keep the created folder inside the configured root, under a name the owner can read, and never through a link. Creating it inside the registration path means a folder the phone made is handled exactly as one the owner picked.
- **Limits.** The folder is created on the gateway's host by the gateway user, not in a container. A check and the `mkdir` are two steps, so a process that can already write the parent could swap a component between them; this is the same residual as D-063 and is not closed. The gateway never deletes a project or its folder; that is not built.

## D-092 Usage per session on the sessions index; project agent state notification
- **Date:** 2026-11-07
- **Decision:** Execution plan task A1 (contracts C1 and C2).
  - **Usage store.** An agent `session/update` with `sessionUpdate` "usage_update" is stored per session, in a new table `session_usage` (schema version 6; the migration creates it). The row holds the last update only: `used` and `size` (whole, non-negative numbers; an update missing either one is not stored), and the cost from `cost.amount` (finite, non-negative) with `cost.currency` (optional, at most 8 characters). Each update replaces the row whole, so an update without cost clears the stored cost. A row is written only for a session the gateway has recorded, and it is deleted with the session. The update is still logged as before: the event-log format does not change. Nothing is estimated.
  - **Index.** Each row of `_agmente/sessions/index` gains `usage: {used, size, costAmount?, costCurrency?, updatedAt}`, left out when no usage is stored. `updatedAt` is when the gateway stored the value (RFC 3339, UTC, milliseconds). The phone computes what is left (`size - used`) and the percent (`used / size`). The gateway reads only the keys C1 names (`used`, `size`, `cost.amount`, `cost.currency`); the flat keys D-070 also accepts are not read. Only the index carries usage; `projects/list` and the ACP session list do not.
  - **Project state.** `_agmente/project/state {projectId, agent, since}`, where agent is `stopped`, `starting`, `running` or `stopping`, and `since` is when that state began. Every agent transition goes through `setState`, so the start, starting, running, stopping (including the idle stop) and stopped transitions all reach it. It is change-only: a transition to the state last sent is not sent again. At most one notification per project every 500 ms. A burst of transitions is coalesced, and the newest state is sent when the gap ends, so the phone always ends on the true state. It is not written to the event log. It goes to the sockets that listed the project with `_agmente/sessions/index` (for that project, or with no `projectId`, every project) or with `_agmente/projects/list` (every project). The `projects/list` hook was added at integration (the call `s.watchProjectStates(ctx, who.Conn, "")` in `projects.go`); A1 alone did not have it. A socket that has closed is dropped when the next state is sent.
  - **Audit.** Each state notification writes one audit line, event `project_state`, with `reason` set to the state name. No text is written.
  - **Known limits.** There is no snapshot on subscribe, because the notification is change-only: a socket learns the agent state at the next change. The first state is the first transition after the gateway starts. A restart inside the 500 ms gap can be coalesced away, so a phone may not see a very short stop. A project created after a socket listed the projects is not in that socket's subscription until it lists again.
  - **Bob.** The shape of Bob's `usage_update` is still unconfirmed (D-070). The wire tests use the C1 shape through the fake agent only.
- **Reason:** The index starts no agent, so the phone needs the last usage stored by the gateway, and it survives a restart. The agent state must reach the phone without polling. The rate limit and coalescing keep a restart loop from flooding phones, and the newest state still arrives.

## D-093 Usage UI: header chip, usage sheet, home row bar, "not reported by Bob" state, one update per second

Date: 2026-11-07. Task B1. Contract C1 (usage on the sessions index).

Context. Bob sends an ACP `usage_update` with the context tokens used, the window size and, sometimes, a cumulative cost. The app already parsed these into the session state (`ForkSessionMeta.usage`). The gateway stores the last value per session and returns it as an optional `usage` object on each row of `_agmente/sessions/index` (D-092). Bob has no balance over ACP.

Decision.

1. Only Bob's figures are shown. The app never estimates a figure, and never shows a balance number. The sheet's "Bob balance" row says "not available from Bob" with a one-line explanation.
2. Header chip, above the transcript of a session. It reads "42%, 84k left" when the window size is known. It reads "Context: not reported by Bob" when Bob has sent no usable figures. When only the used tokens are known (size zero), it reads "12k used" and shows no left or percent. Tapping it opens the usage sheet.
3. Usage sheet. Used, Size, Left and Percent used, shown from the figures. Left and percent need a size above zero. A cost row appears only when Bob sent a cost, labelled "session cost (cumulative)", with its currency when Bob sent one. "Last updated" and the source line "Reported by Bob (ACP usage_update)" appear only when Bob has reported. A not-reported session says so and shows no figures.
4. Home list. Each session row carries a thin bar along its foot, filled to the share of the window in use. It shows only when the size is known. The usage comes from the same `_agmente/sessions/index` request that loads the sessions (`GatewayClient.sessionsWithUsage`), so the list costs no extra request.
5. Malformed usage is ignored. A `usage` object that is not an object, or lacks a non-negative `used` or `size`, or has no RFC 3339 `updatedAt`, is dropped. The session still shows. A malformed cost is dropped and the rest of the usage is kept. A currency is kept only with a cost amount and only when it is a short text.
6. Live updates are at most one per second per session. `UsageUpdateThrottle` is a pure type: the caller passes the time, so tests need no timers. The last value that arrives inside the window is the one shown when the window ends. A "no usage" value clears the chip at once.
7. Derived values. `left = size - used`, never below zero, only when size > 0. `percent = used / size`, only when size > 0, not capped in the model (the bar is capped at 100%).
8. Live timestamps. A live value is stamped with the time this device received it, since ACP's `usage_update` carries no time.

Consequences. The row bar and the header chip read the same `GatewayUsage` type. Its decoding sits in `ACPClient/Sources/ACPClient/Gateway/GatewayUsage.swift` and `GatewayClient+Usage.swift`, and does not change the existing `GatewaySession` decoding. The header chip shows live Bob figures from the session's events; a session reopened after the app restarts shows them once Bob's usage event is replayed.

## D-094 Running-now strip derived from the event log; subagent gap stated in the UI

Date: 2026-11-07. Task B2. Contract C3.

- A tool call is running when its `tool_call` has no later terminal `tool_call_update` (`completed` or `failed`) with the same `toolCallId`. Other statuses (`pending`, `in_progress`, `awaiting_permission`) keep it running. A later `tool_call` with the same id starts it again.
- Open approvals are counted from open permission requests on the current turn's tool calls. The turn is running when a transcript row is streaming. The gateway index status is not plumbed into the session view, so the view model's streaming flag stands in for `running`.
- Only the current turn counts: the assistant rows after the last user row, and only while a turn is running. A transcript restored after a quit can hold tool calls with no terminal update. They belong to a turn that has ended, so they are not shown as running.
- The strip lists at most 5 running tool titles, shows a count, and shows the title as given. For `execute_command` that title is the command text. Raw tool output is never shown.
- The strip shows the fixed note "Subagent work is not shown." Subagent work is not visible in the ACP stream (H1).
- Pure logic lives in `Agmente/Fork/Running/RunningWork.swift` (no UI). The adapter from transcript rows is in `RunningWorkEvents.swift`. The strip is `RunningNowStrip.swift`, placed below the transcript with `safeAreaInset` (one line in `SessionDetailView.swift`), so an empty strip takes no space.

## D-095 Connector listener, OAuth, pairing, grants and limits; two listeners; no client certificate on the public listener
- **Date:** 2026-11-07
- **Decision:** The gateway gets a second listener, the remote connector, bound to `127.0.0.1:connector.port` (default 8789). Caddy forwards public HTTPS to it without a client certificate. The phone's listener (mutual TLS, `127.0.0.1:8788`) is unchanged and shares no code path with the connector. The connector serves only these routes and answers every other path with 404:
  - `GET /.well-known/oauth-protected-resource` (RFC 9728)
  - `GET /.well-known/oauth-authorization-server` (RFC 8414)
  - `GET /authorize` (PKCE pairing page)
  - `POST /token` (authorization code to grant token)
  - `POST /mcp` (MCP Streamable HTTP, protocol 2025-11-25)

  A known path with the wrong method is 405 with an `Allow` header. This includes `GET /mcp` and `DELETE /mcp`, which the transport requires to be 405 when no SSE stream is offered.

  **Spec choices (MCP authorization 2025-11-25, and transports):**
  - **Protected resource metadata: required and served.** MCP servers MUST implement RFC 9728 and MUST list at least one `authorization_servers` entry. The 401 carries `WWW-Authenticate: Bearer resource_metadata="<origin>/.well-known/oauth-protected-resource"`, which satisfies the spec's first discovery mechanism, and the root well-known URI is also served (the second mechanism).
  - **Authorization server metadata: required and served (RFC 8414).** The spec requires RFC 8414 or OIDC discovery. RFC 8414 is served. OIDC discovery is not.
  - **PKCE with S256: required.** `/authorize` refuses any `code_challenge_method` other than `S256`. Metadata advertises `code_challenge_methods_supported: ["S256"]`, which the spec makes mandatory for client acceptance. `/token` checks the verifier in constant time.
  - **Resource indicators (RFC 8707): required.** The client MUST send `resource`, and the server MUST bind tokens to its own audience. The canonical resource is `<publicOrigin>/mcp`. `/authorize` and `/token` refuse a `resource` that names another server. A missing `resource` is accepted and defaults to the canonical value, which is more lenient than the spec for the client but binds the token to this server either way.
  - **Client registration: none.** The spec makes every registration path optional for the server. Client ID Metadata Documents are SHOULD for the server, and dynamic client registration is MAY ("for backwards compatibility"). Neither is required, so neither is built. The gateway accepts any opaque `client_id` and relies on the phone approval as the real gate. Consequence: the connector only works with a client that can use a pre-registered or user-entered `client_id`. Whether the Claude client can do that is the owner's probe (plan step 7.0). If the probe shows Claude needs DCR or CIMD, that is a new decision. The metadata deliberately omits `registration_endpoint` and `client_id_metadata_document_supported`.
  - **Redirect URIs:** not checked against a pre-registered list, since none exists. Each must be `https`, or `http` to `localhost`, `127.0.0.1` or `[::1]`. The phone's pairing list shows the `redirectHost` (an addition to C5) so the owner can see where the code will go.
  - **Origin (MCP transports, DNS rebinding):** MUST validate Origin. A request with no `Origin` is allowed. A request with an `Origin` is allowed only when it matches `connector.allowedOrigins` (exact, case-insensitive), otherwise 403. This applies to every connector route.
  - **Protocol version:** the gateway negotiates `2025-11-25`, `2025-06-18` and `2025-03-26`. Any other `MCP-Protocol-Version` header gets 400. The endpoint is stateless and issues no `MCP-Session-Id`, which the spec allows (MAY). Batch requests are refused. A POST of a notification or response gets 202.
  - **Token lifetime: a deliberate deviation from "SHOULD issue short-lived access tokens".** A grant token does not expire. It is the owner's standing consent, and the phone revokes it at once (`_agmente/connector/revoke`). Short lifetimes would need a refresh flow the connector does not otherwise need. The owner can revisit this with the probe results.

- **Pairing (C5):** `GET /authorize` opens a pending pairing with a six-digit code and a timeout of `connector.pairingTimeoutSeconds` (default 300, range 1 to 3600). The page is streamed: the code shows at once, and the redirect is appended as a script when the phone decides. A decision is one of approve (the code is redirected), deny, or timeout (`error=access_denied`). A client that disconnects cancels its pairing. At most five pairings are open at once; a sixth gets 429. Each approve creates a grant and a single-use authorization code (60 s). The phone methods are `_agmente/connector/pending`, `approve`, `deny`, `grants` and `revoke`, dispatched by one block in the server's `_agmente/` branch.

- **Scope:** a grant holds `{projects: "all" | [ids], sessions?: [ids]}`. The phone's approve checks that every project is registered, and that every session is known and inside the listed projects. The scope gate for tools is `Scope.Allows(projectId, sessionId)`. An unknown session and one outside the scope get the same refusal, so a grant cannot probe for other sessions. Tool refusals are tool errors (`isError: true`) with a plain reason.

- **Grant storage:** `<stateDir>/connector-grants.json`, written atomically (temp file in the same folder, `O_EXCL`, fsync, rename), mode 0600. It holds the grant's scope, label, client id, resource, creation and last-use times, and the SHA-256 hex of its token. It never holds the token. The file is not in the SQLite store, because task A1 changes that schema at the same time. A token is compared by its hash in constant time, and a grant's last-use time is written at most once a minute. The token is shown once, in the `/token` response, and is never logged.

- **Limits (C6):** `connector.limits` holds `maxConcurrentTurns` (1 to 16, default 1), `promptsPerHour` (1 to 1000, default 20), `maxPromptBytes` (1 to 65536, default 8192), `maxResultChars` (1000 to 200000, default 20000) and `sendPromptWaitSeconds` (1 to 600, default 200). Out-of-range values, unknown keys and a missing `publicOrigin` (when enabled) are config errors that `--dry-run` reports. In this task, `send_prompt` runs the scope gate and the size and hourly gates (`promptsPerHour` counts each attempt that passes the scope check) before returning "not implemented". `startTurn` reserves the turn slot (one per session, `maxConcurrentTurns` overall) and is ready for task D2.

- **Tools:** the five C7 tools are declared with their schemas and gated. Their handlers return "not implemented" until task D2 fills them in. An unknown tool name is a JSON-RPC error.

- **Enabled:** `connector.enabled` defaults to false. When false, no listener starts and the phone's methods are method-not-found. `Listen` loads the grants file and binds the port, and a bind failure stops the gateway at start, as the phone's listener does.

- **Audit:** events `connector_listening`, `connector_reject` (origin, no token, invalid token), `connector_pairing` (requested, approved, denied, timeout, cancelled), `connector_token`, `connector_revoke` and `connector_mcp` (tool calls). A grant is named by its id. A token, a code and prompt text are never written. The connector's client address is the Caddy proxy's address, because the public listener sees the proxy's connection.

- **Reason:** A public listener is new internet exposure. The bearer grant, the phone approval with a visible code, PKCE, the strict route table, the Origin check, the per-grant hourly limit and the revoke path are the controls. None of them depends on the phone's mutual TLS. Choosing the smallest spec-conforming set keeps the surface small and reviewable. Dynamic client registration and client ID metadata documents would each add either an unauthenticated write path or an outbound fetch from a public request, and neither is needed unless the probe shows the client requires one.

## D-097 Phone approval of connector pairings and grant management
- **Date:** 2026-11-07
- **Decision:** The phone is the only approver of a connector pairing (contract C5). A Connections screen lists the pending pairings (six-digit code, client name, time left) with Approve and Deny, and the grants (label, scope, last used) with Revoke.
  - **Approve asks for a scope first.** Two choices: "One session" (the default; the newest session is picked, and the person may pick another) and "All projects" (`projects: "all"`, no session list). One session sends exactly one project and one session: the picked session's own project and that session id.
  - **Deny** removes the pairing with no scope. **Revoke** asks for confirmation, then removes the grant at once; the client must pair again.
  - **Reads, no push.** The lists are read on appear, on pull, and every 5 seconds while the Connections screen is on screen. The timer belongs to that screen's task and stops when the screen goes away. No notification routing is added (`AppViewModel+Gateway.swift` is unchanged).
  - **Errors.** The five methods use the existing `GatewayError` (a JSON-RPC error keeps its code and the gateway's text; a dropped connection and a wrong answer shape are named). A failed approve, deny or revoke keeps the row, reads the lists again so a closed pairing drops out, and shows the gateway's text.
  - **Local state.** A row the screen approved, denied or revoked does not return on a read that was already in flight.
  - **Entry.** One toolbar button on the gateway home (the link icon, `gatewayConnections`), shown only when the selected server is the gateway. The toolbar is built in `Agmente/ContentView.swift` (`SessionListPage`), so the hook is there, next to the New Project button (D-099 app side).
- **Reason:** The owner approves each client on the phone, with the same tap-and-confirm rule as tool approvals (D-031, D-009). A scope choice made before Approve means the default cannot grant more than the person saw. Polling while visible avoids a new notification path until the owner asks for one.
- **Limits.** The grant list shows counts for projects and sessions, not names: the grants carry ids only. The pairing code is the only check that the page and the phone are talking about the same request; the gateway checks it on approve. Error codes for a pairing that expired before the tap are not in contract C5; the screen shows the gateway's text as sent.

## D-098 Public exposure of the connector: Caddy site on 443, launchd templates, config example

- **Decision:** The connector is exposed through a second Caddy site on TCP 443 under the host name in `CONNECTOR_HOST`. It has no `client_auth` block and no `tls internal`. It forwards only seven exact paths to `127.0.0.1:8789` and returns 404 for everything else: the two `/.well-known/oauth-protected-resource` forms (root and `/mcp` suffix), `/.well-known/oauth-authorization-server`, `/register`, `/authorize`, `/token` and `/mcp`. The phone listener (`deploy/Caddyfile`) is unchanged.
  - **File.** `deploy/Caddyfile.connector`. It is a separate file, added to the main Caddy config with a top-level `import` (integration added the line to `deploy/Caddyfile`, which is relative to that file). It is not a second Caddy process, because only one process can bind 443.
  - **Why no client certificate.** The Claude client cannot present one. The grant bearer token from the pairing (D-095), the strict path list and the gateway's limits are the controls. The public site must not carry the phone's paths or port.
  - **Certificate.** Caddy's automatic public certificate for `CONNECTOR_HOST`. A private certificate is refused by the Claude client.
  - **Host name.** Read from the environment (`{$CONNECTOR_HOST}`), never written into the repo. The public name is the owner's.
- **Launchd.** Two templates under `deploy/launchd/`, not installed by any script:
  - `dev.agmente.gateway.plist`: a LaunchAgent (user). The gateway needs the owner's Apple `container` session and project folders. `BOB_API_KEY` is loaded from a secrets file outside the repo, never placed in the plist. `KeepAlive` true, logs under `<stateDir>/logs/`.
  - `dev.agmente.caddy.plist`: a LaunchDaemon (root), because binding 443 needs root on macOS. `XDG_DATA_HOME` and `XDG_CONFIG_HOME` point under the owner's folder, so the certificate state is not in `/var/root`. `CONNECTOR_HOST` is set here.
- **Config.** `gateway/config.mac.example.json` gains the `connector` block from C6 with `enabled: false`. The gateway config parser does not reject unknown top-level keys (it checks only `push.*` and `limits.*` keys). With D-095 merged, the block is now parsed and validated (`connector` keys, limit ranges, `publicOrigin`). Integration also set the example's `listen.port` to 8788, the phone listener's port (below).
- **Reason.** Keeps the public listener to the paths Claude needs and one 443 forward. Keeps the phone's mutual TLS intact. Moves the process controls into launchd so restarts after a crash do not depend on a login shell.
- **Limits.**
  - Port 80 is optional. Caddy can issue on 443 alone (TLS-ALPN-01). This was not tested on this Mac.
  - The spec's path-suffixed form `/.well-known/oauth-protected-resource/mcp` is in the matcher (integration, notes item 2), so Caddy forwards it. The gateway does not serve it and answers 404 (D-095 serves the root form only). The `WWW-Authenticate` challenge names the root form, which the gateway serves, so the challenge and the served route agree. A client that looks up the path-suffixed form first and gets 404 falls back to the challenge's root URL. The probe checks this.
  - The phone block in `deploy/Caddyfile` was changed at integration to `:8443` forwarding to `127.0.0.1:8788`, the plan's values (8787 is held by Hammerspoon on the test Mac). The live Caddy was not touched.
  - Caddy runs as root and the gateway as the owner. A root-owned Caddy log and data files under the owner's folder are expected.

## D-099 Review fixes to folder creation (D-091)
- **Date:** 2026-11-07
- **Decision:** D-091 stands: the request, the name rules, the parent rules, the registration and the audit are unchanged. Review found seven defects. These changes fix them.
  - **Parent pinned.** After the path checks, the parent folder is opened once (`os.Root`). The mkdir, the `0755` mode change, the post-create check and the rollback all work through that open folder, so a component swapped after the open cannot redirect them. The path is checked again after the open and must still resolve to itself, so a link swapped in before the open is refused with nothing made. A folder made in a parent that is then moved aside is removed again by the same call.
  - **A new folder must be a folder.** After the mkdir, anything at the name that is not a directory (a file or a link) is refused with `-32602` ("the new folder was replaced while it was made") and is left alone. Before this change a regular file at the name passed the post-create check and was registered as a project.
  - **Mode through the open folder.** The `0755` chmod follows no link out of the parent, so a link at the name cannot change the mode of a folder outside the roots.
  - **Rollback.** The folder this call made is removed only while it is still a directory and empty. A file or link at the name is never removed.
  - **Roots.** `_agmente/projects/roots` lists a root only while it still exists and resolves to itself, each root once. Before this change a root removed after start was still listed.
  - **App.** Changing the root clears a refusal. A refusal is shown only when the name and the root still match what was sent. A second Create while one is in flight sends nothing (already the case; now tested).
- **Errors.** A refusal is `-32602`, as D-091 says. A failure of the system itself (the folder cannot be created, read or chmod'ed, or the store fails) stays `-32603` "internal error", because it is not a refusal of the request and nothing has changed when it happens. The text stays as in `projects_folder.go`.
- **Reason:** Each change closes a case where the gateway made, changed or deleted something outside what the owner asked for, or showed the person a refusal that no longer matched the form.
- **Limits.** This narrows the residual in D-091. A check and the open are still two steps, but a link swapped in between is caught by the second check. A process that can already write the parent can still move the open folder in the milliseconds after the open; the folder then made is the one this call created, and it is removed again when the path no longer resolves to it. This is the D-063 residual and is not closed. The gateway still never deletes a project or its folder.
