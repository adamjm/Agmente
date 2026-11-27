# Mac setup: the gateway with Apple `container`

This guide runs the ACP Code gateway on a Mac with Apple's `container` CLI. Bob runs in one container per project. The runner is `runner.kind: "apple"` (D-079, D-080, D-081). For the reasons, see `docs/DECISIONS.md` and the 2026-11-07 entries in `docs/RESULTS.md`.

A step marked **verify** was not confirmed in those records. Paths use `~/acpcode/` as an example. The config needs absolute paths, because the gateway does not expand `~` in JSON.

## 1. Prerequisites

- An Apple silicon Mac (the spike ran on macOS 27.0.1, arm64).
- Apple `container` CLI 1.7.0 at `/opt/homebrew/bin/container`.
- Node 22.13 or later (the live check and test scripts) and Go 1.26 or later (building the gateway), per `gateway/package.json` and `gateway/go.mod`.
- Podman, only if you build the image on this Mac (step 3). Not needed if you receive the image archive from elsewhere.

Check the versions:

```bash
/opt/homebrew/bin/container --version
```

```bash
node --version
```

```bash
go version
```

```bash
podman --version
```

The container CLI reports 1.7.0 on the tested Mac (RESULTS 2026-11-07, spike); the flag form is confirmed on this Mac (2026-11-07).

## 2. Start the container service and kernel

Start the Apple container service:

```bash
container system start
```

Install the recommended kernel:

```bash
container system kernel set --recommended
```

The first use may download a kernel (the spike used `kata-static-4.3.1-arm64`, from the kata-containers GitHub release). This step needs network access. The owner approved that download on the tested Mac (RESULTS 2026-11-07, spike).

## 3. Build or obtain the image

The gateway expects the image `acpcode-bob:2.0.9`, stored under the **full** name `localhost/acpcode-bob:2.0.9`.

Why the full name: Apple `container` treats a short name as a Docker Hub name (`docker.io`), and a short name then fails with a 401 (the 401 detail is **verify**; the docker.io behaviour is in D-080). Put the full name in `runner.image`.

The image is built from `deploy/bob-project.Containerfile`, which is marked "verify". The spike used an image built with Podman (the build command was confirmed on this Mac, 2026-11-07):

```bash
podman build -t acpcode-bob:2.0.9 -f deploy/bob-project.Containerfile deploy
```

Apple `container` needs the OCI archive format. Export the image from Podman as an OCI archive (RESULTS 2026-11-07, spike). The `-o` flag is from `podman save --help`:

```bash
podman save --format oci-archive -o ~/acpcode/acpcode-bob-2.0.9.oci.tar localhost/acpcode-bob:2.0.9
```

Load the archive into Apple `container`. The `--input` flag is from `container image load --help`; the spike used this subcommand (RESULTS 2026-11-07, spike):

```bash
container image load --input ~/acpcode/acpcode-bob-2.0.9.oci.tar
```

Check that the image is listed under the full name. This command was confirmed on this Mac (2026-11-07):

```bash
container image list
```

Remove the archive once it is loaded (the spike removed its scratch files; the command was confirmed on this Mac, 2026-11-07):

```bash
rm ~/acpcode/acpcode-bob-2.0.9.oci.tar
```

The first start of a fresh image takes about 15 s (init image download). Later starts take about 1 to 1.3 s.

## 4. Find the DNS resolver

Apple's default resolver for containers (192.168.64.1, the vmnet default) did not answer from inside a container on the tested Mac. Use the Mac's own IPv4 resolver instead (D-081).

List the resolvers:

```bash
scutil --dns
```

Take the first IPv4 nameserver. This prints the first match, using the same pattern as `macResolver()` in `gateway/scripts/live-bob.mjs`:

```bash
scutil --dns | grep -E 'nameserver\[[0-9]+\] : [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1
```

Put that address in `runner.dns` (step 5). Do not copy a value from this guide or from the example file: the example holds a placeholder, and the address depends on the network (D-081).

A public resolver such as `1.1.1.1` also works, but it receives every container lookup in clear text. The owner chose not to use it as the default (D-081).

## 5. Create the folders and the config

Both folders must exist before the gateway starts. The gateway exits when it cannot open the database in `stateDir` (D-024). The gateway creates each project's home folder under `stateDir/homes/` with mode 0700 (D-024). It does not create the project root or `stateDir` itself.

```bash
mkdir -p ~/acpcode/projects ~/acpcode/state
```

Copy the example config out of the repo, then edit the copy (`~/acpcode/config.json`):

```bash
cp gateway/config.mac.example.json ~/acpcode/config.json
```

Set these values:

- `tokens`: build the gateway first (step 7), then run the token command. It prints the token once, and a `config entry` line with `id`, `identity` and `sha256`. Put that entry's values into `tokens`, replacing the placeholder hash. Copy the token into the app, and do not keep it in a file. The gateway stores only the hash.

  ```bash
  gateway/bin/acpcode-gateway new-token <device-id> <identity>
  ```
