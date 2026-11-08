# Research: Bob tokens, context window and running work in the app

Date: 2026-11-07. Repo: `/Users/adammakarucha/Documents/Projects/remote-bob-app/Agmente`. Bob: `@ibm/bob` 2.0.9 (installed at `/opt/homebrew/lib/node_modules/@ibm/bob`, Bob commit `9690f20b0`).

Scope: research and probes only. No code, config or repo docs were changed. One live Bob prompt was sent (cost in section 2.4). No credential value was printed, and no file in the phone scratchpad folder was read.

## 0. Answers in brief

| Number | Status today | Source when available | Shown where (plan) |
| --- | --- | --- | --- |
| (a) Bob tokens available | **Unavailable.** Bob has no balance or quota interface that a client can call. | None found. | "Not available from Bob" line in the usage sheet. No estimate. |
| (b) Context used / left for the session | **Unavailable now.** The ACP field exists and the app parses it, but Bob 2.0.9 never sends it. | Measured, agent-reported: ACP `usage_update` `used` and `size`. Left = size - used (client-derived). | Session header chip, usage sheet, home list row. |
| (c) Tools and processes running | **Measured now** from the event log, with gaps (section 4). | ACP `tool_call`, `tool_call_update`, `plan`, gateway session status, approvals. | "Running now" strip in the session and a project line on home. |

## 1. What Bob reports now (repo evidence)

### 1.1 Update kinds the app understands

File: `ACPClient/Sources/ACPClient/ACP/SessionUpdateHandler.swift` (`interpretUpdate`, switch on `sessionUpdate`).

| Kind | Handled as | Usage fields | Source file |
| --- | --- | --- | --- |
| `agent_message_chunk` | `agentMessage` (plus media blocks, `ContentBlockParsing.swift`) | no | SessionUpdateHandler.swift |
| `agent_thought_chunk` | `agentThought` | no | same |
| `user_message_chunk` | `userMessage` | no | same |
| `tool_call` | `toolCall(ACPToolCallInfo)` (title, kind, status, id) | no | same |
| `tool_call_update` | `toolCallUpdate` (status, title, kind, output) | no | same |
| `plan`, `plan_update` | `planUpdate(entries)`, max 200 | no | SessionMetaUpdateParsing.swift |
| `plan_removed` | `planRemoved` | no | same |
| `session_info_update` | `sessionInfo(title)`; `updatedAt` is ignored | no | SessionMetaUpdateParsing.swift |
| `usage_update` | `usage(ACPSessionUsage)`: `used` (or `usedTokens`), `size` (or `contextSize`), `cost` `{amount, currency}` | **yes, the only usage fields in the app** | SessionMetaUpdateParsing.swift, lines 28 to 90 |
| `current_mode_update` | `modeChange` | no | SessionUpdateHandler.swift |
| `config_option_update` | `configOptionsUpdate` | no | same |
| `available_commands_update` | `availableCommandsUpdate` | no | same |
| unknown | text fallback only | no | same |

Display side: `ACPCode/Fork/Session/ForkSessionMeta.swift` (`usage`, `ForkUsageFormat.line`), `ACPCode/SessionDetailView.swift:120` (`SessionUsageFooter` under the composer), `ACPCode/Fork/Session/SessionPlanView.swift:70-73`, and `ACPCode/ACPSessionViewModel.swift:728` (routes `.usage`, `.planUpdate`, `.sessionInfo` to the meta state).

The decision record says the usage and plan shapes are "verify" against Bob (`docs/DECISIONS.md` D-070). This research confirms the shape from Bob's own schema (section 2.2): Bob's `usage_update` uses exactly `used`, `size` and `cost {amount, currency}`, and its plan kinds are `plan` and `plan_update`. Bob's server emits only `plan`, not `plan_update` (section 2.2). The app handles both, so nothing is broken.

### 1.2 Gateway forwarding

