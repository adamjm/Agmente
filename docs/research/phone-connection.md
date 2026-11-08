# Research and plan: the Claude iPhone app calls ACP Code (project + session)

Date: 2026-11-07. Research and plan only. No code was edited, nothing was installed. The token, passphrase and .p12 files in `scratchpad/phone/` were not opened.

Marks: **[V]** verified in a source I read this session. **[S]** stated by a secondary source only. **[U]** unverified, an inference or a gap. Decision IDs (D-n), FR, T and RESULTS refer to the repo docs.

---

## 0. Summary

Goal: the Claude app on the iPhone sends content (from the chat prompt) to a chosen ACP Code project and session, and gets the response back.

**Recommendation: Option A, "gateway-direct". Claude calls a remote MCP connector served by the Mac gateway. The gateway injects the prompt into the named session itself and returns the result as the tool result. The phone is not in the call path.** The phone keeps two roles: it shows the session (it is a subscriber, as today) and it answers approvals (D-009).

Why the phone is not a broker: the session does not live on the phone. Bob runs on the Mac in a per-project container and keeps running when the phone is gone (D-025, ARCHITECTURE 2.3). The phone is a viewer. Routing the call through the phone adds a failure mode (a backgrounded app has no usable socket) and creates a path where remote text makes the app send a prompt with no tap, which D-041 rules out for links.

The one real blocker is reachability and auth, not iOS:

1. Claude's connector calls come from Anthropic's cloud, not the phone **[V]**. So the Mac needs a public HTTPS name with a publicly trusted certificate, and the existing mutual-TLS host cannot serve it.
2. A personal Claude account probably cannot use static request headers (beta, limited set of organisations) **[V]**. The connector will need OAuth (DCR or CIMD + PKCE) **[V]**, so the gateway needs a small OAuth authorization server.

Everything else (scoped tokens, prompt injection into the log, rate limits, audit) is gateway work on top of existing machinery: the event log, the approval queue, the push path.

---

## 1. Evidence

### 1a. What the Claude iOS app can call into