- `projects.roots`: an absolute project root, for example `/Users/<you>/acpcode/projects`.
- `stateDir`: an absolute path, for example `/Users/<you>/acpcode/state`. It must not be `/`.
- `runner.container`: `/opt/homebrew/bin/container`.
- `runner.image`: `localhost/acpcode-bob:2.0.9` (the full name, step 3).
- `runner.dns`: the address from step 4. Replace the placeholder in the example file.
- `files.host`: the placeholder `files.example.com`. Set it for your deployment (step 11).

Leave `runner.kind` as `"apple"`. The Apple runner passes the first element of `agent.command` to `--entrypoint`, so `bob` must stay first. `containerUid` and `containerGid` default to 10001; change them only if the image's user changes.

## 6. Environment: BOB_API_KEY

`BOB_API_KEY` must come from the environment or from a secrets file outside the repo. Never put it in the config file. The gateway passes it to Bob by name only (FR-32), using `agent.envPassthrough`.

Either export it in your shell (replace the placeholder with your own key; do not write the real key into a file in the repo):

```bash
export BOB_API_KEY=<your-bob-api-key>
```

or load it from a secrets file outside the repo, with `NAME=value` lines:

```bash
set -a; . ~/acpcode/secrets.env; set +a
```

The live check reads the key from the environment and never prints it.

## 7. Build and dry-run

Build the gateway from the repo root:

```bash
(cd gateway && go build -trimpath -o bin/acpcode-gateway ./cmd/acpcode-gateway)
```

Validate your config without starting anything:

```bash
gateway/bin/acpcode-gateway --config ~/acpcode/config.json --dry-run
```

Expected output ends with:

```
Config OK (dry run).
```

If the dry run fails, fix the reported problem and run it again before starting the gateway.

## 8. Run the gateway and the live check

Start the gateway in the foreground:

```bash
gateway/bin/acpcode-gateway --config ~/acpcode/config.json
```

Run the live check for the apple runner. It starts its own gateway on a free port, uses a scratch project under `~/.acpcode-live/`, needs `BOB_API_KEY` (step 6), and uses the Mac's resolver unless you pass `--dns`:

```bash
node gateway/scripts/live-bob.mjs --runner apple
```

Expected last line:

```
SUMMARY apple: 24/24 passed
```

The run exits 0. The 24 checks cover turns, reopen, resubscribe, approvals, git status, the turn diff, the idle stop and reload (D-081, RESULTS 2026-11-07).

## 9. MCP servers for the agent

- **Loopback is not reachable from a container.** A container cannot reach the Mac's `127.0.0.1` (RESULTS 2026-11-07, Apple container check). An HTTP MCP server for Bob running in a container must listen on the Mac's LAN address, or on a host name that the container resolves. The LAN address was tested. A host name was not tested (verify).
- **Gateway URL rule.** The gateway accepts an MCP URL only as `https` to any host, or as `http` to a loopback host (`gateway/internal/server/mcp_guard.go`, D-019). An `http` URL on the LAN is refused, so a LAN server must use `https`. How the certificate reaches the agent is not tested here (verify).
- A loopback `http` URL passes the gateway's rule, but the container cannot connect to it, so it is not a working setup for a container-run agent.

## 10. Known limits

- **No keep-id.** Apple `container` has no user-namespace mapping, so the container runs as `-u 10001:10001` by default. The 0700 folders stay 0700, and files written by the container appear on the host as the owner's user (RESULTS 2026-11-07, spike; D-079). Change the user with `containerUid` and `containerGid`.
- **Memory.** Each running Bob container adds about 800 MB of host memory (829 MiB measured for one). The total grows linearly with running projects: about 6205 MiB of new memory with 8 at once (RESULTS 2026-11-07, step 3 and concurrency entry).
- **Cold load.** About 2.4 s median for one project. About 9.2 s median with 8 at once.
- **NFR-15 is not met at concurrency** (target: 3 s p95 cold load).
- **Main memory lever:** `limits.idleSeconds` (1800 in the example). A stop comes 1 to 1.25 idle times after the last activity (D-032, D-078).
- The apple runner is opt-in. The owner has not decided whether it becomes the Mac default (D-080).

## 11. Troubleshooting

**The container service is not running.** Start it (step 2). The status command was confirmed on this Mac (2026-11-07):

```bash
container system start
```

```bash
container system status
```

**The kernel is missing.** Install the recommended one (needs network):

```bash
container system kernel set --recommended
```

**Image not found.** Check that the image is listed under the full name, and that `runner.image` is `localhost/acpcode-bob:2.0.9` (step 3). The list command was confirmed on this Mac (2026-11-07):

```bash
container image list
```

**DNS does not resolve inside the containers.** Bob's own log then shows `fetch failed` (D-080). Set `runner.dns` to the first IPv4 nameserver from `scutil --dns` on this Mac (step 4). The gateway passes it to the container as `--dns`. Then run the live check again (step 8).

**A stale container after a crash.** A second start with a name in use fails with `container with id ... already exists` and exit 1. List the container names:

```bash
container list --quiet
```

Delete only a container whose name starts with `acpcode-`, with the command the gateway itself uses (`runner_apple.go`):

```bash
container delete --force acpcode-<projectId>
```

Do not use `container inspect` or `container list --format json`. Both print environment values (D-079).

## 12. Not covered

- The public connector's deployment (Caddy on public port 8443 as your own user, the LaunchAgent, the public address). It is covered in section 13.
- The phone listener's Caddy site (`deploy/Caddyfile`, :8443 to 127.0.0.1:8788) and the systemd unit (`deploy/acpcode-gateway.service`). This guide does not cover them.
- Push delivery and APNs. See `docs/PUSH-TESTING.md`.

## 13. Public connector (Claude remote access)

The connector lets a Claude client reach the gateway from the internet (D-095, D-098, D-100). It is a second listener, separate from the phone's mutual-TLS listener. It is off by default (`connector.enabled` is `false` in `gateway/config.mac.example.json`). The gateway serves it on `127.0.0.1:8789` (`connector.port`). Caddy is the only public path to it. It listens on public TCP **8443**, the same port as the phone's site, and tells the two apart by host name. Caddy forwards seven paths only: the two `/.well-known/oauth-protected-resource` metadata paths (with and without the `/mcp` suffix), `/.well-known/oauth-authorization-server`, `/register`, `/authorize`, `/token` and `/mcp`. Everything else is 404.

The connector site asks for no client certificate, because the Claude client cannot present one. Access depends on the grant that the phone approves at pairing, and on the gateway's limits. A grant can reach sessions that have `alwaysAllow` set, so a connector prompt can run tools there without a phone prompt. The owner accepted this trade-off. Each such turn is audited with `source: "claude"`, and the audit line never holds the prompt text.

### Why port 8443 and no root (D-100)

Caddy runs as your own user, from a LaunchAgent, not as root from a LaunchDaemon. Ports below 1024 need root on macOS, so the public site cannot use 443 or 80 without a root process or a `pf` redirect. Port 8443 needs neither. Two changes follow:

- **Certificate.** Let's Encrypt's HTTP-01 and TLS-ALPN-01 challenges need public port 80 or 443, which this setup does not forward. The connector certificate therefore uses the **DNS-01** challenge through a DNS provider's API. It needs no inbound port.
- **No port 80 listener.** `deploy/Caddyfile` sets `auto_https disable_redirects`, so Caddy does not try to bind port 80 for HTTP-to-HTTPS redirects. No client uses that redirect.

The publicOrigin includes the port, `https://<host>:8443`. The gateway uses it as the MCP resource identifier, so Claude must send the same origin. Whether Claude accepts a non-443 port is **not verified**. It is probe 7.0. If Claude rejects it, the port choice comes back to the owner.

### What the owner must do

1. **DNS.** Choose a public host name for the connector, for example `connector.your-domain.example`. It must not be the phone's name. Add an A record (and an AAAA record, if you use IPv6) that points to the Mac's public address.
2. **Router.** Forward public TCP **8443** to the Mac's port 8443 on its LAN address. Do not forward 443 or 80 for this. Never forward the gateway ports (8787, 8788, 8789). The phone's site uses the same forward, so do not remove it while the phone needs it.
3. **DNS provider token.** Caddy needs an API token for the DNS provider, to add and remove the `_acme-challenge` TXT record for the host name. Create it in the provider's dashboard. If the provider allows it, scope the token to that one zone and to DNS edits only. Add it to the owner's secrets file, not to the repo, and not to chat:

   ```
   CADDY_DNS_API_TOKEN=<the token>
   ```

   The file is `/Users/you/acpcode/secrets.env` (the gateway's secrets file, which the gateway's LaunchAgent also sources). Set its mode to 600: `chmod 600 /Users/you/acpcode/secrets.env`. The gateway itself sees only the variables in `agent.envPassthrough`.
4. **Build Caddy with the DNS module.** The Homebrew build of Caddy does not include a DNS provider. Build a Caddy that does, with `xcaddy` (install it from `github.com/caddyserver/xcaddy`). Choose the module for your provider from the `caddy-dns` organisation (`github.com/caddy-dns`):

   ```bash
   xcaddy build --with github.com/caddy-dns/<provider> --output ~/acpcode/caddy/bin/caddy
   ```

   `<provider>` is a placeholder: use the module path from that provider's `caddy-dns` README. The `tls` directive names the provider the same way, for example `dns cloudflare {env.CLOUDFLARE_API_TOKEN}` (Caddy's `tls` directive page). In `deploy/Caddyfile.connector`, replace the placeholder `PROVIDER` with that provider name. The token stays in the environment variable `CADDY_DNS_API_TOKEN`.
