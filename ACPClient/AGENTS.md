# ACPClient Package Guide

## Scope
Typed ACP transport/service package used by the iOS app.

## External Repo Paths
- Read `.agmente.paths` (from repo root) before cross-checking ACP upstream docs/spec.
- ACP upstream reference root: `AGMENTE_ACP_REPO/docs`.

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

## Gateway `_agmente/*` methods
The typed wrappers are in `Sources/ACPClient/Gateway/`. The full list is in `docs/SPEC.md` 6.2. Added 2026-11-07:
- `_agmente/sessions/index` (`GatewayClient+Usage.swift`): each row may carry `usage` (`used`, `size`, optional `costAmount`/`costCurrency`, `updatedAt`), omitted when Bob has not reported usage (contract C1, D-092). Remaining context is `size - used`, shown only when `size > 0`.
- `_agmente/projects/list`: the socket is sent one `_agmente/project/state` snapshot per listed project before the response (D-104), then each change (C2). `_agmente/sessions/index` does the same for the project it lists.
- Notification `_agmente/project/state` `{projectId, agent, since}` (`GatewayProjectState.swift`, D-102), with `agent` one of `stopped`, `starting`, `running`, `stopping`; any other value decodes to `.unknown`, which is never shown. Change-only, at most two per second per project. Not in the event log. `AppViewModel.handleIncoming` sends it to `handleGatewayProjectState` (`Agmente/Fork/Gateway/AppViewModel+Gateway.swift`), which records it in `GatewayHomeModel`; the home shows it on the project header. The listing snapshot gives the current state when a socket starts listing, so a project already running on reconnect is not shown as stopped.
- Connector (`GatewayConnector.swift`, `GatewayClient+Connector.swift`, D-097; contract C5): `_agmente/connector/pending` (`{pairings}`), `_agmente/connector/approve` (`{pairingId, scope}` returns `{grantId}`), `_agmente/connector/deny` (`{pairingId}`), `_agmente/connector/grants` (`{grants}`), `_agmente/connector/revoke` (`{grantId}`).
