# Architecture

Read with [SPEC.md](SPEC.md). Decision IDs (D-n) refer to [DECISIONS.md](DECISIONS.md).

## 1. Layers

| Layer | Component | Job | Folder |
| --- | --- | --- | --- |
| Edge | Caddy | Terminate TLS. Require a client certificate (mutual TLS). Forward to loopback. | `deploy/Caddyfile` |
| Gateway: admission | `server.go`, `auth.go` | Reject before upgrade: Origin, rate limit, token, capacity. | `gateway/internal/server/` |
| Gateway: protocol guard | `guard.go`, `jsonv` | One JSON object per message; `cwd` inside roots; size caps; re-serialized as one line. | `gateway/internal/` |
| Gateway: agent control | `agent.go`, `runner.go`, `supervisor.go`, `client.go` | One agent per project (host or podman runner, project lock), id remapping, routing by cwd and sessionId, per-socket send queues. | `gateway/internal/server/` |
| Gateway: config and audit | `config`, `audit` | Validate the config file; one JSON audit line per event on stderr. | `gateway/internal/` |
| Gateway: sessions (phase 3) | `projects.go`, `store`, `subscribe.go`; approvals and idle close planned | Project registry, event log, subscribe and replay (D-028), approval queue, idle close. | `gateway/internal/server/`, `gateway/internal/store/` |
| Gateway: project data (phases 3, 5, 6) | `git.go`, `gitexec.go`, `snapshot.go`, `watch.go`; planned `files/`, `mcp/`, `skills/` | Read-only git (D-034, D-035); later signed file URLs, MCP and skill config. | `gateway/internal/server/` |
| Gateway: notify (phase 3) | `push/`, `push_deliver.go` | APNs payloads (D-038), token-based auth, HTTP/2 send, cleanup and retry (D-053); triggers and suppression (D-054). | `gateway/internal/push/`, `gateway/internal/server/` |
| Project runtime | One container per project | Run `bob acp` and git as the project user. | `deploy/` (planned) |
| App: transport | `AgmenteTransport` (one WebSocket client, D-017), wrapped by `ACPClient` and `AppServerClient` | WebSocket, TLS, SPKI pinning, client certificate, 16 MiB message cap, connect timeout. | `AgmenteTransport/`, upstream folders |
| App: security | Keychain store | Tokens, client identity, MCP headers. | `Agmente/Security/` (new) |
| App: features | Home, Git, Preview, MCP, Skills screens | UI for the gateway features. | `Agmente/Fork/` (new) |

Rule: new app code goes in new files under `Agmente/Fork/` and `Agmente/Security/`. Edits to upstream files stay small hooks (D-005).

## 2. Data flows

### 2.1 Connect and admission (phase 1)

```
Phone ──TLS + client cert──▶ Caddy :443 ──▶ Gateway 127.0.0.1:8787  (HTTP upgrade request)
                               │                 │
                     no/invalid cert         1. Origin header?        ── yes ─▶ 403, close
                     ─▶ TLS alert              2. address locked out?  ── yes ─▶ 429, close
                                               3. token hash match?    ── no ──▶ 401, count failure, close
                                               4. under connection cap? ── no ──▶ 429, close
                                               5. upgrade (no agent yet; agents start per project on a routed request, D-025)
```

No agent process starts during admission. Every reject writes one audit line.

### 2.2 Message path and guard (phase 1)

```
Phone message ─▶ size ≤ maxMessageBytes? ── no ─▶ close 1009
             ─▶ exactly one JSON object?  ── no ─▶ close 1007
             ─▶ has params.cwd?           ── yes ─▶ realpath inside a root? ── no ─▶ JSON-RPC error -32602 to phone (not forwarded)
             ─▶ write line to agent stdin ─▶ stdin full? ── yes ─▶ pause socket until drain

Agent stdout line ─▶ length ≤ maxMessageBytes? ── no ─▶ drop, audit, close 1009
                  ─▶ valid JSON?               ── no ─▶ drop (agent log noise), audit
                  ─▶ send to phone ─▶ phone slow (buffer > max)? ── yes ─▶ pause agent stdout
Agent exits ─▶ pending requests get JSON-RPC -32000 "agent exited"; sockets stay open; next request starts a new agent after the exit (D-025)
Phone closes ─▶ the project's agent keeps running (D-025; D-006 superseded)
Phone slow (send queue over 2 × maxMessageBytes + 1 MiB) ─▶ close that socket 1013
```

### 2.3 Turn while the phone is away (phase 3)

