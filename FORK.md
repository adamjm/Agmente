# Agmente for IBM Bob (private fork)

This fork turns Agmente into a remote client for IBM Bob Shell that is safe on the public internet. It adds a gateway (`gateway/`) that replaces `stdio-to-ws`, and a phased plan for the app changes.

Start with `docs/SPEC.md`. The upstream `README.md` still describes the original app.

## Start

1. Unzip this overlay at the root of your fork. It adds files and replaces `CLAUDE.md` only (D-010).
2. In `.gitignore`, replace the line `.claude/` with these three lines, so git tracks `/next` and the settings (D-011):
   ```
   .claude/*
   !.claude/settings.json
   !.claude/commands/
   ```
3. Install Go 1.26 or later (the gateway) and Node.js 22.13 or later (the test suite, the fake agent and Bob).
4. Install the gateway dependency:
   ```bash
   npm ci --prefix gateway
   ```
5. Run all checks:
   ```bash
   scripts/check.sh
   ```
   On macOS this also runs the Swift package tests.
6. Open Claude Code at the fork root and run `/next`. It works the first open task in `docs/PLAN.md`, and stops for your approval at the start of each phase.

## Try the gateway locally

```bash
(cd gateway && go build -trimpath -o bin/agmente-gateway ./cmd/agmente-gateway)
gateway/bin/agmente-gateway new-token iphone owner     # copy the token; put the entry in config.json
cp gateway/config.example.json gateway/config.json  # edit tokens, agent.command, projects.roots
gateway/bin/agmente-gateway --config gateway/config.json --dry-run
gateway/bin/agmente-gateway --config gateway/config.json
```

In the current, unmodified app, add a server with `ws://127.0.0.1:8787` (simulator) and the token as the bearer token. For a phone on the internet, put Caddy in front (`deploy/Caddyfile`) and use `wss://`.

## File map

| Path | What it is |
| --- | --- |
| `CLAUDE.md` | Instructions for Claude Code: role, rules, workflow |
| `.claude/commands/next.md` | `/next`: work the next open task |
| `.claude/settings.json` | Allowed check commands; denied secret files |
| `docs/SPEC.md` | Requirements, interfaces, tests |
| `docs/ARCHITECTURE.md` | Components, data flows, trust boundaries |
| `docs/PLAN.md` | Phases and tasks with status |
| `docs/DECISIONS.md` | Decision log (append only) |
| `docs/RESULTS.md` | Test results with commands and output |
| `scripts/check.sh` | The check gate |
| `scripts/check-docs.mjs` | Keeps SPEC, PLAN and RESULTS consistent |
| `gateway/cmd/agmente-gateway/` | Gateway entry point: run, `--dry-run`, `new-token` |
| `gateway/internal/` | Gateway packages: `config`, `audit`, `jsonv` (one-line JSON re-encoder), `server` (admission, guard, agent process) |
| `gateway/test/` | Gateway tests, fake ACP agent, Bob capability fixture, benchmark |
| `gateway/bin/agmente-gateway new-token` | Create a device token and its hashed config entry |
| `deploy/` | Caddy (mutual TLS) and systemd examples, marked "verify" |
