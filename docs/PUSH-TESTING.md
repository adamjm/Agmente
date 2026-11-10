# Testing push notifications end to end

Status 2026-11-07: the app asks for permission, gets a device token and gives it to the gateway, and the gateway stores it (D-052). The gateway also **delivers** pushes to APNs (D-053 to D-055): the JWT, the HTTP/2 send, the triggers, foreground suppression, and the cleanup and retry rules are built and tested against a fake APNs server. **Nothing has reached Apple or a device yet.** The device part (Part E, step 3 onward) needs an APNs key from the owner and a real iPhone. This page lists what to do, in order, and how to tell each step worked.

## Part A. Checks that need no Apple account (done; rerun any time)

| Step | Command | Pass |
| --- | --- | --- |
| Gateway wire tests | `scripts/check.sh` | "All checks passed"; `test/push.test.mjs` and `test/apns.test.mjs` are in the count |
| Payload builder (T-24) | `(cd gateway && go test ./internal/push/...)` | ok |
| Delivery against a fake APNs (T-48, wire part) | `node --test test/apns.test.mjs` from `gateway/` after `go build` | every test passes |
| App tests | `xcodebuild -project ACPCode.xcodeproj -scheme ACPCode -destination 'platform=iOS Simulator,name=iPhone 17' test` | TEST SUCCEEDED |
| Register by hand | start a gateway, connect with a token, send `{"jsonrpc":"2.0","id":1,"method":"_acpcode/push/register","params":{"deviceToken":"<64 hex>","environment":"sandbox"}}` | result `{}`; `sqlite3 <stateDir>/gateway.db 'select identity,device,environment from push_tokens'` shows one row |
| Key and config rules | `gateway/bin/acpcode-gateway --config <file> --dry-run` | prints the `push` block with ids and paths, never key bytes; a group-readable key is refused |

## Part B. What you need from Apple (owner)

1. **Apple Developer Program membership** (paid). Needed for the Push capability and the key.
2. **App ID with Push Notifications.** In Certificates, Identifiers & Profiles, open the App ID for the app's bundle id and enable Push Notifications. The project's bundle id is in the Xcode target; the placeholder `com.example.*` ids in the repo will not work. Change the bundle id to one you own first.
3. **APNs auth key (`.p8`).** Keys, then +, tick Apple Push Notifications service (APNs). Download the `.p8` once. Note the **Key ID** (10 characters) and your **Team ID** (10 characters, top right of the membership page). One key works for both sandbox and production.
4. **Store the key on the gateway host only**, outside the repo and the config file (NFR-14: no secrets in config). Mode 0600, for example `/etc/acpcode/AuthKey_<KEYID>.p8`. Never commit it, paste it into chat or put it in the app.
5. **A real iPhone** signed in to iCloud, with a USB cable or wireless debugging. The simulator on Apple silicon can receive pushes dragged in as `.apns` files but cannot get a real device token, so it cannot test this path.

## Part C. Make the app able to receive pushes (needs the Mac, Xcode, the account)

1. In Xcode, select the ACP Code target, Signing & Capabilities, choose your team, and set the unique bundle id from B2.
2. Add the **Push Notifications** capability. This creates the `aps-environment` entitlement (`development` for Debug, `production` for archive builds).
3. Build and run on the iPhone (Debug build, so `environment` is `sandbox`).
4. Settings, Notifications, tap **Allow notifications**, accept the system prompt. The row should read "Allowed, token held". If it shows "Registration failed" with "no valid aps-environment", step 2 did not take effect (clean build folder, re-run).

## Part D. Check the token reaches the gateway (needs only C)

1. Run the gateway (loopback plus Caddy, or `ws://` to your Mac on the same network with "Local only" on, D-019). Connect the app to it.
2. On the gateway host: `sqlite3 <stateDir>/gateway.db 'select identity,device,environment,length(token),updated from push_tokens'`.
3. **Pass:** one row for the token's identity and device, `length(token)` 64, environment `sandbox`.
4. **Check the environment guess:** a Debug build run from Xcode should say `sandbox`. If you install a Release or TestFlight build it must say `production`. If it does not match, delivery fails with `BadDeviceToken`; fix `PushGatewaySync.environment`.
5. Kill and relaunch the app: the row's `updated` time changes (the app registers again each launch).

## Part E. Delivery: what is built, then the device test

### E.1 What is built (D-053 to D-055)

- **Config.** The `push` block in the gateway config (SPEC 6.3): `keyFile` (absolute path to the `.p8`), `keyId`, `teamId`, `topic` (bundle id). Optional `sandboxURL` and `productionURL`. No `push` block means delivery is off. Example for the host (no key material in the file):

  ```json
  "push": {
    "keyFile": "/etc/acpcode/AuthKey_ABCDE12345.p8",
    "keyId": "ABCDE12345",
    "teamId": "TEAM123456",
    "topic": "com.example.yourapp"
  }
  ```