5. **Caddy files.** Copy the Caddy configs into the Caddy folder. The main file already imports the connector site, outside any site block:

   ```bash
   cp deploy/Caddyfile ~/acpcode/caddy/Caddyfile
   cp deploy/Caddyfile.connector ~/acpcode/caddy/Caddyfile.connector
   ```

   The phone site's client CA is still read from `/etc/caddy/acpcode-client-ca.pem`. Caddy runs as you, so that file must be readable by your user (`ls -l /etc/caddy/acpcode-client-ca.pem`). A private copy of the same CA, under `~/acpcode/caddy/`, works if the directory is not readable. Then change the `trust_pool` path in the copy. Changing it is a change to the phone's site, so re-check the phone's mutual TLS afterwards.
6. **Caddy environment.** Set `CONNECTOR_HOST` to the host name from step 1, in `deploy/launchd/dev.acpcode.caddy.plist`. The Caddy LaunchAgent sets it, and the Caddyfile reads it as `{$CONNECTOR_HOST}`. Without it, Caddy will not load the config.
7. **Caddy LaunchAgent.** Install the template as a user agent (its comments give the commands). Stop any manually started Caddy first, or port 8443 is already taken. The agent runs as you, not as root.
8. **Gateway config.** In your copy of the config, set `connector.enabled` to `true` and `connector.publicOrigin` to `https://<the host name>:8443`. JSON has no comments, so this note lives here. Keep `allowedOrigins` empty until the connector probe shows which origin the Claude client sends.
9. **Start.** Run the gateway dry run first (step 7 below). Then restart the Caddy agent (or `caddy reload`), and restart the gateway. Restarting the gateway stops running project agents, so do it when no session is running.
10. **Probe.** Add the connector in the Claude app and record the results in `docs/RESULTS.md`. Include whether Claude accepts the port 8443 origin (probe 7.0). Mark the directives in `deploy/Caddyfile.connector` as verified there.

Validate the Caddy config before you reload it, with the same environment values as the agent. Use the Caddy built in step 4, since the stock build cannot load the DNS directive:

```bash
CONNECTOR_HOST=connector.your-domain.example ~/acpcode/caddy/bin/caddy validate --config ~/acpcode/caddy/Caddyfile --adapter caddyfile
```

Load the token from the secrets file rather than typing it: `set -a; . ~/acpcode/secrets.env; set +a`, then run the command with `CONNECTOR_HOST` set. Expected: exit 0 and `Valid configuration`.

### How to verify

Run these from a network outside your home LAN (for example a phone on cellular). A request from inside the LAN may fail because of the router's NAT, which is a test artefact, not a fault. Each check prints the HTTP status code. A handshake failure prints `000`.

The connector answers without a client certificate, on its metadata path. Expected `200`, once the gateway is running with the connector enabled. A `502` most likely means the gateway's connector listener is not running:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://connector.your-domain.example:8443/.well-known/oauth-protected-resource
```

The path-suffixed metadata form is forwarded by Caddy. Expected `200` once the gateway serves it (owner decision 44). Until then the gateway answers `404`, and Caddy's forward still works:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://connector.your-domain.example:8443/.well-known/oauth-protected-resource/mcp
```

Any path outside the seven listed above must give 404. This one is outside the list:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://connector.your-domain.example:8443/admin
```

Expected: `404`.

The connector's `/mcp` path needs a grant token. With none sent, the gateway answers `401`:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://connector.your-domain.example:8443/mcp -d '{}'
```

Expected: `401`, from the gateway. A `404` here means the Caddy site is not loaded.

