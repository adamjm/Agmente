# AppServerClient Package Guide

## Scope
Typed Codex app-server transport/service package used by the iOS app.

## External Repo Paths
- Read `.acpcode.paths` (from repo root) before cross-checking Codex app-server upstream source.
- Codex upstream reference root: `ACPCODE_CODEX_REPO/codex-rs`.

## Architecture Model
- Transport and request orchestration are separated from protocol payload parsing.
- Service APIs should remain typed and avoid leaking raw JSON-RPC details to callers.
- Event parsing should map wire notifications/requests into stable app-facing event types.

## Protocol Notes
- Default wire mode omits `"jsonrpc":"2.0"` header, with optional inclusion toggle.
- Handle both notifications and server-initiated requests (for approvals and similar flows).
- Keep event parser mappings aligned with upstream app-server method names.
- Treat method-name and payload-shape drift as compatibility-sensitive changes.

## Codex Thread Maintenance
Final thread hydration behavior used by ACP Code for Codex:

1. Open/reconnect prefers non-destructive attach:
   - `thread/loaded/list`
   - if loaded: `addConversationListener` + `thread/read(includeTurns: true)`
2. `thread/resume` is fallback only:
   - use when thread is not loaded, or listener attach/read path is unavailable
3. Merge behavior:
   - preserve richer local tool-call rows/outputs
   - append newly resumed items
   - avoid duplicate assistant rows via normalized content + tool-call identity checks
4. Persistence for cold relaunch:
   - send `persistExtendedHistory: true` on `thread/start` and `thread/resume`

Maintenance guardrails:
- Do not reintroduce unconditional `thread/resume` during reconnect.
- Do not immediately issue another resume after successful listener+read attach.
- Keep `includeTurns: true` on read-based hydration paths.
- Remember that `persistExtendedHistory` is not backfilled for old sessions.

See `AppServerClient/codex-thread-hydration.md` for the expanded maintenance checklist and regression scenarios.

## Extension Pattern
When adding app-server method support:
1. Add method name constant.
2. Add payload model and params encoder.
3. Add typed service wrapper.
4. Add response parser coverage if result is typed.
5. Add or update event parser mapping if notifications/requests are involved.
6. Add package tests for request flow, parse flow, and error handling.

## Tests
- Run package tests for `AppServerClient`.