- Every agent `session/update` is written to the event log unchanged and sent to subscribers as `_acpcode/event` (`gateway/internal/server/supervisor.go` `notify`, lines ~320 to 385; `gateway/internal/store` `events` table; D-027). The gateway therefore already forwards a Bob `usage_update` to the phone today, with no gateway change, and replays it on reopen.
- The gateway reads only two kinds itself: `current_mode_update` (`currentModeId`) and `session_info_update` (`title`, `supervisor.go` lines 337 to 350).
- Session status is computed in `gateway/internal/server/sessions.go` lines 60 to 90 (`awaiting_approval` from open approvals, `running` from memory, otherwise the stored `idle` or `error`). The stored value is set in `supervisor.go` `logTurnEnded` (~line 740).
- The gateway does not keep any usage numbers. The sessions table has no usage column.
- Agent lifecycle (`agent_start`, `agent_exit`, `agent_error`, `agent_idle_stop`) goes only to the audit log (`supervisor.go` lines 159, 177, 197, 245; `idle.go` line 147). Phones never receive it.

### 1.3 Captured wire evidence in the repo

- `gateway/test/fixtures/bob-initialize-2.0.9.json`: the `initialize` result. Capabilities are `loadSession`, `sessionCapabilities` (list, delete, resume, close), `promptCapabilities`, `mcpCapabilities.http`, and `_meta["bob/extensions"]`. No usage or context capability is advertised.
- `docs/RESULTS.md`, 2026-11-07 "Open questions on Bob 2.0.9" (around lines 965 to 1000): `tool_call`, `tool_call_update` (keys `content, rawOutput, sessionUpdate, status, toolCallId`), `session_info_update`, `available_commands_update`. No `usage_update` appears in any captured stream.
- A repository-wide search (`usage_update`, `usedTokens`, `contextSize`, `plan_update`) finds no recorded Bob payload with usage. The only matches are the parser, its tests, and the docs.
- Captured `sessionUpdate` kinds in the repo's fixtures and tests: `tool_call`, `tool_call_update`, `plan`, `agent_message_chunk`, `user_message_chunk`, `current_mode_update`, `config_option_update`, `available_commands_update`.

## 2. Bob's own interface

### 2.1 Commands (`bob --help`, `bob acp --help`, `bob run --help`, `bob chat --help`, `bob mcp --help`)

- Top level: `chat`, `run`, `mcp`, `acp`, plus `--list-tasks`, `--show-license`, `--accept-license`, `--resume`. There is **no** `account`, `usage`, `balance`, `quota` or `whoami` command.
- `bob acp`: `--log-level`, `--trust`, `--auto-approve`, `--disable-mcp`, `--disable-subagents`, `--accept-license`. No usage flag.
- `bob run`: `--format pretty|json|stream-json`, `--max-cost <number>` (a per-run budget limit, not a balance), `--max-turns`. `bob mcp`: list, add, remove, enable, disable. None reports usage.

### 2.2 Bundle inspection (static, `bob.js` 15.6 MB, read only)

