# Architecture

Read with [SPEC.md](SPEC.md). Decision IDs (D-n) refer to [DECISIONS.md](DECISIONS.md).

## 1. Layers

| Layer | Component | Job | Folder |
| --- | --- | --- | --- |
| Edge | Caddy | Terminate TLS. Require a client certificate (mutual TLS). Forward to loopback. | `deploy/Caddyfile` |
| Gateway: admission | `server.js`, `auth.js` | Reject before upgrade: Origin, rate limit, token, capacity. | `gateway/src/` |
| Gateway: protocol guard | `acp-guard.js` | One JSON object per message; `cwd` inside roots; size caps. | `gateway/src/` |
| Gateway: agent control | `agent-process.js` | Spawn the configured agent; pipe line-delimited JSON. | `gateway/src/` |
| Gateway: sessions (phase 3) | `sessions/` | Project registry, event log, subscribe and replay, approval queue, idle close. | `gateway/src/sessions/` (planned) |
| Gateway: project data (phases 3, 5, 6) | `git/`, `files/`, `mcp/`, `skills/` | Read-only git, signed file URLs, MCP and skill config. | `gateway/src/` (planned) |
| Gateway: notify (phase 3) | `push/` | APNs payloads and delivery. | `gateway/src/push/` (planned) |
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
                                               4. under agent caps?    ── no ──▶ 429, close
                                               5. upgrade ─▶ spawn configured agent ─▶ pipe
```

No agent process exists until step 5. Every reject writes one audit line.

### 2.2 Message path and guard (phase 1)

```
Phone message ─▶ size ≤ maxMessageBytes? ── no ─▶ close 1009
             ─▶ exactly one JSON object?  ── no ─▶ close 1007
             ─▶ has params.cwd?           ── yes ─▶ realpath inside a root? ── no ─▶ JSON-RPC error -32602 to phone (not forwarded)
             ─▶ write line to agent stdin ─▶ stdin full? ── yes ─▶ pause socket until drain

Agent stdout line ─▶ length ≤ maxMessageBytes? ── no ─▶ drop, audit, close 1009
                  ─▶ valid JSON?               ── no ─▶ drop (agent log noise), audit
                  ─▶ send to phone ─▶ phone slow (buffer > max)? ── yes ─▶ pause agent stdout
Agent exits ─▶ close socket 1011 with reason "agent exited"
Phone closes ─▶ kill agent (phase 1 only; D-006)
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

Failure path: the agent process dies. The gateway marks its sessions `error`, logs an event, and restarts the agent on the next request. After a restart, and only then, it sends `session/load` for a session the phone opens (FR-20, F-12). Reason: a load on a live session is refused while a turn runs, and when idle it rebuilds Bob's session (MCP servers restart, F-19) and replays history that would enter the event log twice. The new agent starts only after the old process has exited, so two Bob processes never share a task store (F-21, D-014).

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

Turn snapshot: `GIT_INDEX_FILE=<tmp> git add -A`, then `git write-tree`, at turn start and turn end. `git add` can run clean filters from `.gitattributes`. That is why git runs in the container (T-27).

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

- Node.js gateway with one dependency, `ws`. See D-001.
- ACP on the wire, plus `_agmente/*` methods. See D-002.
- Mutual TLS at Caddy and hashed bearer tokens at the gateway. See D-003.
- Phases ordered so that no-credential work comes first; sessions and git are built against a fake agent. See D-004.
- Gateway lives in `gateway/` in the fork. See D-005.
- Phase 1 keeps one agent per connection; phase 3 moves to one per project. See D-006.
- Event log in SQLite through `node:sqlite` (proposed). See D-007.
- Git and Bob run in the project container. See D-008.
- The gateway never approves. See D-009.
- The overlay replaces `CLAUDE.md` and leaves the upstream `README.md`. See D-010.
- The shared `.claude/` files are tracked in git. See D-011.