The phone's site must still require a client certificate. Run this without a certificate. Expected: `000`, because the TLS handshake fails before any request. Any HTTP status, such as `200` or `421`, means the phone's site accepted a connection without a certificate. Stop and investigate:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://agent.your-domain.example:8443/
```

Replace `agent.your-domain.example` with the phone site's host name (the example in `deploy/Caddyfile`).

The gateway's startup output names the connector listener on `127.0.0.1:8789`. Check the config with `gateway/bin/acpcode-gateway --config ~/acpcode/config.json --dry-run` before each start.

### How to turn it off

1. **Revoke the grants** from the phone's connector screen.
2. **Disable the listener.** Set `connector.enabled` to `false` in the config, then restart the gateway (when no session is running). No connector listener starts.
3. **Remove the public route.** Delete the `import` line from the Caddy config (or the `Caddyfile.connector` import) and reload Caddy: `caddy validate`, then `caddy reload`. The connector host name then has no site on 8443, and the phone's site keeps running.
4. **Optional.** Remove the connector's DNS record. Remove the router's 8443 forward only if the phone does not use it. That forward also serves the phone's site.
5. **Optional.** Revoke the DNS provider token in the provider's dashboard, and delete `CADDY_DNS_API_TOKEN` from the secrets file.

## 14. The lean runner: `srt` instead of containers (D-122)

`runner.kind: "srt"` runs Bob, git and the push commands as processes under Anthropic sandbox-runtime. There is no image, no VM and no DNS step, so sections 2 to 4 do not apply. The boundary is weaker than a container: same user id, same kernel, a Seatbelt profile (D-122). Choose it knowingly.

1. **Node 22.21 or later.** Older Node ignores the sandbox's proxy variables and the agent would have no network.
2. **Install `srt` outside every project root and the state folder.** The gateway refuses a path inside them (the agent could replace it):

   ```bash
   npm install -g @anthropic-ai/sandbox-runtime
   ```

   Tested with 0.0.83. `which srt` gives the absolute path for `runner.srt`.
3. **Use a git that is not the Xcode shim.** `/usr/bin/git` costs about 3 s a call in the sandbox. The gateway uses `/usr/local/bin/git` if it exists, else the git under `xcode-select -p`. Install the Xcode Command Line Tools or a git in `/usr/local/bin`.
4. **Config.** Copy `gateway/config.mac-srt.example.json`. The runner block is:

   ```json
   "runner": {
     "kind": "srt",
     "srt": "/opt/homebrew/bin/srt",
     "allowedDomains": ["api.us-east.bob.ibm.com", "bob.ibm.com", "iam.cloud.ibm.com"],
     "allowRead": ["/opt/homebrew", "/usr/local"]
   }
   ```

   - `allowedDomains` is the only network the agent has. Bob needed the three hosts above on 2026-11-22. A prompt that works in a container but fails here with `fetch failed` needs another host: run the agent once under `srt --debug` and read the denied hosts (the debug log also prints the command line, including secrets, so delete it).
   - `allowRead` is how the agent finds Bob, node and your toolchains. The agent cannot read your home, the other projects or the state folder.
   - `weakerNetworkIsolation` (default off; srt calls it `enableWeakerNetworkIsolation`) lets Go tools verify certificates through the macOS trust service. It opens a Mach service, so leave it off unless `go` or `gh` fails on TLS.
   - `allowLocalBinding` (default off) lets the **agent only** connect to any port on `127.0.0.1` and bind local ports, for example an http MCP server you run on the Mac (the gateway accepts `http` MCP URLs to loopback only). It also makes every service on the Mac's loopback reachable by the agent, so turn it on only for that need. Git and push never get it. Verified with real srt on 2026-11-22: off, a loopback connection fails; on, it works.
   - **MCP servers under srt** (real Bob, 2026-11-22, 25 of 25 checks):
     - A stdio server under `/opt/homebrew` works; one in your home is unreadable and Bob reports it unavailable (no hang). It is denied home, `~/.ssh`, writes outside the project and `.git/config`.
     - **Any http or https MCP entry makes Bob open a local listener**, so without `allowLocalBinding` `session/new` fails with `listen EPERM 127.0.0.1`. Turn the key on for any list that has an http or https entry.
     - Write loopback MCP URLs as `http://localhost:PORT`, not `127.0.0.1`: Bob sends even loopback MCP requests through srt's proxy, which refuses unlisted hosts. With `allowLocalBinding` on, the gateway adds `localhost` to the agent's `allowedDomains`.
     - An https MCP server works when its host is in `allowedDomains` and is unusable when it is not.
     - **Limit:** a stdio MCP server that needs the network cannot reach it, even when the host is allowed. Bob starts MCP children with a clean environment (no proxy variables, no `$VAR` expansion in an entry's env), and the proxy URL and token are per run. Use an http or https MCP server for network tools, or the Podman or Apple runner for a stdio server that needs the network.
   - `agent.command` should be an absolute path to `bob`, and `envPassthrough` should not include `HOME` (the gateway sets the project home).
5. **Live check:**

   ```bash
   set -a; . ./.env; set +a; node gateway/scripts/live-bob.mjs --runner srt --srt "$(which srt)" --domains api.us-east.bob.ibm.com,bob.ibm.com,iam.cloud.ibm.com
   ```

   24 of 24 passed on 2026-11-22. The Go live tests need `ACPCODE_TEST_SRT=$(which srt)`.

### Tighter or weaker: what you can change (D-122)

The sandbox has a fixed core and a few dials in the `runner` block. The core is not configurable: a setting cannot weaken it.

**Fixed (cannot be loosened by config):**
- The agent cannot read your home folder, the project roots (other projects), the state folder, `/tmp` or `/var/folders`. Its own project folder, its own home (`<stateDir>/homes/<id>`) and the `allowRead` paths are allowed back. **Reads elsewhere are open:** srt allows reading everything it is not told to deny, so system folders (`/etc`, `/Library`, `/Applications`, `/usr`, `/opt` outside `allowRead`) and any other user's files that the gateway user can read stay readable. There is no setting to deny more. If another folder outside the home holds secrets (for example `/Volumes/backup` or `/opt/secrets`), the agent can read it; move it into the home or use the Podman or Apple runner.
- The agent can write only its project folder and its own home. `TMPDIR` is `<home>/tmp`.
- `.git/hooks` is never writable, and `.git/config` is writable only by the gateway's own git commands, never by the agent.
- Git has no network. A push command reaches only the git hosts, only while it runs.
- The settings file lives in the state folder, which the agent cannot read or write, and `runner.srt` must lie outside the project roots and the state folder.
- Same user id and kernel as the gateway. This is the weaker boundary D-122 accepted; no setting turns it into a container.

**The dials, from most to least effect:**

| Setting | Default | Tighter | Weaker | What the weaker value opens |
|---|---|---|---|---|
| `runner.allowedDomains` | the three Bob hosts in the example (required, 1 to 64) | List only Bob's hosts. Use exact names, not `*.` patterns, and no `:port` you do not need | Add registries (`registry.npmjs.org`, `pypi.org`, `proxy.golang.org`, `crates.io`), then `*.example.com` | Everything the agent runs, and any package install script, can send data to those hosts. A wildcard host that lets users publish content (a storage or paste service) is an exfiltration path |
| `runner.allowRead` | `/opt/homebrew`, `/usr/local` (optional key) | Empty, when `bob`, `node` and your tools are outside your home | Add toolchain paths under the home, for example `~/.cargo/bin` and `~/.rustup`, or a `bob` installed under the home (nvm, `~/.local`) | The agent can read everything inside each path, including every file and key kept there. Never list the home, `~/.ssh`, `~/.aws`, `~/.config`, a credentials file or a project root. `/` and globs are refused |
| `runner.weakerNetworkIsolation` | `false` | Keep `false` | `true` | srt opens the macOS trust service (`com.apple.trustd.agent`) so Go and `gh` can verify certificates. srt's README names it as a possible data-exfiltration route. Needed only for Go and other tools that use the system trust store |
| `runner.allowLocalBinding` | `false` | Keep `false` | `true` | The agent (not git or push) can connect to every port on `127.0.0.1` and open its own listener. Needed for any http or https MCP entry (Bob opens a local listener). `localhost` is added to the agent's allowed hosts |
| `git.hosts` (top level, not in `runner`) | `["github.com"]` | Name only the host you push to | Add a second host | The hosts a remote URL and a stored git credential may name, and the only network a push gets |
| `limits.idleSeconds` | 1800 | A lower value stops an unused agent sooner, so its process and anything it started do not stay running | A higher value keeps it longer | An idle agent keeps its memory (about 0.4 to 1.9 GB) |
| `agent.envPassthrough` | `PATH`, `LANG`, `BOB_API_KEY` | List only what Bob needs | Adding a name hands that variable's value to the agent and to everything it runs | A secret in the gateway's environment becomes readable by the agent. Do not add cloud or git tokens |

**Three presets.** Copy the `runner` block, set `srt` to `which srt`, and restart the gateway. The gateway refuses a bad value at start and prints the key.

*Tightest.* Bob only, no toolchains, no loopback. Use it for reviewing or explaining code, not for running builds:

```json
"runner": {
  "kind": "srt",
  "srt": "/opt/homebrew/bin/srt",
  "allowedDomains": ["api.us-east.bob.ibm.com", "bob.ibm.com", "iam.cloud.ibm.com"],
  "allowRead": ["/opt/homebrew"]
}
```

The agent can edit files and run programs from `/opt/homebrew` and the system, and cannot install anything: `npm install`, `pip` and `cargo` fail with a network error.

*Default (the example config).* Same hosts, plus `/usr/local`. Builds that need no downloads work. Add registries one at a time as a task needs them.

*Working builds.* For Node, Python, Go and Rust projects. It is the preset the toolchain table in this section was measured with, plus the Go and Rust lines:

```json
"runner": {
  "kind": "srt",
  "srt": "/opt/homebrew/bin/srt",
  "allowedDomains": [
    "api.us-east.bob.ibm.com", "bob.ibm.com", "iam.cloud.ibm.com",
    "registry.npmjs.org", "pypi.org", "files.pythonhosted.org",
    "proxy.golang.org", "sum.golang.org", "storage.googleapis.com",
    "crates.io", "index.crates.io", "static.crates.io"
  ],
  "allowRead": ["/opt/homebrew", "/usr/local", "/Users/you/.cargo/bin", "/Users/you/.rustup"],
  "weakerNetworkIsolation": true
}
```

Drop the lines of the languages you do not use: each registry you remove is one fewer place data can go, and `weakerNetworkIsolation` can go if you do not use Go. `go` needs `proxy.golang.org`, `sum.golang.org` and, for some modules, `storage.googleapis.com`. A project that pulls from GitHub (`go get github.com/...` with a direct fetch, a git dependency) needs `github.com`, which also lets the agent reach any public repository, so add it only when you must.

**How to choose.** Start with the tightest preset. Run the task; if it fails with `fetch failed`, `ENOTFOUND`, `Operation not permitted` or an `x509` error, add exactly what the message points to:

| Symptom in the turn | Cause | Change |
|---|---|---|
| `fetch failed` or `ENOTFOUND` for a host | host not in `allowedDomains` | add that host |
| `x509: OSStatus -26276` (Go) or `failed to copy trust settings` | no access to the macOS trust service | `weakerNetworkIsolation: true`, or avoid Go in the sandbox |
| `Operation not permitted` reading a path under your home | path not in `allowRead` | add the narrowest path that holds the tool |
| `listen EPERM 127.0.0.1` at `session/new` | an http or https MCP entry | `allowLocalBinding: true` |
| `git clone` or `git init` fails with `.git/hooks` | by design | the gateway creates and pushes the repo; do not loosen it |
| a command stops at about 260 s | Bob's own limit, not the sandbox | run it in smaller steps |

Every change takes effect at the next agent start. Stop or wait for the idle stop of a running project, then send a prompt; an already running agent keeps the settings it started with.

**What a change does not give you.** None of these dials reaches the container-level boundary (a separate user, a separate filesystem). If a project must not be able to affect the Mac at all, use the Podman or Apple runner. Loosening `allowedDomains` or `allowRead` is the common way a sandbox stops protecting you, so loosen one entry at a time and record why.

**Toolchains under srt** (agent sandbox, `allowRead` = `/opt/homebrew`, `/usr/local`; measured 2026-11-22 by `go test ./internal/server -run LiveSRTToolchains` with `ACPCODE_TEST_SRT` and `ACPCODE_TEST_SRT_TOOLCHAINS=1`):

| Toolchain | Task | Result | Time | What it needs |
|---|---|---|---|---|
| Go | `go mod download`, `build`, `test` | Fails on TLS by default (`x509: OSStatus -26276`) | 0.7 s | `weakerNetworkIsolation: true`, then it works (8 s); `proxy.golang.org`, `sum.golang.org` |
| Rust | `cargo build`, `cargo test` (crate `itoa`) | Works (12 s) | 12 s | `allowRead` of `~/.cargo/bin` and `~/.rustup` (both are under the denied home); `CARGO_HOME` under the project home; `crates.io`, `index.crates.io`, `static.crates.io` |
| Python | `python3 -m venv`, `pip install pytest`, `pytest` | Works | 10 s | `pypi.org`, `files.pythonhosted.org`; `/usr/bin/python3` is an Xcode shim (slow) |
| Node | `npm install`, `npm ci`, `npm test` | Works | 2.3 s | `registry.npmjs.org` |
| make, clang | `make` with `clang` | Works, but prints `couldn't create cache file ... xcrun_db` and takes about 5 s | 5 s | Xcode shim cost; install the command line tools or use a Homebrew compiler |
| git over ssh | `ssh -T git@github.com` | Fails at once (`Could not resolve hostname`) | 0.5 s | Nothing works: no agent socket, no key, no ssh network. Use https |
| `git clone` / `git init` in the agent | | Denied (`cannot copy ... .git/hooks/...: Operation not permitted`) | 3 s | By design (D-122): `.git/hooks` and `.git/config` are not writable by the agent. The gateway creates the repo |
| Malicious install script (`npm postinstall`) | read `~/.ssh`, list home, read sibling project, read state folder, write `.git/hooks`, write home, reach example.com | All denied | 3.4 s | |

The rows list what a user must add. Go needs `weakerNetworkIsolation`, which opens a Mach service to the agent. The Xcode shim (`/usr/bin/python3`, `clang`, `make`) costs about 3 s per call, so prefer Homebrew tools.

**Memory and start time** (8 projects at once, 3 rounds, `bench-concurrent.mjs --runner srt`): 3.3 GB RSS in total (2.7 GB footprint) against 6.2 GB for the Apple runner; load median 6.7 s (Apple 9.2 s), still above the 3 s NFR-15 target because the sandbox adds about 3 s to Bob's start. A busy Bob grows to about 1.9 GB, so plan 2 GB per working project. Eight srt processes started in the same instant lost one agent in most runs (`Shell 'bash' not found in PATH`, srt's own 1 s lookup); the gateway spaces launches 250 ms apart.