- **Schema:** the ACP schema includes `usage_update` = `{used: number, size: number, cost?: {amount, currency}, _meta?}` (search `Xil=rr({used:`). The session-update union also lists `plan_update` and `plan_removed`.
- **Emitters:** Bob's ACP server (class `U_t`, `sendUpdate` and `notify(n1.client.session.update, ...)`) emits these kinds only: `agent_message_chunk`, `agent_thought_chunk`, `user_message_chunk`, `tool_call`, `tool_call_update`, `plan` (entries `{content, status, priority: "medium"}`), `current_mode_update`, `available_commands_update`, `session_info_update` (`title`, `updatedAt`). **No code path emits `usage_update`, and no `config_option_update` or `plan_update` either.**
- The ACP task class has no spend hook. The `onSpend` callbacks exist in the CLI and subagent classes only.
- **Internal context tracking exists but is not sent:** the engine keeps `contextTokens` per spend event, `contextWindow` from model info (`max_input_tokens`), and auto-compacts at `compactionThresholdPercent: 0.9`. It also emits `onCompactionStart`, which the ACP server turns into an `agent_thought_chunk` "Compacting conversation context...". That is a text signal only.
- **Filter:** `isSessionTask(t)` returns `t === this.sessionId`. Only events of the root task reach ACP, so subagent activity is not forwarded (verify with a live subagent run).
- **Headless stats:** `bob run --format json|stream-json` ends with a `result` event whose `stats` holds `task_id`, `duration_ms`, `session_costs`, `max_cost`, `tool_calls`, and, behind a gate `Dm()` that is not identified, `total_tokens`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cache_ratio`. The `credential_type` field (`byok` or `system`) and `totalCost` appear in the model-usage schema. These are per-run totals, not a balance and not context occupancy. They are not on the ACP path.
- **Endpoints:** the bundle contains `/apprapp/events/v1/instances/<id>/usage` (POST, a metering upload) and `/apprapp/feature/v1/instances/<id>/config`. No balance or quota read endpoint was found. A web-search response carries a `credits` number per call (`onSpend`), which is per call, not a balance.
- **Conclusion:** Bob has no client-readable balance. A balance, if it exists, sits behind IBM's service and needs an API this bundle does not show. This is a finding from static inspection, so "verify" applies.

### 2.3 Auth facts that matter for privacy

ACP.md: with `BOB_API_KEY` set, no login is needed; otherwise SSO with tokens stored in the Bob home. The usage design must never show or log the key, the SSO token, the account or team ids, or `credential_type` beyond a neutral label.

### 2.4 Live probe (one prompt)

Script: `<scratchpad>/usage-probe/probe.mjs` (not in the repo). It starts `bob acp --accept-license --log-level warn` with a disposable `HOME` and a scratch cwd, sends `initialize`, `session/new`, and one `session/prompt` ("Reply with the single word: ok"), then stops. Only key names and kinds were printed. The key was read from the repo `.env` in the script's own process and never printed.

Result:
- `initialize` keys: `protocolVersion, agentCapabilities, authMethods, agentInfo`. `agentCapabilities` keys: `_meta, loadSession, sessionCapabilities, promptCapabilities, mcpCapabilities`.
- `session/new` keys: `sessionId, modes`.
- `session/update` seen: `available_commands_update` (1), `agent_message_chunk` (1), `session_info_update` (1, keys `title, updatedAt`).
- **No `usage_update`.** No `plan`, no tool call (none was needed).
- Prompt response keys: `stopReason` only. Value `end_turn`. No usage in the response.

Cost of the probe: one prompt, a few thousand input tokens (Bob's system prompt plus the prompt) and a short reply. The exact figure was not measured. Measuring it would need `bob run --format json`, which was not run.

## 3. ACP specification

- **Session Context Size and Cost RFD** (`https://agentclientprotocol.com/rfds/session-usage`), status **Completed**, moved 2026-06-05. Fields:
  - `used` (number, required): tokens currently in context.
  - `size` (number, required): total context window in tokens.
  - `cost` (object, optional, nullable): cumulative session cost, with `amount` (required) and `currency` (required, ISO 4217).
  - Cost is cumulative for the session, not per turn. Clients derive remaining (`size - used`) and percent (`used / size`).
  - Send after `session/new`; after `session/load`, `session/resume` or `session/fork` when restoring; after `session/prompt` when data is available; and when context or cost changes significantly. Do not send it when no context window size is known.
  - Context-window usage counts every token currently in context, including cached ones (RFD text).
  - After compaction, `usage_update` can drop. The Compaction RFD (draft) says `usage_update` and compaction updates do not replace each other.
  - Subagent RFD (draft): context usage is local to each session and is not summed across a tree.
