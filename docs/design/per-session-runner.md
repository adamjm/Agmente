# Per-session runner, Claude runner and separate worktree (D-125, D-126)

Status: building, 2026-11-27. This file is the contract every work stream builds against. Change it
only through the lead; a stream that needs a change says so in its report.

## Decisions (owner, 2026-11-27)

1. Claude Code runs as a runner: `@agentclientprotocol/claude-agent-acp` (ACP adapter, verified in a
   spike) which runs the `claude` CLI. The CLI is not an ACP agent by itself.
2. Every runner runs under the `srt` sandbox by default. Container images come later.
3. Model for the Claude runner: `claude-haiku-5-5` (verified through the model gateway; `claude-haiku-5-53` is refused with 403).
4. A runner is chosen per session, not per project. `projects.runner` becomes the project's default.
5. A separate git worktree is made only when the person ticks "separate worktree".

## Claude runner entry (verified env)

```json
"claude": {
  "name": "Claude Code",
  "command": ["/opt/homebrew/bin/claude-agent-acp"],
  "envPassthrough": ["PATH", "HOME", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
                     "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS", "CLAUDE_CODE_EXECUTABLE"],
  "secretsFile": "/Users/you/acpcode/claude.env",
  "allowedDomains": ["model-gateway.example.com"],
  "allowRead": ["/opt/homebrew", "/usr/local"]
}
```

- `claude.env` (mode 0600) holds `ANTHROPIC_AUTH_TOKEN=...`. The token goes in `ANTHROPIC_AUTH_TOKEN`, never `ANTHROPIC_API_KEY`.
- The non-secret values (`ANTHROPIC_BASE_URL=https://model-gateway.example.com`, `ANTHROPIC_MODEL=claude-haiku-5-5`,
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`, `CLAUDE_CODE_EXECUTABLE=/opt/homebrew/bin/claude`) go in the same file.
  A secrets file may hold any name the runner lists in `envPassthrough`.

## Config (D-126)

- `runners.<id>.secretsFile`: now allowed. Same rules as the single-agent `agent.secretsFile` (absolute, regular file, no group or other access, never sets HOME or PATH).
- `runners.<id>.allowedDomains` and `runners.<id>.allowRead`: per-runner srt lists. If absent, the runner gets the shared `runner.allowedDomains` / `runner.allowRead`.
  Resolved into `AgentRunner.AllowedDomains` / `AllowRead` at load. With kind `srt`, every runner must end up with at least one domain.
- Single-agent form: the one runner `default` also gets its `SecretsFile`, `SecretNames`, `SecretsIgnored`, `AllowedDomains`, `AllowRead`. `Config.SecretsFile` etc. stay set for that form (existing tests).
- `AgentRunner` fields (already in `internal/config/runners.go`): `SecretsFile`, `SecretNames`, `SecretsIgnored`, `AllowedDomains`, `AllowRead`.
- The runner side reads secrets, domains and read paths only from the `AgentRunner`, never from `Config.SecretsFile` or `Config.Runner.AllowedDomains`.

## Store (done, schema 11)

- `sessions.runner TEXT` (NULL = the project's runner). `Store.SetSessionRunner`, `Store.SessionRunner`.
- `projects.parent_id TEXT`, `projects.branch TEXT`. `store.Project{ParentID, Branch}`.

## Wire contract

Runner ids are the config runner ids. An id not in the config is refused with `-32602`
`runner must be the id of one of the gateway's runners`.

| Call | Change |
|---|---|
| `session/new` | optional `params._meta["acpcode/runner"]` (string). Absent or empty: the project's runner. |
| `_acpcode/sessions/create` | optional `params.runner` (string), same meaning, passed to its `session/new`. |
| `_acpcode/projects/createWorktree` (new) | params `{projectId, runner?}`. Makes a git worktree of the project and registers it as a child project. Result: the project object (below). Refused with `-32602` when the project is not a git repository with a commit, is itself a worktree project, or the folder cannot be made. The caller then sends `session/new` with `cwd` = the child's path. |
| `_acpcode/projects/list` | each project gains optional `parentId` and `branch` (omitted when empty). Worktree projects are listed like any project. |
| `_acpcode/sessions/index` | each row gains optional `runner` (the session's recorded runner, else its project's runner; omitted when none). |
| `_acpcode/projects/remove`-style cleanup | deleting a worktree project removes the worktree (`git worktree remove`) and its branch only when it has no commits not merged into the parent branch; otherwise it keeps the branch and says so. Only if a remove call already exists; otherwise worktree removal is a separate, later item. |

Worktree project object: `{id, name, path, defaultMode, runner, autoApprove, parentId, branch}`.
Path: the parent's path + `-<runner>-<8 hex>` (a sibling folder, inside the same project root). Branch: `acpcode/<runner>/<8 hex>`, from the parent's current HEAD.
The child's `runner` is the chosen runner (default: the parent's). Its name: `<parent name> (<runner name>)`.