| Mechanism | Can the Claude app call it? | Can it return a response to Claude? |
| --- | --- | --- |
| **Custom / remote MCP connector** | Yes, if the connector is added to the account. Mobile apps use web-added connectors **[V]**. | Yes: the tool result. Size cap about 150,000 characters, 240 s per tool call on claude.ai and Desktop **[V]**. |
| **App Intents / Shortcuts / Siri** (Claude's "Ask Claude" intent) | This is the other direction. Shortcuts or Siri call Claude. Claude does not call Shortcuts. | Not applicable. |
| **URL schemes / universal links** (`claude://`, `https://claude.ai/code`) | These open the Claude app. They are inbound to Claude only. | No. The page documents no callback and no x-callback-url **[V]**. |
| **x-callback-url** | Only Apple's Shortcuts app supports it (`shortcuts://x-callback-url/run-shortcut` with `x-success`, `x-cancel`, `x-error`, and a `result` parameter) **[V]**. | Yes, but only for Shortcuts, and Claude does not use it. |

Facts, with sources:

- **Connectors run from Anthropic's cloud, not the phone, and that includes the mobile apps.** "Claude connects to your remote MCP server from Anthropic's cloud infrastructure, rather than from your local device." Servers on private networks need Anthropic's IPs allowlisted **[V]** (support article 11175166).
- **Can the iPhone app add a connector?** Official wording: web connectors are available to all users on the mobile apps; "installing connectors on mobile is currently in beta"; Claude Desktop and web remain the primary path for custom connectors; services connected on Claude or Desktop appear on mobile at the next login **[V]** (support article 11176164). Whether the iOS UI has an "Add custom connector" button today **[U]**. Plan: add the connector on claude.ai in a browser once, then use it on the phone.
- **Plans.** Custom connectors work on Free, Pro, Max, Ultra, Team and Enterprise. Free is limited to one custom connector **[V]**. This matters for design decision 3 below (one connector per session is not viable on Free).
- **Tool permissions.** Under Customize > Connectors each tool can be "Always allow", "Needs approval" or "Blocked" **[V]**. Whether individual (non-Team) users can set these and how the prompt looks on mobile **[U]**. This is a second approval layer inside Claude, separate from the phone approval in ACP Code.
- **Transports and auth.** Streamable HTTP recommended; legacy HTTP+SSE still supported but being deprecated **[V]**. Auth types: OAuth 2.0 with DCR or CIMD (default), Anthropic-held client credentials, none, and `static_headers` (a fixed token, "beta, for a limited set of organizations", entered by an organization Owner). Owners without access do not see the Request headers section **[V]** (claude.com/docs/connectors/building/authentication, add-unlisted). So for a personal account, expect OAuth.
- **OAuth specifics Claude enforces [V]:** a `401` with `WWW-Authenticate: Bearer resource_metadata=...` is required to start sign-in (Claude ignores it on a 200); PKCE S256 on every authorization request; redirect URI `https://claude.ai/api/mcp/auth_callback` (may later be a claude.com host); discovery, registration and token endpoints get 10 s, refresh 30 s; `/token` must accept `application/x-www-form-urlencoded`; `resource` in protected-resource metadata must equal the connector URL exactly; the authorization server host must also be reachable from Anthropic's egress range; refresh tokens must be rotated for public clients; the MCP spec forbids tokens in the query string.
- **Anthropic egress ranges.** Outbound for MCP tool calls: `160.79.104.0/21` and `153.61.208.0/20` **[V]** (platform.claude.com/docs/en/api/ip-addresses). Note: several guides, and the auth page, only mention the first range. The IP page lists both. "These addresses will not change without notice" **[V]**.
- **Apple "Ask Claude" intent.** Claude for iOS exposes an "Ask Claude" App Intent usable from Siri and Shortcuts; chaining several is supported **[V]** (support article 10263469). That the action returns the reply as a Shortcuts output variable: one third-party source says text in, text out **[S]**; Anthropic's page does not say **[V that it is not stated]**. Verify on a device before building on it.
- **Claude's own links.** `claude://code`, `claude://code/{session-id}`, `claude://code/new?q=...` (also `prompt=`; `mode`, `repo`, `branch`); universal links `https://claude.ai/code`. They need Claude Code access on the account. No callback **[V]** (support article 14898120). A regular-chat prefill scheme on iPhone is not documented there **[U]**.
- **Nothing found** showing Claude on iPhone can trigger Shortcuts or drive other apps. The only device integration found is the Apple Health connector **[V by absence, medium confidence]**.
- **Apple side, Siri.** Reports say App Intents is the Siri integration point in iOS 27 and that system-wide MCP in Siri is disputed or unconfirmed **[S, conflicting]**. Not relevant to Claude calling out, and not relied on.

**Which can return a response to the caller?**

- Remote MCP connector: yes (tool result).
- Shortcuts x-callback: yes, but Claude cannot use it.
- "Ask Claude" intent inside a Shortcut: probably (Claude replies into the Shortcut) **[S]**. This lets a Shortcut call ACP Code with Claude's answer, which is "Claude to ACP Code" only if the user starts the Shortcut.
- `claude://` and `acpcode://` links: no return path.

So the only mechanism by which **Claude's model decides to call something with a prompt-derived argument, and receives the answer, is the remote MCP connector.**

### 1b. Reachability

Confirmed: a connector call cannot reach `adams-mac-studio.local` or the LAN.

- Calls originate in Anthropic's cloud **[V]**. `.local` is an mDNS name that resolves only on the local link **[U: general networking knowledge, not looked up]**. The only tested path so far is phone to `wss://adams-mac-studio.local:8443` on the same LAN (RESULTS 2026-11-07, "Phone to Mac gateway over mutual TLS").
- The existing edge cannot serve Claude even if the name were public:
  - `deploy/Caddyfile` uses `client_auth { mode require_and_verify; trust_pool file ... }`. Claude has no client certificate, so the handshake fails.
  - The test setup uses `tls internal` (RESULTS 1396). Anthropic would not trust a private CA **[U: standard TLS verification, inferred]**. A public ACME certificate is needed.
  - The gateway rejects any upgrade carrying an `Origin` header and requires a bearer token for the WebSocket (FR-1, FR-3). There is no plain-HTTP API: `ServeHTTP` serves `/healthz`, the files host, and WebSocket upgrades only (`gateway/internal/server/server.go`).
  - `deploy/` and `docs/MAC-SETUP.md` section 12 do not cover the public deployment at all. PLAN 1.11 (Caddy + service on a host) is in the backlog. So a public hostname for the phone, away from home, does not exist yet either. The connector and the away-from-home phone need the same exposure work.
  - There is no launchd unit for the Mac gateway (the only service file is a systemd example) **[V]**.

**Safe ways to expose the Mac gateway for the connector**

All of them share the same rules: a **separate hostname** from the mutual-TLS ACP host (as the files host already is, D-061), a **separate loopback listener** on the gateway, only the paths Claude needs (`/mcp`, `/.well-known/oauth-*`, `/register`, `/authorize`, `/token`), no WebSocket upgrade, OAuth on everything.

| Option | How | Pros | Cons / unknowns |
| --- | --- | --- | --- |
| **E1. Caddy on a public name, port 443 forwarded to the Mac** | New site block `mcp.<domain>` with a public ACME cert. Caddy `remote_ip` allowlist of `160.79.104.0/21` and `153.61.208.0/20` on `/mcp`, `/token`, `/register`, `/.well-known/*`. `/authorize` open to any IP (the user's browser visits it) and protected by the phone-approval step. | Strongest control. TLS ends on your Mac. IP allowlist cuts scanners. Same Caddy you already run. | Needs inbound 443 on the home router, a public IPv4 (not CGNAT) **[U]**, dynamic DNS, exposes the home IP. `remote_ip` matcher name and behaviour: verify against Caddy docs **[U]**. |
| **E2. Cloudflare Tunnel (`cloudflared`)** | Outbound-only tunnel from the Mac to a public hostname; no inbound port. Repo `setup.md` Option B already documents `cloudflared` for the app. Add a WAF custom rule to allow only Anthropic ranges on machine paths. | No inbound port, no home IP exposure, free tier **[U]**. | Cloudflare terminates TLS and sees plaintext (prompts and results). Source-IP rules at Cloudflare and how Caddy/gateway sees the client IP (`CF-Connecting-IP`, `trustProxy` is written for Caddy's X-Forwarded-For) need work **[U]**. A remotely-managed tunnel token is a standing secret **[V: anyone with the token can run the tunnel]**. |
| **E3. Tailscale Funnel** | `tailscale funnel` publishes a `*.ts.net` name on port 443, 8443 or 10000 **[V]**. | Simple. No router change. | Only those ports, only the tailnet's domain, "non-configurable bandwidth limits" **[V]**. Source IPs seen at the Mac and any IP allowlist **[U]**. The Mac App Store Tailscale variant caveat is in conflicting docs **[V that docs conflict]**. D-018 already says Tailscale is not a supported *phone* path; this would be a separate, connector-only path. |
| **E4. Anthropic MCP tunnels** | Official tunnel from your network to Anthropic. | No public endpoint. | **Not available.** Research preview, Enterprise plan, by request **[V]**; claude.ai tunnels cannot serve the API and vice versa. Rejected. |
| **E5. A small VPS reverse proxy + WireGuard back to the Mac** | Public edge on a VPS, private link home. | Hides home IP; fixed IP. | Extra host to run and patch. Overkill for one user. Rejected unless E1 or E2 fail. |

Recommendation: **E1 if the router and ISP allow it, else E2.** Decide with the owner (decision 4). Whichever is chosen, keep the mTLS host (`agent.<domain>`) exactly as it is.

Caddy scoping detail to check at deploy time: a client that connects to the public name but sends `Host: agent.<domain>`. Caddy's behaviour on an SNI/Host mismatch is recorded for IP connections only (HTTP 421, `deploy/Caddyfile` comment) **[V for IP, U for SNI mismatch]**. Avoid the question: give the connector its own gateway listener port (decision in 7.1), so the ACP socket is not on that listener at all.

### 1c. The phone as a listener

Not viable. Evidence:

- Apple DTS (Quinn): listening sockets and `NWListener` should be **closed when the app becomes eligible for suspension**; if a listener stays open while suspended, the kernel still accepts connections but the app never services them, so clients connect and hang **[V]** (developer.apple.com/forums/thread/757385).
- Apple DTS: iOS has **no general-purpose way to keep naked TCP connections alive while suspended**; the legacy VoIP category is deprecated and restricted; the supported route is APNs **[V]** (forums thread 91625).
- `beginBackgroundTask` buys on the order of 30 seconds, not a listener lifetime **[S]**; the "about 30 s" figure is an artifact, DTS says not to rely on it **[V]** (forums thread 808351). Apple's own background-time doc page could not be read here (JavaScript-rendered) **[U]**.
- Reachability: the phone is on mobile or home Wi-Fi, so there is no inbound path from Anthropic's cloud to it without a relay. CGNAT on cellular **[U: general knowledge]**.
- Local Network privacy (iOS 14+): needs `NSLocalNetworkUsageDescription`; ACP Code's `Info.plist` already has the key and `NSAllowsLocalNetworking`. It governs LAN access, not internet inbound, and does not make background listening possible. TN3179 content was not readable here; details **[U]**; forum snippets confirm TN3179 exists and covers app identity, extensions sharing the container app's state, and per-user state **[V]**.
- It would also defeat the point of the fork: sessions that keep running with the phone away (FR-16).

### 1d. Brokered design, and why Option A is simpler

You asked for: Claude calls the gateway, the gateway passes the request to the phone over its WebSocket, the phone runs it through the normal session path, streams events, and the response returns. I checked each step against the code.

What already exists (SPEC 6.2, `gateway/internal/server/`):

- Gateway extension methods, all over the authenticated WebSocket only: `_acpcode/projects/list|create|addDenyPaths|addWatchSkip`; `_acpcode/sessions/index|read|subscribe`; `_acpcode/approvals/pending|answer`; `_acpcode/git/status|diff|log|turnDiff` and the `git/changed` notification; `_acpcode/push/register|unregister`; `_acpcode/files/url`; `_acpcode/mcp/list|set`; `_acpcode/skills/list|put|read|delete`; `_acpcode/elicitation/answer` (D-090). ACP passes through: `session/new`, `session/prompt`, `session/cancel`, and the rest. Extension list in `server.go`: `projects, sessions, approvals, git, push, files`.
- The pieces a prompt needs: `projectAgent.forward` writes `session/prompt` to the agent after logging `turn_started` and taking a start snapshot (`supervisor.go` around line 735). `logTurnEnded` logs `turn_ended` and fires the push. Subscribers get live `_acpcode/event` messages; replay reads the SQLite log (D-027, D-028). Approvals queue first-answer-wins with a reject-on-timeout rule (D-031).

What is missing for Claude:

1. **Any HTTP/MCP surface.** Only WebSocket upgrades and `/healthz`.
2. **A client with no WebSocket.** `forward` takes a `*client` that owns a `websocket.Conn` (`client.go`: `c.ws.Write`, `c.ws.Close`). A virtual in-process client is needed. `c.ws` is touched in only five places (`client.go`, `guard_panic.go`, `server.go`), so the refactor is small.
3. **Scoped tokens.** `config.Token` is `{ID, Identity, SHA256}`. A token has the whole identity: every project and session. No scope, expiry, revoke or per-token limits.
4. **A way to wait for a turn's result without a socket.** Subscribe is socket-bound. Need "send, then wait up to N s, else return a `turnId` to poll".
5. **Source attribution.** `turn_started` has no `source`. The app cannot show "sent from Claude".
6. **Per-token rate and size limits.** Today: failed-auth per address, connections per identity, message size (16 MiB). Nothing per caller or per session.
7. **OAuth authorization server** (see 1a). None exists.
8. **App UI** for grants, a "via Claude" badge, and approving a new connector grant.

Phone-brokered variant, evaluated:

- It needs a **new gateway-to-phone command channel**, and the app must act on it: take remote text and call `session/prompt` with no tap. That is the reverse of D-041 ("a link only navigates; never sends a prompt").
- It **fails whenever the phone is backgrounded or the socket is dropped**, which is the normal case. The app has no background WebSocket **[V by 1c]**. A silent push could wake it for about 30 s at most **[S]**, and not at all without the unavailable APNs key (3.11 BLOCKED; PUSH-TESTING).
- It gains nothing: Bob is on the Mac; the phone only relays text back to the Mac.

So the recommended broker is the **gateway itself**, with the phone as viewer and approver. "The phone runs it through the normal session path" is preserved in the only sense that matters: the prompt goes through the same `forward`/log/snapshot/approval path as a phone prompt, and the phone sees it live.

### 1e. Security

**Scope the token to one project and one session.**
- A connector grant is `{grantId, projectId, sessionId, expires, scopes: [prompt]}`, stored in SQLite (new table), not in the config file, because grants are created at runtime by the owner. Token values are stored as SHA-256 hashes only (NFR-14); OAuth access tokens are short-lived (for example 1 hour) with rotating refresh tokens **[V that Claude requires rotation for public clients]**.
- The OAuth `resource` (RFC 8707) is the connector URL; the token's audience is that resource; the gateway refuses tokens issued for anything else. The MCP tools take `session` as an argument and the gateway checks it against the grant. The token cannot call any `_acpcode/*` method, cannot create sessions, cannot list other projects, cannot read git or files, and cannot answer approvals. The MCP endpoint is a different code path from the WebSocket handler, so it has no access to `handleExtension`.
- One connector with a grant allowlist (default: one session), not one connector per session. Free accounts get one custom connector **[V]**.

**Approvals stay on the phone (D-009).**
- A Claude-originated turn uses the normal approval queue. The MCP tool result reports `status: "awaiting_approval"` and never an answer. No MCP tool exists that answers an approval. The timeout still selects a reject option (D-031). The connector token has no path to `_acpcode/approvals/answer`.
- D-089 (owner override: `alwaysAllow` for MCP tools) removes the prompt for those tools. For a Claude-reachable session that is a real hole, because the person who writes the prompt is no longer only the owner. Recommend: the gateway refuses connector prompts to a session whose project/home `mcp.json` or session list has any `alwaysAllow` (check at call time; the gateway already reads those files, D-085). D-089 itself says to reopen it if another writer appears; a connector is another writer **[V from D-089 "Revisit"]**.
- Push: approval pushes (D-054) are suppressed for a device that is subscribed to that session. Real delivery is BLOCKED on the Apple `.p8` key (3.11). Without it the owner must open the app to see an approval, and the MCP call just reports `awaiting_approval`.

**Prompt injection from content Claude passes in.**
- The risk is indirect: Claude reads a web page, email or file, and passes hostile text to Bob, which has a shell. Anthropic's own docs warn about prompt injection on custom connectors **[V]**.
- Controls, in order of strength: (1) every shell/tool action still needs the phone's approval, with the exact command shown (D-040); (2) no `alwaysAllow` in reachable sessions; (3) point the grant at a dedicated low-privilege project, not a real repo; (4) the gateway wraps the text in a fixed provenance frame ("relayed by the Claude connector, untrusted") and strips control characters, with a size cap (suggest 8 KiB). The frame reduces risk and does not remove it; treat it as a label, not a defence. (5) Per-grant rate limit and a one-tap revoke.
- The **return path is also an attack surface**: Bob's reply goes into Claude's context, where hostile repo text could steer Claude's other connectors. Return only the final assistant text, capped (suggest 20,000 chars, far below Claude's 150,000), no tool output, no diffs, no file contents. Owner decision 6.
- Secrets: the existing deny-list (`denylist.go`, D-035, D-050) protects diffs and file URLs. It does not scan Bob's chat reply. A reply could quote a secret Bob read. Another reason to keep the target project secret-free **[U: no scan exists, verified by reading the code paths listed in the docs, not by test]**.

**Rate limits.** Add: max one running turn per session (the gateway already tracks `running`); N prompts per hour per grant (suggest 20); max prompt bytes; max wait; failed-auth limiter reuse (`failureLimiter`, NFR-5) on the OAuth endpoints; cap on registered OAuth clients (DCR registers a new client per connection and can grow without bound **[V from the auth page]**).

**Audit (FR-9, "never log prompt text").** New events: `mcp_grant_created|revoked`, `mcp_auth_ok|rejected`, `mcp_prompt` (grant id, project, session, byte length, SHA-256 prefix of the text, never the text), `mcp_result` (turn id, status, bytes returned). The prompt text is in the event log inside `turn_started`, as for phone prompts; add `source: "claude"` there.

**Other.** The MCP endpoint is on its own listener and host; it must reject WebSocket upgrades and requests with an `Origin` that is not expected (MCP spec: validate `Origin` against DNS rebinding **[V]**). A secret in a URL or query string is never accepted **[V rule]**. Turn it off by default: config key absent = no listener (same pattern as `files`, D-061).

---

## 2. Options

| ID | Option | Verdict |
| --- | --- | --- |
| A | Remote MCP connector served by the Mac gateway; gateway injects the prompt into the session; result returned as tool result | **Recommended** |
| B | Same connector, but the gateway forwards the call to the phone, which sends the prompt | Rejected: fails when the app is backgrounded; needs unattended send-on-receive in the app (conflicts with D-041); no benefit |
| C | Server listening inside the iOS app | Rejected: suspended apps cannot service connections; no inbound path from the internet |
| D | Shortcuts: "Ask Claude" then an ACP Code App Intent ("Send prompt to session") | Not Claude calling out; user-triggered. Cheap on-device add-on (phase 7.7). Needs an App Intent in the app (none today **[V: no App Intents grep hit]**) and Claude's output behaviour verified |
| E | `acpcode://` link with prefilled text that Claude prints | Fallback only. Link must prefill the composer and require a tap (D-041). No return. Whether Claude's iOS chat renders a custom-scheme link as tappable **[U]** |
| F | Anthropic MCP tunnels | Rejected: Enterprise, research preview |
| G | `claude://code/new?q=` from ACP Code to Claude | Opposite direction, needs Claude Code access; opens the composer only. Out of scope |

---

## 3. Build plan

Convention: follows CLAUDE.md. Plan mode and owner approval before each phase; one task at a time; `scripts/check.sh` after each; tests are wire-level against the Go binary with the fake agent; tick only on pass; a FAIL is a valid result. Suggested name: **Phase 7, Claude connector.** Number the D-n entries when the owner approves.

**7.0 Probes with the real Claude app (no gateway code).** Owner-in-loop. Use a throwaway echo MCP server (or the MCP Inspector) behind the chosen exposure option. Record in RESULTS: (a) can the iPhone Claude app add a custom connector, or only use one added on claude.ai; (b) exact headers, source IPs and user-agent Claude sends; (c) the approval prompt on mobile ("Needs approval"); (d) behaviour when a tool call takes longer than the timeout; (e) whether an `https://` + `acpcode://` link in a tool result renders as tappable. Check: five recorded answers. Stop if (a) fails and the owner has no web/desktop path.

**7.1 Scoped grants and the MCP listener (no OAuth yet).** New config `mcp: {host, listenPort, ...}` (absent = off). A second listener on its own loopback port. New SQLite table `grants` (id, project, session, token SHA-256, expires, created, revoked). Dev-time grant creation by CLI: `acpcode-gateway new-grant <project> <session> <ttl>` prints the token once. `/mcp` implements `initialize`, `tools/list` (`send_prompt`, `get_turn`, `cancel_turn`; annotations set), returns `401` + `WWW-Authenticate` with `resource_metadata` for bad/missing tokens, rejects upgrades, rejects wrong `Origin`. Tests (new T-ids): no token = 401 and zero agent spawns; wrong-session argument = JSON-RPC error; token cannot reach any `_acpcode/*` or `session/*`; listener absent when config absent; ACP socket not reachable on this port. Mutations: skip the session check; accept a token for another resource.

**7.2 Prompt injection path (virtual client).** Make `client` independent of `websocket.Conn`; add a `localClient`. `send_prompt {session, text, wait?}` calls the existing `forward` for `session/prompt`; `turn_started` gets `source:"claude"` and a grant id. One running turn per session. Waits up to 200 s (below the 240 s timeout **[V]**); if the turn is not over, returns `{status:"running", turnId}`; `get_turn` returns `running | awaiting_approval | done{text} | error`. Result is the final assistant message text only, capped. Tests with the fake agent: turn runs; a subscribed phone socket receives the same events with `source:"claude"`; the result matches the log; second concurrent prompt refused; text over cap refused; prompt text absent from the audit log (T-13 style). Mutation: return tool output.

**7.3 Approvals and limits.** Result `awaiting_approval` while an approval is open; no MCP path answers it; timeout rejects (reuse T-22/T-23 style tests on a connector-originated turn). Refuse prompts when the session's project has `alwaysAllow` (D-089). Per-grant rate limit; per-grant daily cap; revoke via `new-grant --revoke` and kill-switch config. Audit events from 1e. Check: tests for each refusal, plus a mutation that auto-answers.

**7.4 OAuth authorization server (stdlib only; D-n entry for any dependency).** Endpoints: `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`, `/register` (DCR, capped), `/authorize` (S256 PKCE, `resource` bound), `/token` (code and refresh, form-encoded, rotation), `invalid_grant` errors. Consent initially by one-time pairing code printed by the CLI; phone-approval comes in 7.5. Tests: a scripted client doing the full flow; wrong verifier, wrong resource, reused code, expired token, refresh rotation, 415 on JSON token body, 10 s latency budget. Check against the real Claude client in 7.6, not before.

**7.5 App: grants and "via Claude".** Gateway methods `_acpcode/grants/list|revoke` and a pending-grant approval (mirrors approvals: `_acpcode/grants/pending|answer`, first answer wins, timeout denies, never auto-approves). App: Settings > Claude access (list, revoke, which session), a badge on messages with `source:"claude"`, an inbox row for a new connect request (needs 7.4). Tests in `ACPCodeTests/` with a fake client; no network. App Intent/Shortcut work is not in this phase.

**7.6 Deploy and live check.** Caddy block for the connector host (per chosen option), launchd unit for the Mac gateway (new file under `deploy/`, marked verify), `remote_ip` allowlist of the two Anthropic ranges on machine paths **[V ranges; U Caddy syntax]**. Live: add the connector on claude.ai, use it from the iPhone; send a prompt; see the session update in ACP Code; approve a tool on the phone; see the result in Claude; revoke and confirm the next call fails. Record in RESULTS with date, command, output. BLOCKED items to mark: APNs delivery for approvals (3.11) and anything needing a signed device build.

**7.7 Optional on-device paths.** (i) `acpcode://session/<server>/<session>?draft=<text>`: prefill only, no send (extends D-041; needs a new D-n). (ii) An App Intent "Send to ACP Code session" so a Shortcut can pass Claude's "Ask Claude" output into a session, with a confirmation step. Both are user-triggered and independent of 7.1 to 7.6.

Order rationale: scoped token and listener first (security shape), then the call, then approvals/limits, then OAuth (largest, and only testable end to end with Claude), then app UI, then deploy. Phases 7.1 to 7.3 need no Apple account and no public hostname.

---

## 4. Decisions for the owner

1. **Go with Option A (gateway-direct, phone as viewer and approver)?** Recommend **yes**. Alternative B is worse on every axis checked.
2. **Which exposure?** E1 (Caddy on a public name, port forward) or E2 (Cloudflare Tunnel). Recommend **E1 if your router/ISP allows inbound 443 and you have a public IPv4; otherwise E2.** Needs a domain name. Accept that E2 lets Cloudflare read prompts and replies.
3. **One connector with a per-session allowlist, or one connector per session?** Recommend **one connector, allowlist of one session by default.** Free accounts have one custom connector **[V]**.
4. **Which project/session is reachable?** Recommend **a dedicated, low-privilege project with no secrets and no `alwaysAllow`**, not a real repo.
5. **Grant approval for new connections:** phone approval in the app (7.5), or a pairing code printed on the Mac. Recommend **phone approval, with the pairing code as the first step in 7.4.**
6. **What the tool result may contain:** final assistant text only, capped at 20,000 chars, versus also tool output/diffs. Recommend **final text only.**
7. **D-089 `alwaysAllow`:** keep as is, but refuse connector prompts to any session where it is set. Recommend **yes, refuse.** Or reopen D-089.
8. **Rate limits:** one running turn per session, 20 prompts per hour per grant, 8 KiB per prompt. Recommend **these numbers**, adjustable in config.
9. **MCP listener auth state when the phone is away:** if no device is registered for push (3.11 is BLOCKED), approvals cannot reach a locked phone. Recommend **ship 7.1 to 7.3 anyway; the call reports `awaiting_approval`; mark push BLOCKED.**
10. **Add the optional on-device paths (7.7)?** Recommend **later, after 7.6 works.**
11. **Does the owner accept that the connector must be added on claude.ai (web/desktop), if 7.0(a) shows iOS cannot add one?** Recommend **yes.**

---

## 5. Not verified, to settle in 7.0

- Whether the iPhone Claude app can add a custom connector, and what tool-approval prompts look like for individual users on mobile.
- Whether "Ask Claude" returns the reply as a Shortcuts output variable.
- Whether Claude's iOS chat renders `acpcode://` links as tappable.
- Whether Anthropic's client rejects a private CA (assumed yes).
- Caddy `remote_ip` syntax, and Caddy behaviour on SNI/Host mismatch; how the client IP reaches the gateway behind Cloudflare Tunnel or Funnel.
- Apple's own pages on background time and TN3179 body text (JavaScript-rendered; only forum posts read).
- Whether the gateway's `Origin` rule or `trustProxy` need changes for the MCP listener.
- Bob's handling of a very long reply and how the final assistant text is best assembled from the event log (`update` events are chunked; D-027). Needs a fake-agent test in 7.2.
- Static request headers for a personal account (documented as beta for a limited set of organisations); if available, OAuth could be postponed. 7.0 should check the Add custom connector dialog.

---

## 6. Sources

Claude and Anthropic
- Get started with custom connectors using remote MCP: https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp
- Use connectors to extend Claude's capabilities (mobile beta, tool permissions): https://support.claude.com/en/articles/11176164-use-connectors-to-extend-claude-s-capabilities
- Add a connector that isn't in the directory (steps, auth, request headers): https://claude.com/docs/connectors/custom/add-unlisted.md
- Build an MCP server for Claude (transports, 240 s, 150,000 chars): https://claude.com/docs/connectors/building
- Authentication for connectors (OAuth rules, static headers beta, callback): https://claude.com/docs/connectors/building/authentication.md
- Anthropic IP addresses (outbound ranges): https://platform.claude.com/docs/en/api/ip-addresses.md
- MCP tunnels (Enterprise research preview): https://claude.com/docs/connectors/mcp-tunnels/overview
- Use Claude app intents, shortcuts, and widgets on iOS: https://support.claude.com/en/articles/10263469-use-claude-app-intents-shortcuts-and-widgets-on-ios
- Open the Claude mobile app with a link: https://support.claude.com/en/articles/14898120-open-the-claude-mobile-app-with-a-link
- Third-party (secondary): https://mer.vin/2026/08/local-vs-remote-mcp-claude-custom-connectors/ ; https://dev.to/zhizhiarv/how-to-set-up-remote-mcp-on-claude-iosandroid-mobile-apps-3ce3

Apple
- Shortcuts x-callback-url: https://support.apple.com/guide/shortcuts/apdcd7f20a6f/
- Listeners and suspension (DTS): https://developer.apple.com/forums/thread/757385
- No general way to keep TCP alive while suspended (DTS): https://developer.apple.com/forums/thread/91625
- Background task window (DTS, VoIP context): https://developer.apple.com/forums/thread/808351
- TN3179 Understanding local network privacy (page body not readable here): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- App Intents return values and `openAppWhenRun` (WWDC22 10032, WWDC25 244/275, forums thread 804015): https://developer.apple.com/videos/play/wwdc2022/10032/
- iOS 27 / Siri / MCP reports (conflicting, not relied on): https://www.stork.ai/blog/wwdc-2026-graded-what-apple-shipped-ios-27 ; https://chatforest.com/builders-log/ios-27-apple-intelligence-framework-decision-guide-wwdc-2026/

Exposure
- Tailscale Funnel: https://tailscale.com/docs/features/tailscale-funnel
- Cloudflare Tunnel (remote tunnel API, tunnel tokens): https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/ ; https://developers.cloudflare.com/tunnel/advanced/tunnel-tokens

MCP spec
- Streamable HTTP transport (Origin validation): https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

Repo (read)
- `ACPCode/CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/PLAN.md`, `docs/DECISIONS.md` (D-003, D-009, D-018, D-020, D-025, D-027, D-028, D-031, D-035, D-040, D-041, D-050, D-052 to D-055, D-061, D-085, D-089, D-090), `docs/MAC-SETUP.md`, `docs/RESULTS.md` (2026-11-07 phone entries), `deploy/Caddyfile`, `deploy/acpcode-gateway.service`, `gateway/config.mac.example.json`, `gateway/internal/server/{server,client,auth,supervisor,subscribe}.go`, `gateway/internal/config/config.go`, `ACPCode/Fork/DeepLink.swift`, `ACPCode/Info.plist`, plan `/Users/adammakarucha/.claude/plans/pure-fluttering-hippo.md` (3.20).
