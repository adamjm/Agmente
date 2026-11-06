# Spec: Agmente for IBM Bob (fork)

**Status:** Draft v0.1 · **Owner:** Adam Makarucha · **Date:** 2026-11-05

## 1. Purpose

This fork makes Agmente, an iOS client for ACP coding agents, a safe remote client for IBM Bob Shell over the public internet, without a VPN.

The fork adds a server component, the **gateway**. The gateway replaces `@rebornix/stdio-to-ws`. It authenticates every connection, keeps agent sessions running when the phone is away, and serves project data (git state, files, MCP and skill config) to the app.

The app gets the session experience of the Claude mobile app: start a session in any registered project, leave, and come back to it at any time.

## 2. Scope

**In scope**

- Gateway (Go, folder `gateway/`, D-021): authentication, ACP proxy, agent process control, project registry, event log, approval queue, push notifications, read-only git state, signed file URLs, MCP and skill management.
- iOS app changes: secret storage, transport hardening, projects and sessions home, Bob support, image and HTML rendering, git views, MCP and skill screens.
- Deployment examples: Caddy with mutual TLS, systemd unit, one container per project.
- IBM Bob Shell as the primary agent. Other ACP agents must keep working where they do today.

**Out of scope**

- Git write actions (commit, push, discard).
- Codex app-server features beyond what works today.
- Android, web or desktop clients.
- Sending changes upstream or merging upstream changes in. This is a hard fork (D-005, D-017).
- Multi-user tenancy. One person owns the gateway; that person may have several devices.

## 3. Background and findings

All findings come from the review doc and from code at the versions below. Source IDs refer to section 10.

| ID | Finding | Source |
| --- | --- | --- |
| F-1 | `stdio-to-ws` 0.2.0 checks no credential. `verifyClient` only checks `Origin`, and only when `corsOrigin` is set. | [S2] `dist/stdio-to-ws.js` |
| F-2 | `stdio-to-ws` listens on all interfaces (`new WebSocketServer({ port })`). | [S2] |
| F-3 | With `--persist`, any client that sends a known `X-Client-Id` reattaches to a live agent and receives its buffered output. | [S2] `handleWebSocketConnection` |
| F-4 | `stdio-to-ws` spawns one agent per connection, with no cap. | [S2] |
| F-5 | Agmente stores the bearer token and Cloudflare client secret as plain Core Data string attributes. | [S1] `Agmente.xcdatamodel` `StoredServer` |
| F-6 | Agmente's WebSocket uses `NWConnection`. App Transport Security does not cover it. The default scheme is `ws`. | [S1] `URLSessionWebSocketProvider.swift`, `AppViewModel.swift:15` |
| F-7 | Agmente accepts inbound frames up to `Int.max` bytes. | [S1] `parseFrameFromBuffer` |
| F-8 | Agmente always sends `mcpServers: []`. | [S1] `ServerViewModel.swift:894, 1234, 1328` |
| F-9 | Agmente extracts only text from agent content blocks. Image, resource and resource-link blocks are dropped. | [S1] `SessionUpdateParsing.swift` |
| F-10 | Agmente builds its file-change list from tool-call kinds and titles. | [S1] `FileChangesSummaryView.swift` |
| F-11 | Bob 2.0.9 `initialize` returns `loadSession: true`, session `list`, `delete`, `resume`, `close`, `promptCapabilities.image: true`, `embeddedContext: true`, `mcpCapabilities.http: true`, `authMethods: [sso]`, `_meta["bob/extensions"].version: 1`. | [S3] live probe, fixture `gateway/test/fixtures/bob-initialize-2.0.9.json` |
| F-12 | Bob's `loadSession` and `resumeSession` call `disposeExistingSession` first. If the session is running a turn in the same process, Bob refuses with `-32600` "Session is already running a prompt" and the turn continues. If it is idle, Bob throws the session away, rebuilds it and replays the history as coalesced `session/update` notifications (one per message) after the response. The check covers only sessions in the same process (D-014). | [S3] package source (minified); live probe on 2.0.7 and 2.0.9, 2026-11-06 |
| F-13 | Bob requires license consent. Without stored consent and without client `elicitation.form`, `session/new` fails. `--accept-license` records consent. | [S3] package source; [S4] |
| F-14 | Bob reads `BOB_API_KEY`. Its only ACP auth method is browser SSO. | [S4] |
| F-15 | Bob checks folder trust against its own process working directory, not `session/new` `cwd`. On 2.0.9 a folder with no entry in `$HOME/.bob/trustedFolders.json` is trusted, and only an exact-path `DONT_TRUST` entry is refused (2.0.7 refused folders with no entry). `--trust` trusts all workspaces. Bob's trust check is therefore not a folder control (D-013). | [S4]; [S3] live probe and package source, 2026-11-06 |
| F-16 | Bob reads MCP config from `~/.bob/settings/mcp.json` and `<project>/.bob/mcp.json`, with keys `disabled` and `alwaysAllow`. SSE transport is removed. | [S5] |
| F-17 | Bob loads skills from `<project>/.bob/skills/<name>/SKILL.md` and `~/.bob/skills/`. Names are lowercase kebab-case, at most 64 characters. | [S6] |
| F-18 | Bob exposes skills and MCP prompts as slash commands through `available_commands_update`. | [S3] package source |
| F-19 | Bob starts each configured MCP server once per ACP session. | [S4] |
| F-20 | A repository can make git run programs through `core.fsmonitor`, `diff.external`, textconv drivers, `core.pager` and clean filters. | [S7] |
| F-21 | Two Bob processes with one `HOME` can open the same session at once: neither refuses. A turn that the second process completed (`end_turn`) was missing from the stored history afterwards. Bob logged no lock or conflict error (D-014). | [S3] live probe on 2.0.9, 2026-11-06 |

