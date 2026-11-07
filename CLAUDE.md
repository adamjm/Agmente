# CLAUDE.md

## Role
You are the engineer for the Agmente fork for IBM Bob: an iOS app (Swift) and a gateway (Go) in `gateway/` (D-021).
You write small, tested code. You report facts.
You do not guess about Bob, ACP or Apple API behaviour: you test it, or you mark it as unknown.

## Goal
Build the fork in `docs/SPEC.md`: a secure gateway, a hardened app, persistent multi-project sessions, git state, Bob support, rendering and management.
The work is done when every test in `docs/SPEC.md` section 7 has a recorded result in `docs/RESULTS.md`.
A "fail" result is a valid outcome. Do not change a test to make it pass.

## Context (read when needed, not all at once)
- Requirements and tests: @docs/SPEC.md
- Design and data flow: @docs/ARCHITECTURE.md
- Phased plan and status: @docs/PLAN.md
- Decisions and reasons: @docs/DECISIONS.md
- iOS conventions and protocol notes from upstream: `Agents.md` and the `AGENTS.md` file in each component folder.

## How to work
1. Read `docs/PLAN.md`. Find the first phase that is not complete.
2. Use plan mode for each new phase. Write the plan under "Plan notes". Stop for approval.
3. Build one task at a time. Run `scripts/check.sh` after each task.
4. Tick a task only when its check passes.
5. Record test results in `docs/RESULTS.md` with date, command and output.

## Rules
- The gateway must never approve a tool call. Reason: the phone's approval is the last control before a shell (D-009). Exception: the phone may send MCP `alwaysAllow` for named tools, by owner override (D-089); the gateway still never approves on its own.
- Never add a code path that lets an unauthenticated request spawn a process. Reason: that is the flaw this fork removes (F-1).
- Run git and Bob in the project container, never in the gateway process. Reason: repo config can run programs (F-20, D-008).
- Put new app code in new files under `Agmente/Fork/` or `Agmente/Security/` when it is a new feature. Upstream files may be changed freely when that is the cleaner design. Reason: this is a hard fork with no upstream merges (D-017).
- Keep ACP and Codex behaviour separate unless a shared abstraction is tested. Reason: upstream rule in `Agents.md`.
- Never read, print or commit secrets. Use environment variables or the Keychain. Tokens go in config only as SHA-256 hashes.
- Do not skip, delete or loosen a test to get a green check.
- Standard library first. The gateway has two dependencies, `github.com/coder/websocket` and `modernc.org/sqlite` (D-021, D-023); the Node test suite and Bob probes have one (`ws`). Add another only with a D-n entry.
- Gateway tests are wire-level: they start the gateway as a process and never import its code. Reason: the same suite checks any implementation (D-021).
- Cite the doc page or version for every claim about external behaviour. Mark unverified config keys "verify".

## When you are blocked
- Missing credential (Bob licence, `BOB_API_KEY`, APNs key, Apple account): write `BLOCKED: <what>` in RESULTS.md and go to the next task that does not need it.
- Not on macOS for an app task: write `BLOCKED: needs macOS` and go to the next gateway task.
- External behaviour differs from the spec: record what you saw, then stop and ask.
- A check fails twice after a fix attempt: stop and report the error and what you tried.

## Report format (end of each task)
- Done: <task id and one line>
- Check: <command> → <pass/fail>
- Changed files: <list>
- Next: <task id> or `BLOCKED: <reason>`

## Commands
- All checks: `scripts/check.sh`
- Build the gateway: `(cd gateway && go build -trimpath -o bin/agmente-gateway ./cmd/agmente-gateway)`
- Gateway wire tests (default target: `gateway/bin/agmente-gateway`; another with `AGMENTE_GATEWAY_CMD='["/abs/path"]'`): `npm test --prefix gateway`
- Go unit tests: `(cd gateway && go test ./...)`
- Gateway latency (NFR-1, NFR-2): `node gateway/test/bench.mjs` (same `AGMENTE_GATEWAY_CMD`)
- App tests (macOS): `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test`
- New token: `gateway/bin/agmente-gateway new-token <device-id> <identity>`
