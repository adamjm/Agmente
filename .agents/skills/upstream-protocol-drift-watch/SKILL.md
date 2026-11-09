---
name: upstream-protocol-drift-watch
description: Dynamically inspect ACP and Codex upstream repos using .acpcode.paths, detect protocol/API/spec drift, and produce a risk-scored regression report. Use when checking for new APIs, method changes, or protocol/spec changes after upstream updates.
---

# Upstream Protocol Drift Watch

## Goal

Catch upstream ACP/Codex changes early, especially:
- new RPC/API methods,
- removed or renamed methods,
- protocol/spec file changes that can cause ACP Code regressions.

This skill is dynamic by default: always read current local repos and refs at runtime.

## Inputs

Collect these from the user request when present:
- optional `from_ref` and `to_ref` (for each repo, or shared),
- whether to check `codex`, `acp`, or both.

If refs are not provided:
1. Use `HEAD..origin/main` for each upstream repo.
2. If `origin/main` is unavailable, use `HEAD~1..HEAD`.
3. If `HEAD~1` is unavailable, use `HEAD..HEAD` and report that no baseline exists.

Always fetch upstream remotes before scanning:
```bash
git -C <repo> fetch --all --prune
```

## Required Runtime Sources

1. Read repo-local path registry:
```bash
cat .acpcode.paths
```
2. Resolve:
- `ACPCODE_CODEX_REPO`
- `ACPCODE_ACP_REPO`
3. Validate both paths are git repos before scanning.

## Dynamic Scan Workflow

1. Resolve diff range per repo.
- Use user-provided refs if given.
- Otherwise use `HEAD..origin/main`.
- Always perform `git fetch --all --prune` before resolving refs and diff range.

2. Collect changed files in protocol-relevant areas.
- Codex focus paths:
  - `codex-rs/app-server-protocol`
  - `codex-rs/app-server`
- ACP focus paths:
  - `docs/schema`
  - `docs/protocol`
  - `docs/rfds`

3. Extract method-like token changes from patch.
- Treat quoted/backticked values like `foo/bar` as method candidates.
- Track added and removed candidates separately.

4. Compare against locally supported methods.
- Codex local method sources:
  - `AppServerClient/Sources/AppServerClient/AppServerMethods.swift`
  - `AppServerClient/Sources/AppServerClient/AppServerEventParser.swift`
- ACP local method sources:
  - `ACPClient/Sources/ACPClient/ACP/ACPMethods.swift`
  - `ACPClient/Sources/ACPClient/ACP/ResponseDispatcher.swift`

5. Build a risk score and severity.

## Risk Scale

- `0-19`: none
- `20-44`: low
- `45-74`: medium
- `75-100`: high

Suggested scoring:
- Path impact (max 70):
  - protocol/schema core files changed: `+35` each bucket
  - app-server runtime/docs changed: `+10` to `+20`
  - RFD/docs-only changes: `+8` to `+12`
- Method impact (max 30+):
  - added method not recognized locally: `+12` each (cap 36)
  - removed method referenced locally: `+15` each (cap 45, immediate high priority)
  - payload shape changes on core methods (`thread/*`, `turn/*`, `session/*`): add `+10`

Escalation rule:
- Any removed locally referenced method => at least `medium`.
- Multiple removed locally referenced methods => `high`.

## Output Contract

Always return:
1. Summary table: repo, diff range, changed file count, severity, score.
2. `Added unknown methods` list.
3. `Removed supported methods` list.
4. Key changed files likely to affect compatibility.
5. Recommended follow-up tests:
- `swift test --package-path AppServerClient`
- `swift test --package-path ACPClient`
- targeted `ACPCodeTests` protocol suites.

## Guardrails

- Do not write or require a persistent baseline file unless user explicitly asks.
- Do not create new scripts for this check unless user explicitly asks.
- Prefer live git state and direct diff inspection each run.
- Do not skip fetch unless user explicitly asks to avoid network operations.