**Known limits.** Linux, a push to a real remote and a soak longer than 15 minutes with two projects were not tested. A shell command in a turn is stopped by Bob itself after about 260 s, with or without srt. With two busy projects a git call took up to 4.8 s against the 5 s limit. A tool that needs a host outside `allowedDomains` fails and Bob reports a network error. A stdio MCP server cannot use the network (see the MCP bullets above).

## 15. Claude Code runner (D-125, D-126; in progress)

This section adds Claude Code as a second runner, next to Bob, under the `srt` runner of section 14. The model calls go to the model gateway at `https://model-gateway.example.com`. The gateway injects the environment from the runner's secrets file, so you do not need a wrapper script, `~/.claude/settings.json` or any VS Code step. Contract: `docs/design/per-session-runner.md`. A step marked **verify** has not been run through the ACP Code gateway yet.

1. **Prerequisites.** Section 14 is done: Node 22.21 or later and `srt` installed. If `srt` is not installed yet:

   ```bash
   npm install -g @anthropic-ai/sandbox-runtime
   ```

   Check Node:

   ```bash
   node --version
   ```

2. **Install the ACP adapter.** The `claude` CLI is not an ACP agent by itself, so the gateway runs an adapter that starts it:

   ```bash
   npm install -g @agentclientprotocol/claude-agent-acp
   ```

   The spike used version 0.113.0 (RESULTS 2026-11-27). Find the paths:

   ```bash
   which claude-agent-acp claude
   ```

   The `claude` CLI must already be installed, with the official installer or with Homebrew. A Homebrew install is under `/opt/homebrew`, which the runner can read (see `allowRead` below). **Verify:** an install under your home folder (the official installer puts it in `~/.local/bin`) is unreadable to the agent unless you add that folder to the runner's `allowRead`. Add only the narrowest folder that holds `claude`.

