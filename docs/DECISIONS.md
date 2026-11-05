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