- **Announcement** (`https://agentclientprotocol.com/announcements/session-usage-stabilized`, 2026-06-05): `usage_update` is stable. Agents "can report the current context token count and context-window size, along with optional cumulative session cost".
- **Still draft:** end-turn token accounting on the prompt response (the separate End-Turn Token Usage RFD). The Session Usage RFD does not add it to `PromptResponse`. Bob's prompt response has no usage in any case (section 2.4).
- The protocol version is 1 (Bob's `initialize`). The announcement does not state a version number; "v1" is inferred from its links.
- The repo's vendored ACP docs (`ACPClient/Docs`) do not mention `usage_update`, so the pinned docs predate the RFD. The app code follows the RFD's shape anyway.
- Implementation gaps reported by others (search results, not verified here): several agents do not send `usage_update` yet; some clients treated cumulative cost as per-turn, and some overwrote the context value with the cumulative prompt total. Sources: `https://github.com/QwenLM/qwen-code/issues/8513`, `https://github.com/zed-industries/codex-acp/issues/165`, `https://github.com/agentclientprotocol/claude-agent-acp/issues/375`, `https://github.com/NousResearch/hermes-agent/issues/101817`. The app should keep `used` and `cost` separate, as the RFD says.

Conclusion for (b): the spec defines what we need, the app already parses it, and Bob 2.0.9 does not send it. Bob's own `session_info_update.updatedAt` is the only timing signal Bob sends (ACP.md: "title and last-activity updates after successful prompt turns").

## 4. Process visibility

### 4.1 What the event log already shows

- `tool_call` (title, kind, status `pending` or `in_progress`, `toolCallId`). For `execute_command` the title is the command text itself (`TQe` in the bundle). For other tools it is a label such as "Running Make Image (probe-image)".
- `tool_call_update` with status `in_progress`, `completed` or `failed`, plus content and `rawOutput`.
- `plan` entries with `status` `pending`, `in_progress` or `completed`.
- `session/request_permission` (open and answered, via the approval queue).
- `_acpcode/turn_started` and `_acpcode/turn_ended` (stop reason or error).
- Session status from the index: `running`, `awaiting_approval`, `idle`, `error`.
- A running tool is derivable: a `tool_call` with no later terminal `tool_call_update` for its `toolCallId`. The gateway does not compute this today; the app can, from the log.

### 4.2 What is missing

- **Subagent work** is filtered out by Bob's ACP server (section 2.2). Live check needed.
- **Agent process and container state** (starting, running, stopping, stopped, idle stop) is audit-only. Phones cannot tell a cold start from a stopped project.
- **Background processes** started by a command that outlives the tool call: Bob shows only the tool call. Nothing tracks them.
- **MCP server state** (connected, failed, tool list) is not on the wire.
- **Compaction** is a text thought, not a state.
- **Bob's own context and cost** are not sent (sections 2.2 and 3).

## 5. Design

### 5.1 Where each number comes from

| Number | Source | Status | Update trigger |
| --- | --- | --- | --- |
| (a) Bob balance | None on any interface | **Unavailable** | n/a |
| (a') Session cost, if Bob sends it | ACP `usage_update.cost` (cumulative, currency) | Measured, agent-reported; not a balance | Each `usage_update` |
| (b) Context used / size / left | ACP `usage_update.used`, `size` | Measured, agent-reported; **unavailable until Bob sends it** | Each `usage_update` (spec: after prompt, on load and resume, and on significant change) |
| (b') Context estimate from text | Characters or tokens counted by the app | Estimated; **rejected**: no tokenizer for Bob's model, and the error grows with each compaction | n/a |
| (c) Running tools | Log: `tool_call` without a terminal `tool_call_update` | Measured | Each event |
| (c') Turn in progress | Gateway session status `running` | Measured (in memory, lost on gateway restart and then recomputed as `idle`) | Turn start and end |
| (c') Approvals waiting | Gateway approvals | Measured | Each approval event |
| (c') Agent process state | New gateway notification (below) | Measured, once built | On change |

### 5.2 Where it appears in the app

- **Session header:** a context chip, for example "Context 42%, 84k left", when `usage_update` has been received. When not, the chip reads "Context: not reported by Bob". A tap opens the usage sheet.
- **Usage sheet:** used, size, left and percent; cost with its currency when Bob sends it; "Last updated"; the source line "Reported by Bob (ACP usage_update)"; and a row "Bob balance: not available from Bob" with a short explanation. No estimate is shown.
- **Home list:** a thin context bar on each session row (from the index, below), shown only when known.
- **Running now strip** (session view): a count and the titles of running tools (the command text for `execute_command`), with an "awaiting approval" item when one is open. Subagent work is not included, and the strip says so when subagents are disabled or not shown.
- **Project header on home:** agent state "running", "idle", "starting" or "stopped", from the new notification.

### 5.3 How the gateway forwards it

Recommendation (Option A): **no new usage notification for ACP data.** Keep forwarding `usage_update` as an event (already the case), and add two things:

1. **Index field.** The gateway stores the last `usage_update` per session (new columns `usage_used`, `usage_size`, `usage_cost_amount`, `usage_cost_currency`, `usage_at`; schema version 6, migration in place, as D-051 and D-067 did). `_acpcode/sessions/index` returns `usage: {used, size, costAmount?, costCurrency?, updatedAt}` per session, or omits it when unknown. This feeds the home list without a subscribe.
2. **Project agent state.** A new non-logged notification `_acpcode/project/state {projectId, agent: "stopped"|"starting"|"running"|"stopping", since}`, sent to sockets that have called `projects/list` or `sessions/index` for that project, and on each change. It mirrors `git/changed`: change-only, at most 2 per second per project (NFR-9 pattern). Audit already records the same events.

Option B, a new `_acpcode/usage` notification that the gateway synthesises, is rejected. It would duplicate the ACP field, and it would be needed only if Bob reported usage outside ACP, which it does not.

No change to the event log format is needed. `usage_update` events already replay on reopen.

### 5.4 How often it updates

- Gateway: forwards `usage_update` at once. Stores the last value. The index reads it on demand.
- App: applies at most one update per second per session to the UI (a throttle, no data loss; the last value wins).
- Home: refreshes on open, pull, and `turn_ended` for a session, as the approvals inbox does (D-040). No timer, because a timer would start project containers only through git (D-034), which this design does not add.
- Project state: change-only, max 2 per second per project.

### 5.5 Privacy rules

- Never show, log or push the API key, SSO tokens, account, team, or organization ids. `credential_type` is not forwarded. (It is not sent over ACP anyway.)
- Usage numbers and cost are owner data. They go to the owner's own devices over the existing TLS connection only. They never go into a push payload (NFR-11) and never into the audit log. The audit may hold the event name only (for example `usage_received`), like the other events.
- Tool titles can hold a command, which can hold a secret (for example a token typed into a shell). The app may show them on the phone, as the transcript already does. They must not reach the audit log, a push, or the index.
- The sessions index and the project state carry counts and status only, no prompt or output text.
- The balance row says what is not known. The app never estimates a balance.

## 6. Phase plan

- **U0 (owner, no code):** decide section 7 items 1 and 2. Ask IBM whether a Bob release emits `usage_update` (the schema already lists it). Check newer `@ibm/bob` versions for an emitter (`npm view @ibm/bob versions` and a diff of `dist/bob.js` for `usage_update`). This is read-only.
- **U1 (gateway and app; works for any ACP agent that reports usage):**
  - Gateway: schema v6 columns; store `usage_update` per session; `usage` in `sessions/index`. Wire test with the fake agent extended to emit `usage_update` (`gateway/test/fixtures/fake-agent.mjs`), and a check that the index keeps the last value and survives a restart. Mutation: drop the store write; the test must fail.
  - App: context chip, usage sheet, home row bar, "not reported" state, throttle. Swift unit tests for the chip text and the throttle; the parser already has tests (`ACPClient/Tests/ACPClientTests/SessionMetaUpdateTests.swift`).
  - Blocked for live check: real numbers until Bob emits `usage_update`.
- **U2 (running work):**
  - Gateway: `_acpcode/project/state` notification (not logged), with a wire test using the fake agent's lifecycle (start, idle stop, exit).
  - App: running-now strip derived from the log; subagent gap stated in the UI. Unit tests for the derivation (a `tool_call` with and without a terminal update). Mutation: count completed tools as running; the test must fail.
- **U3 (optional, owner's call):** measure one headless `bob run --format json` to learn whether `stats` has context tokens and what the cost of one minimal prompt is. This needs a separate spend and is not part of the ACP path. Not recommended unless the owner wants measured cost before U1.
- **Not planned:** a balance display. No interface exists to build on.

## 7. Decisions for the owner (with recommendation)

1. **Bob balance.** Accept "not available from Bob" and build no estimate? **Recommend yes.** No interface exists, and an estimate would look like a fact.
2. **Context numbers.** Ship U1 now, showing "not reported by Bob" until Bob emits `usage_update`, and ask IBM for the emitter? **Recommend yes.** U1 costs little and turns on by itself when Bob sends the field. Context numbers should not be faked meanwhile.
3. **Gateway shape.** Index field plus the project state notification (Option A), not a new usage notification? **Recommend Option A.**
4. **Subagent visibility.** Accept the gap for now and state it in the app? **Recommend yes**, and test one live subagent run before stating the gap as fact.
5. **Cost display.** Show cost only when Bob sends it, with its currency, and label it "session cost (cumulative)"? **Recommend yes.**
6. **Live cost probe (U3).** Spend one more prompt to measure per-run stats? **Recommend no** until item 2 is decided.

## 8. What cannot be known, and why

- **Bob balance or quota:** no client interface found (help output, bundle, ACP docs). It may exist on IBM's service. Only IBM can say.
- **Context in use, from Bob:** Bob tracks it internally (`contextTokens`, `contextWindow`) but does not send it over ACP in 2.0.9. Only a Bob release can change this.
- **Context in use, from the app:** not knowable without Bob's tokenizer and Bob's system prompt. An estimate would be wrong after each compaction.
- **Subagent and background work:** filtered by Bob's ACP server, or not tracked by Bob at all.
- **Per-run tokens and cost in headless mode:** present in `bob run` stats, behind a gate not identified (`Dm()`). Not on the ACP path. Not measured.
- **Container and agent state beyond the gateway's own view:** the gateway sees its own process only.

## 9. Files and evidence

- Repo: `ACPClient/Sources/ACPClient/ACP/SessionUpdateHandler.swift`, `SessionMetaUpdateParsing.swift`, `SessionUpdateParsing.swift`; `ACPCode/Fork/Session/ForkSessionMeta.swift`, `SessionPlanView.swift`; `ACPCode/SessionDetailView.swift`; `ACPCode/ACPSessionViewModel.swift`; `gateway/internal/server/supervisor.go`, `sessions.go`, `idle.go`, `subscribe.go`; `gateway/test/fixtures/bob-initialize-2.0.9.json`, `fake-agent.mjs`; `docs/RESULTS.md` (2026-11-07 open questions), `docs/DECISIONS.md` (D-027, D-030, D-032, D-040, D-070).
- Bob: `/opt/homebrew/lib/node_modules/@ibm/bob/ACP.md`, `dist/bob.js` (static search only).
- Probe: `<scratchpad>/usage-probe/probe.mjs`, run once, with a disposable HOME under `<scratchpad>/usage-probe/home`.
- Spec: `https://agentclientprotocol.com/rfds/session-usage`, `https://agentclientprotocol.com/announcements/session-usage-stabilized`.