## 4. Requirements

### 4.1 Functional

| ID | Requirement | Priority | Phase |
| --- | --- | --- | --- |
| FR-1 | The gateway rejects a WebSocket upgrade with HTTP 401 unless the request carries a valid bearer token. It spawns no agent for a rejected request. | Must | 1 |
| FR-2 | The gateway refuses to start if its listen host is not a loopback address. | Must | 1 |
| FR-3 | The gateway rejects an upgrade request that carries an `Origin` header with HTTP 403. | Must | 1 |
| FR-4 | The gateway starts agents only from the command in its config. The client cannot set the command, arguments or environment. | Must | 1 |
| FR-5 | The gateway caps open connections per identity: a connection over the cap gets HTTP 429 before upgrade. It caps running project agents in total: a request that would start one more gets a JSON-RPC error (D-025). | Must | 1 |
| FR-6 | The gateway rejects ACP requests whose `cwd` is not inside a configured project root (after `realpath`). It returns a JSON-RPC error and does not forward the request. | Must | 1 |
| FR-7 | The gateway accepts exactly one JSON-RPC object per WebSocket message. It closes the socket with code 1007 for arrays, multiple lines or invalid JSON. | Must | 1 |
| FR-8 | The gateway rate-limits failed authentication per client address. | Must | 1 |
| FR-9 | The gateway writes an audit log line for each connect, reject, disconnect and ACP method name. It never logs prompt text, tool output or tokens. | Should | 1 |
| FR-10 | The app stores tokens, Cloudflare secrets and client certificates in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It migrates existing Core Data values and erases them. | Must | 2 |
| FR-11 | The app connects to hosted endpoints over `wss://` only. `ws://` is allowed in two cases. (a) Debug builds, to loopback hosts. (b) Servers marked "Local only", to loopback, `.local` and RFC 1918 hosts, in any build. A "Local only" server refuses every other host, and the form warns that its token travels unencrypted. Tailscale (`100.64/10`) and every other `ws://` host are refused. New servers default to `wss` with "Local only" off (D-018, D-019). | Must | 2 |
| FR-12 | The app caps inbound frames and reassembled messages and closes with code 1009 when a cap is exceeded. | Must | 2 |
| FR-13 | The app supports optional SPKI pinning per server. | Should | 2 |
| FR-14 | The app presents a client certificate for mutual TLS when one is configured. | Should | 2 |
| FR-15 | The app sets `NSFileProtectionComplete` on its Core Data store and excludes it from backup. | Should | 2 |
| FR-16 | The gateway keeps one agent process per project, alive independent of phone connections. | Must | 3 |
| FR-17 | The gateway has a project registry. A project path must be inside a configured root. The gateway trusts the folder for Bob at registration. | Must | 3 |
| FR-18 | The gateway writes every agent-to-client message for a session to a persistent event log with a sequence number that increases by 1. | Must | 3 |
| FR-19 | `_agmente/sessions/subscribe` with `afterSeq` replays the logged events after `afterSeq`, then streams live events. | Must | 3 |
| FR-20 | The gateway never sends `session/load` or `session/resume` to the agent for a session that is live in that agent. It sends them only after an agent restart and only when no turn is running. | Must | 3 |
| FR-21 | `_agmente/sessions/index` returns every session with project, title, status (`idle`, `running`, `awaiting_approval`, `error`), last activity and unread count. | Must | 3 |
| FR-22 | The gateway holds each `session/request_permission` until a device answers. The first answer wins. After a timeout it rejects. It never approves on its own. | Must | 3 |
| FR-23 | The gateway sends an APNs push when a turn ends, an approval is needed or a session fails. The payload holds only the project name, session ID and event type. | Should | 3 |
| FR-24 | The gateway closes an agent session after an idle time with no running turn and no subscriber. | Should | 3 |
| FR-25 | Every device of one identity sees the same projects and sessions. | Should | 3 |
| FR-26 | The app home screen lists sessions grouped by project, newest first, with a status badge. The new-session sheet picks a project, not a path. | Must | 3 |
| FR-27 | The gateway serves read-only git state: `_agmente/git/status`, `git/diff`, `git/log`, `git/turnDiff`, and the `git/changed` notification. | Must | 3 |
| FR-28 | Git runs inside the project container as the project user, with the safe flags in ARCHITECTURE.md. | Must | 3 |
| FR-29 | Git file paths come only from the current status output and are passed after `--`. | Must | 3 |
| FR-30 | The gateway hides the content of files that match the secret deny-list in all diffs. | Must | 3 |
| FR-31 | The app shows a branch chip, a Git tab and the turn diff in the file-change row when the gateway is present. | Should | 3 |
| FR-32 | The gateway starts Bob with `--accept-license`, without `--auto-approve` and without `--trust`, from a pinned installed version, with `BOB_API_KEY` from a secrets file. | Must | 4 |
| FR-33 | The app handles `plan_update`, `plan_removed`, `session_info_update` and `usage_update`. | Should | 4 |
| FR-34 | The app sets the start mode with `_meta["bob/mode"]` and changes it with `session/set_mode`. | Should | 4 |
| FR-35 | The app shows a clear error when the agent needs authentication. | Should | 4 |
| FR-36 | "Delete session" calls `session/delete` when the agent advertises it. | Could | 4 |
| FR-37 | The app renders inbound `image`, `resource` (image blob) and `resource_link` (image URI) content with ImageIO downsampling and a MIME allow-list. | Must | 5 |
| FR-38 | The gateway issues short-lived signed URLs for project files. It refuses paths outside the project root, including through symlinks. | Must | 5 |
| FR-39 | The app shows agent HTML in a sandboxed `WKWebView`: non-persistent data store, injected CSP, a content rule list that blocks network loads, navigation locked to the preview scheme, scripts off by default. | Must | 5 |
| FR-40 | The app keeps a list of client-owned HTTP MCP servers, with headers in the Keychain. It sends enabled servers on the next `session/new` or `session/resume` when the agent advertises `mcpCapabilities.http`. | Should | 6 |
| FR-41 | The gateway exposes MCP config: list servers and set `disabled` and `alwaysAllow` in Bob's `mcp.json`. | Should | 6 |
| FR-42 | The gateway acts as one aggregating MCP server that filters `tools/list` and `tools/call` by per-tool toggles. | Could | 6 |
| FR-43 | The gateway exposes skills: list, put and delete, with name validation, a size cap and atomic writes. The app requires Face ID to save a skill. | Should | 6 |
| FR-44 | The app supports ACP elicitation forms. | Should | 6 |
| FR-45 | The gateway starts a project's container and Bob on the first request for that project (session, prompt or git call), not at registration. It stops Bob and the container when every session in the project has been idle for the idle time (no running turn, no pending approval, no subscriber). It starts a new container only after the old one has exited, and never runs two for one project (D-015, D-016). Project files and `HOME` persist across stops. | Must | 3 |