```
Phone A ─prompt─▶ Gateway ─▶ bob acp (project container)
Phone A disconnects                       │
                                          ├─ session/update ─▶ event log (seq n, n+1, …)
                                          ├─ session/request_permission ─▶ approval queue
                                          │        └─▶ APNs push "approval needed"
Phone A or B reconnects ─▶ subscribe(afterSeq = last seen) ─▶ replay n…head ─▶ live stream
Phone answers ─▶ queue: first answer wins ─▶ response to bob
                └ second answer ─▶ "answered elsewhere"
No answer by timeout ─▶ queue selects a reject option (or `cancelled` if the request has none) ─▶ bob
```

Lifecycle (FR-45, D-016): a project's container starts on its first request (about 1.5 s until an existing session is loaded, RESULTS 2026-11-06) and stops after every session is idle for the idle time. A pending approval or a subscriber keeps it running. A request during a stop waits for the exit, then starts a new container with the same name. Files and `HOME` live on volumes, so Bob still has its sessions.

Failure path: the agent process dies. The gateway marks its sessions `error`, logs an event, and restarts the agent on the next request. After a restart, and only then, it forwards one `session/load` for a session the phone opens, keeps the agent's replay out of the log, and holds other requests for that session until a fence shows the replay is over (FR-20, F-12, D-029). A load or resume for a session that is live is answered by the gateway from its cached result and the log. Reason: a load on a live session is refused while a turn runs, and when idle it rebuilds Bob's session (MCP servers restart, F-19) and replays history that would enter the event log twice. The new agent starts only after the old process has exited, so two Bob processes never share a task store (F-21, D-014).

### 2.4 Read-only git (phase 3)

```
Phone ─git/status─▶ Gateway ─▶ container exec (project user):
                                 git --no-pager --no-optional-locks
                                     -c core.fsmonitor=false -c core.hooksPath=/dev/null
                                     status --porcelain=v2 --branch -z
                               env: GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
                               timeout 5 s ─▶ kill, error "git timeout"
                               output > cap ─▶ truncate, truncated:true
Phone ─git/diff(path)─▶ path in last status? ── no ─▶ error
                      ─▶ git … diff --no-ext-diff --no-textconv -- <path>
                      ─▶ path on deny-list? ── yes ─▶ name only, content hidden
```

Turn snapshot (D-036): list the files, hash them with `git hash-object --no-filters -w`, build a temporary index with `git update-index --index-info`, then `git write-tree`, at turn start and turn end. It never runs `git add`, so no clean filter runs (T-27); git still runs in the container.

### 2.5 File preview (phase 5)

```
Phone ─files/url(path)─▶ Gateway: realpath inside project root? ── no ─▶ error
                                 ─▶ HMAC-signed URL on preview host, expires ≤ 300 s
Phone WKWebView / image loader ─▶ preview host ─▶ verify signature + expiry ── fail ─▶ 403
```

The preview host is a different hostname from the ACP endpoint. A hostile page cannot reach the ACP socket or its cookies.

## 3. Trust boundaries

1. Internet to Caddy: only clients with a certificate from your client CA pass.
2. Caddy to gateway: loopback only. The gateway trusts `X-Forwarded-For` only when `trustProxy` is true and the peer is loopback, and then uses only the last entry, which the proxy wrote.
3. Gateway to agent: the agent is untrusted output. Its lines are size-capped and parsed. It runs as another user in a container.
4. Repository content: untrusted. It can carry git config that runs programs (F-20).
5. Agent HTML and images: untrusted. Sandboxed in the app (FR-37, FR-39).

## 4. Design choices

- Go gateway with one dependency, `coder/websocket`, checked by a wire-level test suite in Node. See D-021, which supersedes D-001.
- ACP on the wire, plus `_agmente/*` methods. See D-002.
- Mutual TLS at Caddy and hashed bearer tokens at the gateway. See D-003.
- Phases ordered so that no-credential work comes first; sessions and git are built against a fake agent. See D-004.
- Gateway lives in `gateway/` in the fork. See D-005.
- Phase 1 keeps one agent per connection; phase 3 moves to one per project. See D-006.
- Event log in SQLite through `modernc.org/sqlite`, WAL, `synchronous=NORMAL`, in `gateway/internal/store`. See D-023, which supersedes D-007.
- Git and Bob run in the project container. See D-008.
- The gateway never approves. See D-009.
- The overlay replaces `CLAUDE.md` and leaves the upstream `README.md`. See D-010.
- The shared `.claude/` files are tracked in git. See D-011.