- **Key rule.** The gateway refuses to start when the key is readable by group or others, is not a regular file, or does not parse as a P-256 PKCS#8 key. `chmod 600` fixes the first. `--dry-run` runs the same check and prints `push` with ids and paths only.
- **Auth.** An ES256 provider token: header `{alg, kid}`, claims `{iss, iat}`, cached and rebuilt after 50 minutes. Standard library only.
- **Send.** `POST /3/device/<token>` over HTTP/2 with `authorization`, `apns-topic`, `apns-push-type: alert`, `apns-priority: 10`, and the body from `push.Build` (turn and failure, at most 256 bytes) or `push.BuildApproval` (approval, at most 512 bytes). Neither holds a prompt, tool output or file content; an approval holds only the tool call's title and kind, as a short summary (D-111). The host follows the token's `environment`.
- **Triggers.** A finished turn (`Turn finished`), a failed turn (`Session failed`, when the agent exits mid-turn or refuses the prompt), and an approval request (`Approval needed: <summary>`, for example `Approval needed: Run: npm test`, with `category` `APPROVAL`). Each goes to every stored token.
- **Foreground suppression.** A device with a socket subscribed to that session gets no push at that moment.
- **Cleanup.** 410, `Unregistered`, `BadDeviceToken` or `DeviceTokenNotForTopic` deletes that device's token. 429 and 5xx are retried twice (0.5 s, then 1 s). A 403 `ExpiredProviderToken` rebuilds the JWT once.
- **Audit.** `push_sent`, `push_failed` (status, reason), `push_token_removed`, `push_dropped` (queue full). None holds a token, key, JWT or payload.
- **Tests.** `gateway/test/apns.test.mjs` (wire, against a fake APNs server on HTTP/2 with throwaway keys made at run time) and `internal/push` Go tests. Mutation checks are recorded in RESULTS.

### E.2 Device test (T-48; needs Part B, C and D)

1. Part D passed, the key and ids are in the config, and the gateway is restarted. The audit shows `push_enabled`.
2. Open a session in the app, send a prompt that takes a while (for example `[slow:20000]` against the fake agent, or any long Bob task), then **lock the phone and background the app**.
3. **Pass:** within a few seconds of the turn ending, a notification appears with the project name as the title and "Turn finished" as the body. No prompt text or file name appears. The gateway audit shows `push_sent` with status 200.
4. Repeat with a prompt that needs permission (`[permission]`): "Approval needed" arrives; tapping it opens the app on that session (deep link, D-041). Answer from the inbox.
5. Make the session fail (stop the agent process during a turn): "Session failed".
6. With the app open and subscribed to the session, finish a turn: **no** notification (foreground suppression). The audit has no `push_sent` for that turn.
7. Revoke notifications in iOS Settings, finish a turn: the gateway logs a 410 or the token stays unused; confirm the token row is removed after the next attempt.
8. Wrong environment: install a build whose `environment` does not match the token. Expect `BadDeviceToken` in the gateway audit and the token removed.
9. Record each step's result in `docs/RESULTS.md` under T-48. A step that does not pass is a FAIL with a decision entry, not a changed test.

### E.3 Apple Watch (D-111)

An approval says what is being approved, and the iPhone alert is shown on a paired Apple Watch too. There is no watch app and none is needed: iOS mirrors the iPhone's notifications to the watch. Apple's rule, from [Notifications on your Apple Watch](https://support.apple.com/en-us/108369): "If your iPhone is locked or asleep, you get notifications on your Apple Watch, unless your Apple Watch is locked." And: "If your iPhone is unlocked, you get notifications on your iPhone instead of your Apple Watch." A locked watch, or Do Not Disturb on the watch, sends the alert to the iPhone instead.

**Check on the phone first (owner).**

- The Watch app on the iPhone, My Watch, Notifications, ACP Code: set to *Mirror my iPhone* (or *Custom* with *Allow Notifications* on). Default is mirroring.
- Notification permission for ACP Code is granted in iOS Settings (the app's own permission, not only the watch's).
- Focus modes (Do Not Disturb, a custom Focus) can hold the alert back unless ACP Code is allowed in that Focus. Whether the watch follows the iPhone's Focus: verify on the device.
- The watch and the iPhone use the same Apple ID.

**Manual test.** Needs the device test in E.2 to have passed (the gateway sends the remote push), or the app in the background with the notification permission granted (the local alert, D-111).

1. Wear the watch, unlocked. Lock the iPhone and background the app.
2. Trigger an approval from a prompt that needs permission (`[permission]` against the fake agent, or a real Bob tool call that asks).
3. **Pass:** the watch shows the project name as the title and `Approval needed: Run: …` (the tool call's title, for example `Run: npm test`) as the body, within a few seconds. Tapping it on the watch: verify what it opens (not sourced from Apple; not tested). Answering stays in the app (D-009).
4. Unlock the iPhone and repeat: the alert goes to the iPhone only, not the watch. This is Apple's rule, not a fault.
5. Record the result in `docs/RESULTS.md`.

**What is not verified.** No test in this repository runs on a watch. The watch part is Apple's behaviour and needs a paired watch and an iPhone on the owner's account. The local notification path is covered by unit tests only (`ACPCodeTests/LocalApprovalNotifierTests.swift`, with a fake notification center); the content on a watch is not checked by code.

## Part F. Things that fail quietly

- Focus modes and Do Not Disturb hide the banner but the push still arrives.
- A phone with no network at the time gets the push later; Apple keeps only the last one for the same `apns-collapse-id` (unset, so each is kept up to a limit).
- Production tokens from TestFlight or App Store builds do not work against the sandbox host and the reverse.
- If the token row never appears, check in order: the server's `initialize` lists `push`; permission is "Allowed"; the Xcode console shows the token callback.
- A push is dropped, not sent late, when the gateway's queue is full (64 pending); the audit shows `push_dropped`.