### 4.2 Non-functional

| ID | Requirement |
| --- | --- |
| NFR-1 | An unauthenticated upgrade is rejected in at most 50 ms p95 on loopback. |
| NFR-2 | The gateway adds at most 5 ms p95 per JSON-RPC round trip on loopback, for 1 KiB messages, compared with a direct pipe to the same agent. |
| NFR-3 | The maximum WebSocket message is 16 MiB on the gateway and in the app. A larger message closes the socket with code 1009. |
| NFR-4 | Default caps: 8 connections per identity, 16 running project agents in total (D-025). |
| NFR-5 | Default auth limit: after 10 failures in 60 s from one client address, the gateway returns 429 for 600 s. |
| NFR-6 | Replay of 10,000 logged events to a subscriber takes at most 1 s on the host. |
| NFR-7 | An event that the gateway logged before a crash is present after restart: 0 lost logged events. |
| NFR-8 | Git status on a 10,000-file repository takes at most 1 s p95. Each git call times out at 5 s. A diff response is capped at 2 MiB. |
| NFR-9 | `git/changed` is debounced 500 ms, at most 2 per second per project. |
| NFR-10 | Default approval timeout: 12 h, then reject. Default idle close: 30 min. |
| NFR-11 | A push payload is at most 256 bytes and holds no file content, prompt or tool output. |
| NFR-12 | Signed file URLs expire in at most 300 s. |
| NFR-13 | The app decodes images to at most 4096 px on the longest side and refuses image data over 20 MiB. |
| NFR-14 | The gateway config file holds no secrets. Tokens are stored as SHA-256 hashes. |
| NFR-15 | A cold project start (container start to an existing session loaded and replayed) takes at most 3 s p95 on the host. Measured on a Mac Podman VM: 1.6 s max (RESULTS 2026-11-06). |