3. **Get the API key.** Get the coding-agent key for Claude Code from your model gateway's key settings. It starts with `sk-` but not `sk-ant-`.

4. **Create the secrets file.** Put it outside the repo and every project root. The folder is the same one the config uses:

   ```bash
   mkdir -p ~/acpcode
   touch ~/acpcode/claude.env
   chmod 600 ~/acpcode/claude.env
   ```

   Edit `~/acpcode/claude.env` with `NAME=value` lines. Replace each placeholder with your own value. Do not paste the real key into a file in the repo, a chat or a log:

   ```
   ANTHROPIC_AUTH_TOKEN=<your-claude-code-key>
   ANTHROPIC_BASE_URL=https://model-gateway.example.com
   ANTHROPIC_MODEL=claude-haiku-5-5
   CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
   CLAUDE_CODE_EXECUTABLE=/opt/homebrew/bin/claude
   ```

   The gateway refuses a secrets file that is not an absolute path, is not a regular file, or can be read by group or others. It never lets the file set `HOME` or `PATH`.

5. **Add the runner.** In `~/acpcode/config.json`, the `runners` map holds one entry per agent. If the config still has the single `agent` block, move it into `runners` first (D-116): the two forms cannot be mixed. Add this entry, with your own paths, beside Bob's entry. The shared `runner.kind` is `"srt"`:

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

   - `secretsFile` is the file from step 4. Only the names in `envPassthrough` reach the agent.
   - `allowedDomains` is this runner's only network. Bob's hosts stay in Bob's entry (section 14) or in the shared `runner.allowedDomains`. A runner with no list of its own takes the shared one, and under `srt` every runner must end up with at least one domain.
   - `allowRead` is this runner's read paths. Set it for the folder that holds `claude-agent-acp`, `node` and `claude`.
   - Set `defaultRunner` to the runner a new project should start with. The phone picks a runner for each session, and the project's runner is the default for that choice (D-125).

