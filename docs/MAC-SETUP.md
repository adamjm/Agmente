# Mac setup: the gateway with Apple `container`

This guide runs the Agmente gateway on a Mac with Apple's `container` CLI. Bob runs in one container per project. The runner is `runner.kind: "apple"` (D-079, D-080, D-081). For the reasons, see `docs/DECISIONS.md` and the 2026-11-07 entries in `docs/RESULTS.md`.

A step marked **verify** was not confirmed in those records. Paths use `~/agmente/` as an example. The config needs absolute paths, because the gateway does not expand `~` in JSON.

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

The gateway expects the image `agmente-bob:2.0.9`, stored under the **full** name `localhost/agmente-bob:2.0.9`.

Why the full name: Apple `container` treats a short name as a Docker Hub name (`docker.io`), and a short name then fails with a 401 (the 401 detail is **verify**; the docker.io behaviour is in D-080). Put the full name in `runner.image`.

The image is built from `deploy/bob-project.Containerfile`, which is marked "verify". The spike used an image built with Podman (the build command was confirmed on this Mac, 2026-11-07):

```bash
podman build -t agmente-bob:2.0.9 -f deploy/bob-project.Containerfile deploy
```

Apple `container` needs the OCI archive format. Export the image from Podman as an OCI archive (RESULTS 2026-11-07, spike). The `-o` flag is from `podman save --help`:

```bash
podman save --format oci-archive -o ~/agmente/agmente-bob-2.0.9.oci.tar localhost/agmente-bob:2.0.9
```

Load the archive into Apple `container`. The `--input` flag is from `container image load --help`; the spike used this subcommand (RESULTS 2026-11-07, spike):

```bash
container image load --input ~/agmente/agmente-bob-2.0.9.oci.tar
```

Check that the image is listed under the full name. This command was confirmed on this Mac (2026-11-07):

```bash
container image list
```

Remove the archive once it is loaded (the spike removed its scratch files; the command was confirmed on this Mac, 2026-11-07):

```bash
rm ~/agmente/agmente-bob-2.0.9.oci.tar
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
mkdir -p ~/agmente/projects ~/agmente/state
```

Copy the example config out of the repo, then edit the copy (`~/agmente/config.json`):

```bash
cp gateway/config.mac.example.json ~/agmente/config.json
```

Set these values:

- `tokens`: build the gateway first (step 7), then run the token command. It prints the token once, and a `config entry` line with `id`, `identity` and `sha256`. Put that entry's values into `tokens`, replacing the placeholder hash. Copy the token into the app, and do not keep it in a file. The gateway stores only the hash.

  ```bash
  gateway/bin/agmente-gateway new-token <device-id> <identity>
  ```
