# ACP Code Codex UI Test Harness Contract

Scenario source of truth:
- `e2e/scenarios/codex/local-cli-smoke.md`

This file documents only the environment-variable contract used by the existing UI test harness.

## Test Target

- Project: `<repo-root>/ACPCode.xcodeproj`
- Scheme: `ACPCode`
- UI test id: `ACPCodeUITests/ACPCodeUITests/testCodexDirectWebSocketConnectInitializeAndSessionFlow`

## Runtime Env Vars Used By The Test

- `ACPCODE_E2E_CODEX_ENABLED`
  - Required truthy value (`1`, `true`, `yes`, `y`).
  - If unset/false, test intentionally `XCTSkip`s.
- `ACPCODE_E2E_CODEX_ENDPOINT`
  - Preferred endpoint, for example `ws://127.0.0.1:8788`.
  - Parsed into protocol (`ws`/`wss`) plus host+port for Add Server form.
- `ACPCODE_E2E_CODEX_HOST`
  - Fallback when endpoint is not set, for example `127.0.0.1:8788`.
  - Protocol defaults to `ws`.
- `ACPCODE_E2E_CODEX_PROMPT`
  - Optional prompt override for the send-message step.

## Cleanup Expectations

- Stop any app-server process started for the run.
- Uninstall app from simulator:
  - `xcrun simctl uninstall <UDID> com.example.ACPCode`
