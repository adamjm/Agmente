# ACPClient Package Guide

## Scope
Typed ACP transport/service package used by the iOS app.

## External Repo Paths
- Read `.acpcode.paths` (from repo root) before cross-checking ACP upstream docs/spec.
- ACP upstream reference root: `ACPCODE_ACP_REPO/docs`.

## Architecture Model
- Transport concerns, request orchestration, and ACP parsing are separated layers.
- Public service APIs should remain typed and hide wire-format details from callers.
- Parsing helpers should be resilient to optional/partial ACP payloads.

## Extension Pattern
When adding ACP method support:
1. Add the method constant and typed payload mapping.
2. Expose a typed service wrapper.
3. Add response/event parsing coverage.
4. Ensure delegate and pending-request behavior remain correct.
5. Add package tests for success and failure paths.

## Compatibility Rules
- Preserve support for server-initiated JSON-RPC requests (do not treat as transport errors).
- Keep slash-escaping compatibility option functional.
- Keep request ID/pending continuation behavior deterministic.
- Keep reconnection/disconnect semantics from breaking in-flight request handling.

## Tests
- Run package tests for `ACPClient`.

## Gateway `_acpcode/*` methods
The typed wrappers are in `Sources/ACPClient/Gateway/`. The full list is in `docs/SPEC.md` 6.2. Added 2026-11-07:
- `_acpcode/sessions/index` (`GatewayClient+Usage.swift`): each row may carry `usage` (`used`, `size`, optional `costAmount`/`costCurrency`, `updatedAt`), omitted when Bob has not reported usage (contract C1, D-092). Remaining context is `size - used`, shown only when `size > 0`.
- `_acpcode/projects/list`: the socket is sent one `_acpcode/project/state` snapshot per listed project before the response (D-104), then each change (C2). `_acpcode/sessions/index` does the same for the project it lists.
- Notification `_acpcode/project/state` `{projectId, agent, since}` (`GatewayProjectState.swift`, D-102), with `agent` one of `stopped`, `starting`, `running`, `stopping`; any other value decodes to `.unknown`, which is never shown. Change-only, at most two per second per project. Not in the event log. `AppViewModel.handleIncoming` sends it to `handleGatewayProjectState` (`ACPCode/Fork/Gateway/AppViewModel+Gateway.swift`), which records it in `GatewayHomeModel`; the home shows it on the project header. The listing snapshot gives the current state when a socket starts listing, so a project already running on reconnect is not shown as stopped.
- Connector (`GatewayConnector.swift`, `GatewayClient+Connector.swift`, D-097; contract C5): `_acpcode/connector/pending` (`{pairings}`), `_acpcode/connector/approve` (`{pairingId, scope}` returns `{grantId}`), `_acpcode/connector/deny` (`{pairingId}`), `_acpcode/connector/grants` (`{grants}`), `_acpcode/connector/revoke` (`{grantId}`).
- Git at creation and credentials (D-105; `GatewayGitSetup.swift`): `projects/create` takes `createFolder: true` and, when git is on, `gitInit`, `gitRemote` and `credentialId`; the result's `git` is `GatewayGitInit`. `_acpcode/git/credentials/list` (metadata only), `set` (returns `{id}`; the token is sent once and never read back), `delete`, and `_acpcode/git/push` (`confirm` is always true). A gateway without these answers -32601, which `GatewayError.isMethodNotFound` reports. `ACPLogRedaction` keeps a `credentials/set` message out of the send log, so a token is never logged.