- `projects.roots`: an absolute project root, for example `/Users/<you>/agmente/projects`.
- `stateDir`: an absolute path, for example `/Users/<you>/agmente/state`. It must not be `/`.
- `runner.container`: `/opt/homebrew/bin/container`.
- `runner.image`: `localhost/agmente-bob:2.0.9` (the full name, step 3).
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
set -a; . ~/agmente/secrets.env; set +a
```

The live check reads the key from the environment and never prints it.

## 7. Build and dry-run

Build the gateway from the repo root:

```bash
(cd gateway && go build -trimpath -o bin/agmente-gateway ./cmd/agmente-gateway)
```

Validate your config without starting anything:

```bash
gateway/bin/agmente-gateway --config ~/agmente/config.json --dry-run
```

Expected output ends with:

```
Config OK (dry run).
```

If the dry run fails, fix the reported problem and run it again before starting the gateway.

## 8. Run the gateway and the live check

Start the gateway in the foreground:

```bash
gateway/bin/agmente-gateway --config ~/agmente/config.json
```

Run the live check for the apple runner. It starts its own gateway on a free port, uses a scratch project under `~/.agmente-live/`, needs `BOB_API_KEY` (step 6), and uses the Mac's resolver unless you pass `--dns`:

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

**Image not found.** Check that the image is listed under the full name, and that `runner.image` is `localhost/agmente-bob:2.0.9` (step 3). The list command was confirmed on this Mac (2026-11-07):

```bash
container image list
```

**DNS does not resolve inside the containers.** Bob's own log then shows `fetch failed` (D-080). Set `runner.dns` to the first IPv4 nameserver from `scutil --dns` on this Mac (step 4). The gateway passes it to the container as `--dns`. Then run the live check again (step 8).

**A stale container after a crash.** A second start with a name in use fails with `container with id ... already exists` and exit 1. List the container names:

```bash
container list --quiet
```

Delete only a container whose name starts with `agmente-`, with the command the gateway itself uses (`runner_apple.go`):

```bash
container delete --force agmente-<projectId>
```

Do not use `container inspect` or `container list --format json`. Both print environment values (D-079).

## 12. Not covered

- The public connector's deployment (Caddy on 443, the launchd services, the public address). It is covered in section 13.
- The phone listener's Caddy site (`deploy/Caddyfile`, :8443 to 127.0.0.1:8788) and the systemd unit (`deploy/agmente-gateway.service`). This guide does not cover them.
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

   The file is `/Users/you/agmente/secrets.env` (the gateway's secrets file, which the gateway's LaunchAgent also sources). Set its mode to 600: `chmod 600 /Users/you/agmente/secrets.env`. The gateway itself sees only the variables in `agent.envPassthrough`.
4. **Build Caddy with the DNS module.** The Homebrew build of Caddy does not include a DNS provider. Build a Caddy that does, with `xcaddy` (install it from `github.com/caddyserver/xcaddy`). Choose the module for your provider from the `caddy-dns` organisation (`github.com/caddy-dns`):

   ```bash
   xcaddy build --with github.com/caddy-dns/<provider> --output ~/agmente/caddy/bin/caddy
   ```

   `<provider>` is a placeholder: use the module path from that provider's `caddy-dns` README. The `tls` directive names the provider the same way, for example `dns cloudflare {env.CLOUDFLARE_API_TOKEN}` (Caddy's `tls` directive page). In `deploy/Caddyfile.connector`, replace the placeholder `PROVIDER` with that provider name. The token stays in the environment variable `CADDY_DNS_API_TOKEN`.
5. **Caddy files.** Copy the Caddy configs into the Caddy folder. The main file already imports the connector site, outside any site block:

   ```bash
   cp deploy/Caddyfile ~/agmente/caddy/Caddyfile
   cp deploy/Caddyfile.connector ~/agmente/caddy/Caddyfile.connector
   ```

   The phone site's client CA is still read from `/etc/caddy/agmente-client-ca.pem`. Caddy runs as you, so that file must be readable by your user (`ls -l /etc/caddy/agmente-client-ca.pem`). A private copy of the same CA, under `~/agmente/caddy/`, works if the directory is not readable. Then change the `trust_pool` path in the copy. Changing it is a change to the phone's site, so re-check the phone's mutual TLS afterwards.
6. **Caddy environment.** Set `CONNECTOR_HOST` to the host name from step 1, in `deploy/launchd/dev.agmente.caddy.plist`. The Caddy LaunchAgent sets it, and the Caddyfile reads it as `{$CONNECTOR_HOST}`. Without it, Caddy will not load the config.
7. **Caddy LaunchAgent.** Install the template as a user agent (its comments give the commands). Stop any manually started Caddy first, or port 8443 is already taken. The agent runs as you, not as root.
8. **Gateway config.** In your copy of the config, set `connector.enabled` to `true` and `connector.publicOrigin` to `https://<the host name>:8443`. JSON has no comments, so this note lives here. Keep `allowedOrigins` empty until the connector probe shows which origin the Claude client sends.
9. **Start.** Run the gateway dry run first (step 7 below). Then restart the Caddy agent (or `caddy reload`), and restart the gateway. Restarting the gateway stops running project agents, so do it when no session is running.
10. **Probe.** Add the connector in the Claude app and record the results in `docs/RESULTS.md`. Include whether Claude accepts the port 8443 origin (probe 7.0). Mark the directives in `deploy/Caddyfile.connector` as verified there.

Validate the Caddy config before you reload it, with the same environment values as the agent. Use the Caddy built in step 4, since the stock build cannot load the DNS directive:

```bash
CONNECTOR_HOST=connector.your-domain.example ~/agmente/caddy/bin/caddy validate --config ~/agmente/caddy/Caddyfile --adapter caddyfile
```

Load the token from the secrets file rather than typing it: `set -a; . ~/agmente/secrets.env; set +a`, then run the command with `CONNECTOR_HOST` set. Expected: exit 0 and `Valid configuration`.

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

The gateway's startup output names the connector listener on `127.0.0.1:8789`. Check the config with `gateway/bin/agmente-gateway --config ~/agmente/config.json --dry-run` before each start.

### How to turn it off

1. **Revoke the grants** from the phone's connector screen.
2. **Disable the listener.** Set `connector.enabled` to `false` in the config, then restart the gateway (when no session is running). No connector listener starts.
3. **Remove the public route.** Delete the `import` line from the Caddy config (or the `Caddyfile.connector` import) and reload Caddy: `caddy validate`, then `caddy reload`. The connector host name then has no site on 8443, and the phone's site keeps running.
4. **Optional.** Remove the connector's DNS record. Remove the router's 8443 forward only if the phone does not use it. That forward also serves the phone's site.
5. **Optional.** Revoke the DNS provider token in the provider's dashboard, and delete `CADDY_DNS_API_TOKEN` from the secrets file.