## Gateway model

- An agent is keyed by (project id, runner id). The key for the project's own runner is the project id, so every existing `s.agents[pid]` lookup still finds the default agent.
  Any other runner uses `pid + "@" + runner`. `Server.agent(pid)` keeps its meaning; add `Server.agentFor(pid, runner)` and `Server.agentsOf(pid)`.
- Routing: `session/new` takes the runner from `_meta["acpcode/runner"]`; an existing session routes by `Store.SessionRunner`, falling back to the project's runner.
- The runner interface keeps `start(p store.Project, home string)`. The supervisor passes a copy of the project with `Runner` set to the agent's runner, so the runner side needs no new parameter.
- Lock file: per runner (`<home>/.acpcode-<runner>.lock`), so two runners in one project do not collide. Container names (podman, apple): `acpcode-<projectId>` for the project's own runner, `acpcode-<projectId>-<runner>` otherwise. HOME stays per project.
- A session's runner is recorded when its `session/new` succeeds, only when it differs from the project's runner.
- Stop, state, idle stop and Shutdown reach every agent of a project.

## File ownership (no two streams edit the same file, except where noted)

| Stream | Owns |
|---|---|
| 1 config and runner side | `gateway/internal/config/*`, `gateway/internal/server/runner.go`, `runner_apple.go`, `runner_srt.go` (settings: per-runner domains and read paths; lock names), `gateway/config*.example.json`, `gateway/internal/server/secrets*` tests for runners |
| 2 routing | `gateway/internal/server/server.go`, `supervisor.go`, `sessions_create.go`, `projects.go`, `projectstate.go`, `stop.go`, `mcp_servers.go`, `connector_tools.go`, new `agents.go` |
| 3 worktree | new `gateway/internal/server/worktree.go` (+ test), `snapshot.go`, `git_push.go`, `gitexec.go`, `runner_srt.go` only in a new function `worktreeAccess` called from `settings` (one added call, no other edits), `scope.go` for the new method name, `projects.go` is NOT edited: the stream registers its method through a one-line case in `handleExtension` owned by stream 2, so stream 3 gives stream 2 the function name `serveCreateWorktree` and stream 2 adds the case |
| 4 app | `ACPClient/**`, `ACPCode/**`, `ACPCodeTests/**` |
| 5 docs | `docs/**` except this file, `gateway/README*`, and the Mac setup guide |

## Quality bar

- No secret value in argv, logs, audit lines, error text or test output. Tests use fake values.
- Every new behaviour has a test. Run what your area owns: `go vet ./...` and `go test ./...` in `gateway/` (other streams edit the same package at the same time, so a compile error in a file you do not own is not yours; wait and retry), `xcodebuild test` or `swift test` for the app.
- Keep edits small and targeted. Do not reformat or rewrite files you do not own. Do not run `gofmt -w` on files you do not own.