## 5. Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md). Key rules:

- Only Caddy faces the internet. The gateway listens on loopback. Mutual TLS at Caddy and a bearer token at the gateway (D-003).
- The phone speaks ACP to the gateway, plus `_agmente/*` extension methods (D-002).
- Each project runs in its own container. Bob and git run there, never in the gateway process (D-008).
- The gateway never approves a tool call (D-009).

## 6. Interfaces

### 6.1 Phone to gateway (WebSocket)

- URL: `wss://<host>/` through Caddy.
- Headers: `Authorization: Bearer <token>`. No `Origin`.
- Messages: one JSON-RPC 2.0 object per text message. A trailing newline is allowed.
- ACP methods pass through, subject to FR-6, FR-7 and FR-20.

### 6.2 Gateway extension methods (phase 3 and later)

| Method | Params | Result |
| --- | --- | --- |
| `_agmente/projects/list` | — | `{ projects: [{ id, name, path, defaultMode }] }` |
| `_agmente/projects/create` | `{ name, path, defaultMode? }` | `{ project }` |
| `_agmente/sessions/index` | `{ projectId? }` | `{ sessions: [{ sessionId, projectId, title, status, lastActivity, headSeq, unread }] }` (D-030) |
| `_agmente/sessions/read` | `{ sessionId, seq }` | `{ lastSeenSeq }`: the identity's read marker, which only moves forward (D-030) |
| `_agmente/sessions/subscribe` | `{ sessionId, afterSeq }` | `{ headSeq }`, then notifications `_agmente/event { sessionId, seq, message }`: the replay up to `headSeq`, then live events (D-028) |
| `_agmente/approvals/pending` | — | `{ approvals: [{ approvalId, sessionId, projectId, toolCall, options, since }] }` (D-031) |
| `_agmente/approvals/answer` | `{ approvalId, optionId }` or `{ approvalId, cancelled: true }` | `{}`; a later answer gets `-32001` with the reason (D-031) |
| `_agmente/git/status` | `{ projectId }` | `{ branch, upstream, ahead, behind, files: [{ path, status, staged, added, removed }], hash, truncated }` (D-035) |
| `_agmente/git/diff` | `{ projectId, path?, staged?, fromTree?, toTree? }` | `{ diff, truncated, hidden }` (D-035; the tree params come with 3.15) |
| `_agmente/git/log` | `{ projectId, limit, cursor? }` | `{ commits: [...], nextCursor? }` |
| `_agmente/git/turnDiff` | `{ sessionId, turn }` | `{ diff, truncated, hidden, fromTree, toTree }` (D-036) |
| `_agmente/git/changed` (notification) | `{ projectId, hash }` | — (sent to sockets that called `git/status` for the project, D-037) |
| `_agmente/files/url` | `{ projectId, path }` | `{ url, expiresAt }` |
| `_agmente/mcp/list`, `_agmente/mcp/set` | `{ projectId?, name, disabled?, alwaysAllow? }` | `{ servers }` |
| `_agmente/skills/list`, `put`, `delete` | `{ scope, name, content? }` | `{ skills }` |