6. **Check the config and start.** Run the dry run from section 7, then start the gateway:

   ```bash
   gateway/bin/acpcode-gateway --config ~/acpcode/config.json --dry-run
   ```

   The gateway refuses to start when the secrets file is missing or too open, or when an `srt` runner has no domain.

7. **Confirm it works.** In the app, start a session in a project and choose the Claude Code runner. Send a short prompt. The first turn starts `claude-agent-acp` under `srt`, which takes a few seconds. Run through the live gateway on 2026-11-27 (RESULTS): a prompt to the Claude runner returned an answer. If the turn fails:

   | Symptom | Cause | Change |
   | --- | --- | --- |
   | `403` that names the model | The model name is not one the model gateway serves. `claude-haiku-5-53` is refused. | Set `ANTHROPIC_MODEL=claude-haiku-5-5` in `claude.env`, restart the project's agent |
   | `fetch failed` or `ENOTFOUND` | The host is not in the runner's `allowedDomains` | Check `model-gateway.example.com` is listed in the Claude entry |
   | `401` or an auth error | The key is wrong, expired or in the wrong variable | Get a new key (step 3). Put it in `ANTHROPIC_AUTH_TOKEN` |
   | `Operation not permitted` reading `claude` or `node` | The folder is not in `allowRead` | Add the narrowest folder that holds the tool |

   A changed setting applies at the next agent start. Stop the project's agent, or wait for the idle stop, then send a prompt.

**The model.** `claude-haiku-5-5` is the verified name. In the 2026-11-27 spike the model gateway also answered Sonnet (served as `claude-sonnet-5-5`) and `claude-advantage-assist`, and refused `claude-sonnet-4-5`, `claude-haiku-4-5` and `claude-haiku-5-53` with 403. Change `ANTHROPIC_MODEL` only to a name you have tested the same way.

**The token goes in `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`.** The key is a token for the model gateway, not an Anthropic key. The verified setup (D-126) uses `ANTHROPIC_AUTH_TOKEN` only, and the gateway's own example never sets `ANTHROPIC_API_KEY`.

**Two runners in one project.** The same project can have a Bob session and a Claude Code session running at once, each with its own agent. They then share one project folder, and two agents may edit the same file. When you start the second session, tick **Separate worktree**. The gateway makes a sibling folder on its own branch (`acpcode/<runner>/<8 hex>`) and the session works there. Worktrees are available under the `srt` runner only. The gateway never merges the branch: merge it yourself, for example with `git merge` in the original project folder, when you are content with the work.
