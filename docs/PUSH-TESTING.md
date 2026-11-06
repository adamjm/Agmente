# Testing push notifications end to end

Status 2026-11-07: the app can ask for permission, get a device token and give it to the gateway, and the gateway stores it (D-052). **Nothing sends a push yet.** Delivery (PLAN 3.11) needs an Apple account, a key and a real iPhone. This page lists what to do, in order, and how to tell each step worked.

## Part A. Checks that need no Apple account (done; rerun any time)

| Step | Command | Pass |
| --- | --- | --- |
| Gateway wire tests | `scripts/check.sh` | "All checks passed"; `test/push.test.mjs` is in the 142 |
| Payload builder (T-24) | `(cd gateway && go test ./internal/push/...)` | ok |
| App tests | `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test` | TEST SUCCEEDED |
| Register by hand | start a gateway, connect with a token, send `{"jsonrpc":"2.0","id":1,"method":"_agmente/push/register","params":{"deviceToken":"<64 hex>","environment":"sandbox"}}` | result `{}`; `sqlite3 <stateDir>/gateway.db 'select identity,device,environment from push_tokens'` shows one row |

## Part B. What you need from Apple (owner)

1. **Apple Developer Program membership** (paid). Needed for the Push capability and the key.
2. **App ID with Push Notifications.** In Certificates, Identifiers & Profiles, open the App ID for the app's bundle id and enable Push Notifications. The project's bundle id is in the Xcode target; the placeholder `com.example.*` ids in the repo will not work. Change the bundle id to one you own first.
3. **APNs auth key (`.p8`).** Keys, then +, tick Apple Push Notifications service (APNs). Download the `.p8` once. Note the **Key ID** (10 characters) and your **Team ID** (10 characters, top right of the membership page). One key works for both sandbox and production.
4. **Store the key on the gateway host only**, outside the repo and the config file (NFR-14: no secrets in config). Mode 0600, for example `/etc/agmente/AuthKey_<KEYID>.p8`. Never commit it, paste it into chat or put it in the app.
5. **A real iPhone** signed in to iCloud, with a USB cable or wireless debugging. The simulator on Apple silicon can receive pushes dragged in as `.apns` files but cannot get a real device token, so it cannot test this path.

## Part C. Make the app able to receive pushes (needs the Mac, Xcode, the account)

1. In Xcode, select the Agmente target, Signing & Capabilities, choose your team, and set the unique bundle id from B2.
2. Add the **Push Notifications** capability. This creates the `aps-environment` entitlement (`development` for Debug, `production` for archive builds).
3. Build and run on the iPhone (Debug build, so `environment` is `sandbox`).
4. Settings, Notifications, tap **Allow notifications**, accept the system prompt. The row should read "Allowed, token held". If it shows "Registration failed" with "no valid aps-environment", step 2 did not take effect (clean build folder, re-run).

## Part D. Check the token reaches the gateway (needs only C)

1. Run the gateway (loopback plus Caddy, or `ws://` to your Mac on the same network with "Local only" on, D-019). Connect the app to it.
2. On the gateway host: `sqlite3 <stateDir>/gateway.db 'select identity,device,environment,length(token),updated from push_tokens'`.
3. **Pass:** one row for the token's identity and device, `length(token)` 64, environment `sandbox`.
4. **Check the environment guess:** a Debug build run from Xcode should say `sandbox`. If you install a Release or TestFlight build it must say `production`. If it does not match, delivery fails with `BadDeviceToken`; fix `PushGatewaySync.environment`.
5. Kill and relaunch the app: the row's `updated` time changes (the app registers again each launch).

## Part E. Delivery (the remaining code, then the test)

Code to write (task 3.11, second half; plan it first, then add a D-n):

- JWT: ES256, header `{alg: ES256, kid: <KEYID>}`, claims `{iss: <TEAMID>, iat: <now>}`, signed with the `.p8`. Apple wants a new token at most every 20 minutes and at least every 60. Go standard library `crypto/ecdsa` is enough.
- Send: HTTP/2 POST to `https://api.sandbox.push.apple.com/3/device/<token>` (or `api.push.apple.com` for production tokens) with headers `authorization: bearer <jwt>`, `apns-topic: <bundle id>`, `apns-push-type: alert`, body from `push.Build` (`internal/push`, at most 256 bytes). Go's `net/http` does HTTP/2 over TLS.
- Triggers: turn ended, approval needed, session failed (FR-23), to every token of the session's project identity. Do not push to a device that has a live subscriber on that session.
- Cleanup: on status 410 or `Unregistered`, and `BadDeviceToken`, delete that token (`Store.DeletePushToken`).
- Config: the key path, key id, team id and bundle id as config keys (paths and ids only, never the key itself). Refuse to start delivery when the key file is group- or world-readable.
- Tests: a fake APNs server (HTTP/2, TLS with a test certificate) in the wire suite to check headers, JWT claims, payload, topic and cleanup on 410, so only the last mile needs the real device.

Device test (T-new, add to SPEC section 7 when the code exists):

1. Part D passed, key and ids configured, gateway restarted.
2. Open a session in the app, send a prompt that takes a while (for example `[slow:20000]` against the fake agent, or any long Bob task), then **lock the phone and background the app**.
3. **Pass:** within a few seconds of the turn ending, a notification appears with the project name as the title and "Turn finished" as the body. No prompt text or file name appears.
4. Repeat with a prompt that needs permission (`[permission]`): "Approval needed" arrives; tapping it opens the app on that session (deep link, D-041). Answer from the inbox.
5. Make the session fail (stop the agent process): "Session failed".
6. With the app open and subscribed to the session, finish a turn: **no** notification (foreground suppression).
7. Revoke notifications in iOS Settings, finish a turn: the gateway logs a 410 or the token stays unused; confirm the token row is removed after the next attempt.
8. Wrong environment: install a build whose `environment` does not match the token. Expect `BadDeviceToken` in the gateway audit and the token removed.

## Part F. Things that fail quietly

- Focus modes and Do Not Disturb hide the banner but the push still arrives.
- A phone with no network at the time gets the push later; Apple keeps only the last one for the same `apns-collapse-id` (unset, so each is kept up to a limit).
- Production tokens from TestFlight or App Store builds do not work against the sandbox host and the reverse.
- If the token row never appears, check in order: the server's `initialize` lists `push`; permission is "Allowed"; the Xcode console shows the token callback.