Shapes are a draft. Each phase confirms them in its plan notes and records changes in DECISIONS.md.

### 6.3 Gateway config file

JSON, path from `--config`. Example: `gateway/config.example.json`. Keys: `listen` (`host`, `port`), `trustProxy`, `tokens` (`id`, `identity`, `sha256`), `agent` (`command`, `envPassthrough`), `projects.roots`, `stateDir` (absolute; the database and project homes, D-024), `runner` (`kind` `podman` with `image` and optional `podman`, or `host` with `allowHost: true` for tests, D-025), `limits` (`maxMessageBytes`, `maxAgentsPerIdentity` (accepted, unused since D-025), `maxAgentsTotal`, `maxConnectionsPerIdentity`, `authFailuresPerWindow`, `authWindowSeconds`, `lockoutSeconds`, `approvalTimeoutSeconds` (NFR-10, D-031), `idleSeconds` (NFR-10, D-032)).

### 6.4 Gateway CLI

- `agmente-gateway --config <file>`: run.
- `agmente-gateway --config <file> --dry-run`: validate config, print a summary, exit.
- `agmente-gateway new-token <id> <identity>`: print a new token once and its config entry.
- The binary is built to `gateway/bin/agmente-gateway` (D-021). The Node gateway was removed (D-022).

## 7. Test plan

| ID | Test | Pass criterion | Covers |
| --- | --- | --- | --- |
| T-1 | Run `scripts/check.sh` | Exit 0, prints "All checks passed." | Phase 0 |
| T-2 | Upgrade with no `Authorization` header | HTTP 401; agent spawn count stays 0 | FR-1 |
| T-3 | Upgrade with a wrong token, then the right token | 401, then 101 | FR-1 |
| T-4 | Upgrade with an `Origin` header and a valid token | HTTP 403; no spawn | FR-3 |
| T-5 | Start with `listen.host` = `0.0.0.0` | Config error; process exits non-zero | FR-2 |
| T-6 | Send a message larger than `maxMessageBytes` | Socket closes with 1009 | FR-7, NFR-3 |
| T-7 | Open `maxConnectionsPerIdentity + 1` sockets for one identity; then start projects past `maxAgentsTotal` | Last socket gets 429 and no agent starts for any socket; the project over the cap gets a JSON-RPC error | FR-5, NFR-4 |
| T-8 | `session/new` with `cwd` outside roots, and through a symlink that points outside | JSON-RPC error `-32602`; agent receives nothing | FR-6 |
| T-9 | Send a JSON array, two lines in one message, and invalid JSON | Socket closes with 1007 each time | FR-7 |
| T-10 | 10 bad tokens from one address in 60 s, then a good token | 11th request gets 429 | FR-8, NFR-5 |
| T-11 | Measure unauthenticated reject latency, 500 requests | p95 ≤ 50 ms | NFR-1 |
| T-12 | Measure round-trip overhead, 2,000 echo calls, gateway vs direct pipe | p95 overhead ≤ 5 ms | NFR-2 |
| T-13 | Audit log after a session with a prompt | Lines contain method names; no prompt text, no token | FR-9 |
| T-14 | iOS unit test: migrate a server with a token | Token in Keychain; Core Data attribute empty | FR-10 |
| T-15 | iOS unit test: the transport policy for `ws://example.com`, `ws://100.100.1.1`, `ws://192.168.1.5`, `ws://printer.local`, `ws://127.0.0.1` and `wss://example.com`, each with "Local only" off and on, in Debug and Release | `wss://example.com` allowed (refused when "Local only" is on). `ws://` allowed only for loopback in Debug, or for loopback, `.local` and RFC 1918 with "Local only" on. Every refused URL makes no network call | FR-11 |
| T-16 | iOS unit test: feed a 17 MiB frame to the parser | Connection closes with 1009; memory not allocated for the payload | FR-12 |
| T-17 | iOS: connect with a wrong pinned SPKI | Handshake fails | FR-13 |
| T-18 | Disconnect the phone mid-turn; reconnect; subscribe with last `seq` | Turn completes; events arrive with no gap in `seq` | FR-16, FR-19 (phase 3 gate) |
| T-19 | Replay 10,000 events | ≤ 1 s | NFR-6 |
| T-20 | Kill the gateway with SIGKILL after N logged events; restart | All N events present | NFR-7 |
| T-21 | Reopen a session while a turn runs, and while it is idle (fake agent with Bob's refuse-while-running and rebuild-when-idle behaviour) | Agent receives no `session/load` or `session/resume`; turn completes; no replayed history enters the event log | FR-20 |
| T-22 | Two devices answer one permission request | First answer forwarded; second gets "answered elsewhere" | FR-22 |
| T-23 | Permission request with no answer past the timeout | Agent receives a reject outcome; never an allow | FR-22, NFR-10 |
| T-24 | Build a push payload for each event type with long titles | ≤ 256 bytes; no prompt or tool text | FR-23, NFR-11 |
| T-25 | Create a project outside roots, and through a symlink | Refused | FR-17 |
| T-26 | Hostile repo: `core.fsmonitor`, `diff.external` and a textconv driver each set to create a marker file; run status and diff | No marker file anywhere | FR-28 |
| T-27 | Hostile repo with a clean filter; run the turn snapshot | Marker appears only inside the project container, never on the host | FR-28 |
| T-28 | `git/diff` with a path not in status, and with a path that starts with `-` | Refused | FR-29 |
| T-29 | Diff of a changed `.env` file | Name shown; content hidden | FR-30 |
| T-30 | Git status on a generated 10,000-file repo, 20 runs | p95 ≤ 1 s | NFR-8 |
| T-31 | Turn in which the agent runs `echo x > new.txt` | Turn diff lists `new.txt` | FR-27 |
| T-32 | `bob acp` through the gateway: `initialize` | Capabilities match fixture F-11, or the difference is recorded | FR-32 (phase 4 gate) |
| T-33 | Bob: `session/new`, `session/prompt`, `session/load`, `session/resume` | Each returns success on the pinned version | FR-32 |
| T-34 | Open question Q-1: does Bob `session/load` cancel a running turn? | Observed behaviour recorded | F-12, FR-20 |
| T-35 | Bob without `BOB_API_KEY` | App shows the auth error, not a generic failure | FR-35 |
| T-36 | iOS: decode a 50-megapixel PNG in a transcript | Peak memory increase ≤ 100 MB; image ≤ 4096 px | FR-37, NFR-13 |
| T-37 | Signed URL: `../` path, symlink to `/etc/passwd`, expired URL | All refused | FR-38, NFR-12 |
| T-38 | Hostile HTML page: `fetch`, external `img`, form post, `window.open`, top navigation | A local test server receives 0 requests | FR-39 (phase 5 gate) |
| T-39 | Open question Q-2: does Bob forward image blocks from MCP tool results over ACP? | Observed behaviour recorded | FR-37 |
| T-40 | Disable an MCP server; start a new session | Its tools are absent from the session | FR-41 |
| T-41 | Proxy: disable one tool mid-session | Absent from `tools/list`; `tools/call` refused; no Bob restart | FR-42 (phase 6 gate) |
| T-42 | Open question Q-3: does Bob's `session/resume` accept a changed `mcpServers` list? | Observed behaviour recorded | FR-40 |
| T-43 | Open question Q-4: does a running Bob session see a newly added skill? | Observed behaviour recorded | FR-43 |
| T-44 | Skill names: `Bad Name`, `../x`, 65 characters, valid name; 70 KiB content | Invalid names and oversize content refused; valid saved atomically | FR-43 |
| T-45 | Run Bob without `--accept-license` against an app with elicitation | License form shown and answered in the app | FR-44 |
| T-46 | Project lifecycle with a fake container runner: first request starts one container; a second request while starting waits and does not start another; idle past the idle time stops it; a pending approval or a subscriber keeps it running; a request during stop waits for exit, then starts a new one | Exactly one container per project at any time; each case behaves as stated | FR-45, D-015 |
| T-47 | Cold start on the Linux host: `node gateway/scripts/bench-start.mjs --runs 20 --skip-host` | Load-and-replay p95 ≤ 3 s | NFR-15 |

## 8. Risks and open questions

| ID | Item | Test |
| --- | --- | --- |
| Q-1 | Answered 2026-11-06 (RESULTS): `session/load` and `session/resume` during a turn are refused, not cancelled (F-12). | T-34 |
| Q-2 | Does Bob forward image content from MCP tools over ACP? | T-39 |
| Q-3 | Does `session/resume` accept a changed `mcpServers` list? | T-42 |
| Q-4 | Does a running Bob session pick up a new skill? | T-43 |
| Q-5 | Answered 2026-11-06 (RESULTS): no. Two processes lose a write without an error (F-21). The gateway must never run two Bob processes on one task store (D-014). | T-18 runs with one process; record any lock error |
| Q-6 | Answered 2026-11-06 (RESULTS): Bob checks trust before auth, against its process working directory. On 2.0.9 it trusts folders with no entry. The gateway `cwd` guard (FR-6), the per-project agent `cwd` and the container are the folder controls (D-013). | T-33 with a key set: record the result of `session/new` in an untrusted folder |
| R-1 | Bob's `_bob/*` methods and `_meta` keys are not part of ACP and can change. Pin the version; keep T-32 as a probe. | T-32 |
| R-2 | The SQLite driver for the Go gateway is not chosen yet (D-007 no longer applies, D-021). | T-20 |
| R-3 | Closed 2026-11-06: this is a hard fork that takes no upstream merges (D-017). | — |
| R-4 | APNs needs an Apple Developer account and a device. | T-24 covers the payload offline |

## 9. Dependencies

- macOS with Xcode for app phases (2, 3 app parts, 4, 5, 6) and Swift package tests.
- Apple Developer Program membership: device builds, Keychain sharing, APNs key (`.p8`).
- IBM Bob licence and `BOB_API_KEY` (phase 4 onward). Review the licence with `bob --show-license acp`.
- A Linux host with Docker or Podman, a DNS name, Caddy 2 with a client CA for mutual TLS.
- Go 1.26 or later for the gateway, with two dependencies: `github.com/coder/websocket` (D-021) and `modernc.org/sqlite` (D-023).
- Node.js 22.13 or later for the wire test suite (it reads `gateway.db` with `node:sqlite`, D-027) and the fake agent (one npm dependency, `ws`), and for Bob.

## 10. Sources

- [S1] Agmente, commit `87f224e` (21 Mar 2026): https://github.com/rebornix/Agmente
- [S2] `@rebornix/stdio-to-ws` 0.2.0 (npm): https://github.com/rebornix/stdio-to-ws
- [S3] `@ibm/bob` 2.0.9 (npm), probed 2026-11-05: https://zed.dev/acp/agent/bob
- [S4] Bob Shell ACP: https://bob.ibm.com/docs/shell/features/acp
- [S5] Bob Shell MCP configuration: https://bob.ibm.com/docs/shell/configuration/mcp/mcp-bobshell
- [S6] Bob Shell skills: https://bob.ibm.com/docs/shell/features/skills
- [S7] git-config documentation (`core.fsmonitor`, `diff.external`, `diff.<driver>.textconv`, `filter.<driver>.clean`): https://git-scm.com/docs/git-config
- Review doc with full findings: https://claude.ai/artifact/MLCaLo9x8PdLXdAezVHBW6
