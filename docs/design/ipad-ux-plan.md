# Agmente fork: iPad and UX critique and build plan

Date: 2026-11-07. Author: design review agent. Status: plan only. No code was edited, built, installed or launched.

## 0. Scope, method, limits

Goal: (a) make the app a good universal iPhone and iPad app with native iPad UI; (b) improve UI and UX overall.

Skills loaded: frontend-design, design-critique, accessibility-review, design-system. All four loaded without error.

Method: read `Agmente/CLAUDE.md`, `docs/SPEC.md`, `ARCHITECTURE.md`, `PLAN.md`, `DECISIONS.md` (as provided), the Xcode project settings, `Info.plist`, and these UI files in full or in the parts that matter: `ContentView.swift`, `Fork/Gateway/*`, `SessionDetailView.swift`, `SettingsView.swift`, `ServerManagementViews.swift`, `Fork/Git/GitView.swift`, `SessionSupplementalViews.swift`, `SessionSidebarView.swift`, `SessionWindowStore.swift`, `AgmenteApp.swift`, `PromptComposerCommands.swift`, and the UIKit transcript in `ChatRendering/`. I did not read `CodexSessionDetailView.swift` line by line (it mirrors `SessionDetailView.swift`; every hook below must be applied to both, and ACP and Codex stay separate per `Agents.md`). I did not read the MCP, Skills or Elicitation views in full.

Limits of this critique:
- It is from code, not from screenshots of a running app. Anything about on-screen behaviour is marked "verify". The first plan phase produces the baseline screenshots.
- Contrast ratios were computed in `scratchpad/contrast.py` from iOS system colour values as I remember them (approximate). Phase 1 adds a test that resolves the real `UIColor` values.
- API availability in section 5 is from memory of the SDK. None was re-read this session. Per CLAUDE.md, every row is "verify" until checked against the `@available` annotations in Xcode.
- The task says upstream edits stay small hooks (D-005). CLAUDE.md line 31 says upstream files "may be changed freely" (D-017, no upstream merges). These conflict. I followed the task: new code in `Agmente/Fork/`, upstream edits listed one by one in section 6.2.
- Line numbers drift: the brief said `SessionListPage` about line 437; it is at `ContentView.swift:503`. `SessionRow` is at `:1505`, `NewSessionSheet` at `:1577`.

## 1. Facts found

### 1.1 Project settings (Agmente.xcodeproj, Debug and Release identical)

| Setting | Value |
| --- | --- |
| `TARGETED_DEVICE_FAMILY` | `"1,2"` on app, tests and UI tests: universal iPhone and iPad |
| `IPHONEOS_DEPLOYMENT_TARGET` | 18.0 (project, tests). The app target inherits it. |
| `MACOSX_DEPLOYMENT_TARGET`, `SUPPORTED_PLATFORMS` | 15.0, `iphoneos iphonesimulator macosx`. A macOS build exists and must keep compiling. |
| `SUPPORTS_MACCATALYST`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` | NO, NO |
| `SWIFT_VERSION` | 5.0 |
| iPhone orientations | Portrait, Landscape Left, Landscape Right |
| iPad orientations | all four, including upside down |
| `UIRequiresFullScreen` | not set. The app is allowed in Split View, Slide Over and Stage Manager. |
| `UIApplicationSupportsMultipleScenes` | not set (generated scene manifest). No "New Window" on iPad today. |
| `UIApplicationSupportsIndirectInputEvents` | YES. Pointer and trackpad events reach the app. |
| Project style | `objectVersion = 77` synchronized folders: new files under `Agmente/Fork/` join the target with no project-file edit (PLAN, phase 2 notes). |

Simulators available on this Mac (listed, not booted): iPad Pro 13-inch (M5), iPad Pro 11-inch (M5), iPad Air 13-inch (M4), iPad Air 11-inch (M4), iPad mini (A20 Pro), iPad (A16), plus iPhone 17, 17e, Air, 18 Pro, 18 Pro Max, iPhone Duo.

### 1.2 Existing iPad-specific handling

Almost none.
- Zero uses of `horizontalSizeClass`, `userInterfaceIdiom`, `ViewThatFits`, `ScaledMetric`, `.popover`, `.inspector`, `.hoverEffect`, `.keyboardShortcut` (outside macOS commands), `dropDestination`, `UIScreen`.
- `NavigationSplitView` exists once, inside `#if os(macOS)` (`ContentView.swift:54`). iOS, including every iPad, gets one `NavigationStack(path:)` (`:63`). So an iPad shows the phone layout stretched.
- `PromptComposerCommands` (send with Command-Return, cancel with Command-period) is compiled only for `macOS || macCatalyst` (`PromptComposerCommands.swift:26`, `AgmenteApp.swift:17`). The `focusedSceneValue` that feeds it is set on iOS too (`SessionDetailView.swift:564`) but nothing consumes it.
- `.contextMenu` appears only in `#if os(macOS)` blocks (`ContentView.swift:705`, `:1985`) and once in `SessionDetailView.swift:1528`.
- `.presentationDetents` appears three times (`SessionDetailView.swift:149`, `PlanModeViews.swift:175`, `ContentView.swift:1666`).
- There are 18 `.sheet(` sites and no popovers.
- The macOS branch already has a two-column structure (`macDetailContent`, `splitSelection`, `SessionWindowStore`). It is the precedent, not reusable as is.

### 1.3 Structural facts that shape the plan

| Fact | Where | Consequence |
| --- | --- | --- |
| One `AppViewModel` per `ContentView`, created as `@StateObject` | `ContentView.swift:8` | A second scene would open a second socket set. See section 3.6. |
| The model has one selected server and one selected session | `AppViewModel.swift:118`, `AppViewModel+Gateway.swift` (`event.sessionId == sessionId` guard) | Only one conversation is live at a time. No two-window, two-session design is possible without model work. |
| Selecting a server reconnects | `selectServer` | Only the selected server has live data. A sidebar cannot show live status for every server. |
| Navigation state is in three places: `navigationPath` (iOS), `splitSelection` (macOS), `model.serverSessionId`, glued by `.onChange` heuristics | `ContentView.swift:92-166` | A split view needs one selection source of truth. |
| Gateway home state is a `@StateObject` inside the list page | `ContentView.swift:512` | A sidebar and a content column cannot share it until it is hoisted. |
| `SessionTimeGroup`, `SessionFolderGroup`, `SessionDisplay`, `SessionRow`, `SessionCardStyle`, `NavigationDestination`, `healthyGreen` are `private` | `ContentView.swift` | New files cannot reuse them without a visibility change or a copy. |
| The transcript is a custom UIKit list (`HighPerformanceChatListView` on `ListViewKit`) with a height cache keyed by entry, width and content hash | `ChatRendering/` | Width changes work by design. Dynamic Type changes and memory under live resize do not (section 2.5). |
| `ChatTranscriptContainerView` already takes `contentInsets` (passed as `.zero`) | `SessionDetailView.swift:354` | A ready hook for a readable column. Whether `ListViewKit` honours left and right insets in its layout is "verify". |

## 2. Critique

Severity: Critical blocks the goal or a user task; Major hurts a group of users; Minor is polish.

### 2.1 First impression and hierarchy

On a phone the home screen opens with a 24 pt rounded title, an agent capabilities block and an "N active, N idle" row inside a large card (`summaryCard`, `ContentView.swift:912`), before the first session. For a gateway server the person's real question is "what needs me, what is running". The answer is a small orange banner (when approvals exist) and then project sections. The strongest element on the screen is the agent's name, which is the least useful.

On an iPad the same screen is full-width cards 22 pt radius, 1000+ pt wide, with an 11 pt chevron at the far edge. Eye travel from title to chevron is the whole screen. Nothing is anchored; the conversation takes over the screen when opened and the list vanishes.

| Finding | Severity | Recommendation |
| --- | --- | --- |
| iPad shows the stretched phone stack (`ContentView.swift:63`) | Critical | Idiom-based three-column `NavigationSplitView` (section 3). |
| Summary card outranks the work (`:912-1070`) | Major | Move agent name and capabilities to the server header or sidebar. First screen: connection state, "Needs you", "Running", recents (Phase 4). |
| New Session is a heavy black split button (`:1117`) on every width; on gateway servers its chevron menu item "Custom Working Directory..." opens the project picker, not a path (`:1153-1160` set `showingNewSessionSheet`, sheet branches on `selectedServerIsGatewayHome` at `:815`) | Major | Gateway: remove the misleading item; start in the selected project in one action; project menu when scope is "All". |
| Grouping toggle (time or folder) is an unlabeled icon (`:849-858`); the gateway home ignores it (it always groups by project) | Minor | Show it only where it applies, as a menu with the current value in its label. Verify whether it shows on gateway servers (it is gated on `serverSessionSummaries` being non-empty). |
| Wordmark `PixelBot` and "let's git together and code" are brand voice, fine on empty states; the "Setup guide" link goes to the upstream project site (`SessionSupplementalViews.swift:451`, `ContentView.swift:753`) | Minor | Owner call: point at this fork's docs, or remove. |

### 2.2 Navigation depth

iPhone path today: server menu (title) -> list -> optional "Show more" folder list -> conversation -> Git sheet -> diff. Settings, MCP servers, refresh, disconnect, edit server and delete server share one "More" menu (`:424-483`). Safe and destructive actions are neighbours; global and per-server actions are mixed.

On iPad the navigation should not be deeper than: sidebar scope -> session -> (inspector tab). With the split view collapsing in a narrow window, depth becomes three (sidebar, list, conversation). Mitigation in section 3.4.

| Finding | Severity | Recommendation |
| --- | --- | --- |
| Three state sources for one selection | Major | `ForkNavigationModel` (Phase 2). |
| "More" mixes global, server and destructive actions | Minor | Split: server actions in the sidebar server header context menu and "Manage servers"; Settings as a sidebar footer row; delete only inside "Edit server". |
| Server switching hidden in the title (a Menu with a pill) | Major | Server switcher is the first element of the iPad sidebar; on iPhone keep the title menu but give it a visible chevron label and VoiceOver hint. |

### 2.3 Empty, loading and error states

| State | Today | Problem | Recommendation |
| --- | --- | --- | --- |
| No server | `SessionPlaceholderView`: wordmark, hint, "Add Server", "Setup guide" | Fine, but generic | Keep; one primary action. |
| Gateway first load | Nothing shown until `hasLoaded` (`GatewayHomeSections`: neither list nor empty branch renders) | Blank screen on first load and after reconnect | Placeholder rows with `redacted(reason: .placeholder)` plus `ProgressView`. |
| Gateway load fails | One orange footnote (`gatewayHomeError`), no retry, stale data kept | No button, no age | Banner: reason, "Updated 2 min ago", Retry button. |
| Gateway has no projects | "No projects yet. Register one on the gateway to start a session." | Says what, not how | Add a second line pointing at the gateway docs, and a copy button for the call. App has no "add project" UI; reserve a "+" slot in the sidebar Projects section. |
| Connection failed or down | Server pill dot is green or orange only (`ContentView.swift:387`, `:402`). `stateLabel` text shows only in dev mode (`:1046`). `.failed(error)` prints raw text. | The person cannot tell "connecting" from "refused by policy" from "auth failed". Critical for a remote-access tool. | Connection banner and pill states (section 3.5). Map failure classes to plain copy (transport policy, pin mismatch, certificate, 401/403/429, unreachable). |
| Disconnected and tap New Session | Button is dimmed to 0.7 opacity but stays enabled and silently returns (`:1120`, `:1155`, `:1189`, `:1216`) | Silent no-op; VoiceOver says it is enabled | `.disabled(...)` plus helper text, or make the tap reconnect. |
| Session open, no messages | "Loading session..." or wordmark and a joke | Fine | Keep. |
| Approval answer fails | Options stay; system message in chat | Good (D-040) | Keep. |

### 2.4 Touch targets (44 pt)

Measured from code, not from a ruler. "About" means glyph size plus padding.

| Control | Where | Size | Verdict |
| --- | --- | --- | --- |
| Composer icon buttons (folder, slash command, photo) | `SessionDetailView.swift:~461-470`, `:~686` | footnote glyph + 8 pt padding: about 32 x 32 | Below 44 |
| Summary card collapse chevron | `ContentView.swift:955` | 28 x 28 | Below 44 |
| Folder header "+" | `:1490-1495` | `.bordered`, `.controlSize(.small)`: about 28 high | Below 44 |
| Clear selected command (xmark) | `SessionDetailView.swift:~641` | 18 pt glyph, no padding | Below 44 |
| Git branch chip, when tappable | `GitView.swift:8-35` | `.caption2` + 3 pt vertical padding: about 20 high | Below 44 |
| Scroll-to-bottom button | `SessionDetailView.swift:~112` | 14 pt glyph + 10-12 pt padding: about 34-38 | Below 44 |
| Approval "Cancel request" | `ApprovalsInboxView.swift` | `.footnote` text button | Below 44 |
| Send and stop button | `SessionDetailView.swift:~536` | 44 x 44 | Pass |
| New session bar | `ContentView.swift:1092` | 50 | Pass |

Fix pattern (Phase 1): one `ForkHitTarget` modifier (`frame(minWidth: 44, minHeight: 44)` plus `contentShape`) so the visual size can stay small. On iPad with a pointer, 44 is not required, but the same app is used by touch.

### 2.5 Dynamic Type

- 32 uses of `.font(.system(size:))` (fixed size). Examples: summary title 24 pt (`ContentView.swift:937`), `PixelBot` 32 and 14 pt, composer glyphs.
- Zero `@ScaledMetric`, zero `dynamicTypeSize` limits, zero `ViewThatFits`. Rows are single `HStack`s with `.lineLimit(1)` titles (`SessionRow`, `GatewaySessionRow`). At accessibility sizes the title truncates first while the badge, count and chevron keep their size.
- UIKit tool-call rows use fixed fonts: `UIFont.systemFont(ofSize: 16/14/15)` and `monospacedSystemFont` (`ToolCallRowView.swift:63-70`), no `UIFontMetrics`. User and markdown rows use `preferredFont` but do not reload on a size change.
- `ChatHeightCache` key is entry id, width and content hash (`ChatHeightCache.swift`). It does not include the content size category, so heights stay stale after the person changes text size while the app runs. It is also never evicted except in `removeAll()` (called on thought expand, `HighPerformanceChatListView.swift:251`). Under live window resize (Stage Manager) each integer width adds entries: unbounded growth. Verify with a resize test.
- Caption2 (11 pt at default) carries information: cwd line, badges, chip. Apple's smallest default text styles are for secondary detail; informational text should be `.caption` (12) or larger and must also pass contrast.

| Finding | Severity | Recommendation |
| --- | --- | --- |
| Fixed fonts in UIKit rows; cache ignores size category | Major | `UIFontMetrics` plus add category to cache key, reload on `UIContentSizeCategory.didChangeNotification` (Phase 6). |
| Single-line rows with badges | Major | `ViewThatFits` or `dynamicTypeSize.isAccessibilitySize` to stack metadata under the title (Phase 1 for `Fork` rows). |
| Width-keyed cache without bound | Major (iPad) | Bucket widths to 8 pt and cap entries (Phase 8). |

### 2.6 Dark mode

Good: most surfaces use system semantic colours; `SessionCardStyle` drops the shadow in dark mode and uses a 0.5 pt hairline (`ContentView.swift:1560-1574`); diff add and remove colours have hand-tuned light and dark pairs (`SessionDetailView.swift:1073-1103`).

Problems:
- `SessionCardStyle` and `DeveloperLogRow` branch on `colorScheme` and use literal `Color.white` (`:1567`, `:1769`). That breaks "elevated" backgrounds and Increase Contrast. `secondarySystemGroupedBackground` gives the same look in both modes with no branch.
- The send button is a black circle (`SessionDetailView.swift:~548`). On dark it is 1.23:1 against `1C1C1E`: nearly invisible. The disabled state is grey with a white glyph (3.26:1).
- The New Session button tint in dark mode is `Color(red: 0.12, green: 0.13, blue: 0.18)` (`ContentView.swift:1084`) on a near-black background. Hand-picked, not checked.
- 41 `Color(red:)` / `UIColor(red:)` literals (16 in `ToolCallRowView.swift`, 16 in `CodexSessionDetailView.swift`, 8 in `SessionDetailView.swift`). They are the de facto palette, undocumented.

### 2.7 VoiceOver

- 93 accessibility identifiers (good for tests) but only 18 `accessibilityLabel` and 6 `accessibilityElement` uses. Identifiers are not labels.
- Icon-only buttons without labels: send and stop, folder, slash command, photo, summary chevron, the toolbar ellipsis menu in `SessionDetailView`, git icon fallback has one (`"Git"`). VoiceOver reads the SF Symbol name ("paperplane fill").
- `SessionRow` activity indicator is a coloured `Circle()` with no label: "active" is colour-only (WCAG 1.4.1).
- `GatewaySessionRow` has no `accessibilityElement(children: .combine)`, so a row reads as separate pieces; the chevron is read. Fix: one combined element, "Title. Running. 2 unread. Active 5 minutes ago. Project X", chevron hidden, custom action "Review approval" when waiting.
- The UIKit transcript has two accessibility settings in total (the "Thinking" button label, and the media row image label). Rows, roles ("You", "Agent"), tool-call status and actions are unset. How VoiceOver reads the third-party `MarkdownTextView` is "verify".
- Good pattern to copy: `GitChipText.accessibilityLabel` (unit-testable label function) and `.accessibilityElement(children: .ignore)`.
- No reduce-motion handling anywhere (14 `withAnimation` or `.animation` uses, a shimmering bubble). Not a blocker; add `accessibilityReduceMotion` for the running indicator and shimmer.

### 2.8 Contrast (computed, light on white / dark on `1C1C1E`)

| Element | Light | Dark | Needs | Pass? |
| --- | --- | --- | --- | --- |
| Status badge text on its 18% tint: orange ("Needs approval") | 1.90 | 5.81 | 4.5 | Fail light |
| Same, red ("Error") | 2.79 | 4.06 | 4.5 | Fail both |
| Same, blue ("Running") | 3.17 | 3.75 | 4.5 | Fail both |
| Same, grey (unknown) | 2.74 | 4.45 | 4.5 | Fail both |
| `healthyGreen` active dot (73,210,123) on card | 1.95 | 8.74 | 3.0 non-text | Fail light |
| Idle dot `systemGray4` on card | 1.52 | n/a | 3.0 non-text | Fail light |
| Approvals banner icon, orange on its 14% tint | 1.96 | n/a | 3.0 non-text | Fail light |
| Orange warning footnotes (`gatewayHomeError`, Local-only warning) | 2.20 on white, 1.97 on grouped | 8.28 | 4.5 | Fail light |
| Unread badge, white on accent blue | 4.02 | 3.65 | 4.5 (small bold text) | Fail both |
| Send button, black circle vs dark surface | n/a | 1.23 | 3.0 non-text | Fail |
| Disabled send, white glyph on grey | 3.26 | | 3.0 non-text | Pass, barely |
| `.tertiary` informational text (cwd line `caption2`) | 1.74 | 2.48 | 4.5 | Fail both |
| `.secondary` small text | about 3.44 | higher | 4.5 for small text | Fail light for caption sizes |

Chevrons in `.tertiary` are decorative; that is acceptable. The cwd line is information.

Candidate replacement values are in section 4.2 and pass 4.5:1 (computed: running 5.69, approval 4.93, error 4.96, ok 4.56 on 12% tints in light; 5.2-7.1 on 16% tints in dark).

### 2.9 What breaks at iPad widths (reading the code, "verify" until baseline screenshots)

| Break | Cause | Fix |
| --- | --- | --- |
| Session cards 1000+ pt wide, one per row | `ScrollView` + `VStack` + `frame(maxWidth: .infinity)` (`ContentView.swift:734-776`) | Columns, `List`, readable width |
| Transcript lines 150+ characters | UIKit rows use full width; user bubble is `bounds.width - 50` (`UserRows.swift:30`), assistant markdown the full row | Readable column (max about 760 pt) via `contentInsets`, code and diffs allowed wider |
| Composer stretches edge to edge; the control row has no overflow handling | `SessionDetailView.swift:~447-482` | Max width equal to the readable column; on compact, collapse secondary controls into one menu |
| Sheets float as small forms; `presentationDetents([.medium])` ignored at regular width (verify) | UIKit sheet behaviour | Choose per screen: popover, inspector, `presentationSizing` (section 3.7) |
| `confirmationDialog` attached to the whole screen (`SessionDetailView.swift:179`) | On iPad it is a popover anchored to its host view | Attach to the triggering button (verify anchor) |
| Elicitation sheet cannot be dismissed (`set: { _ in }`) (`ElicitationFormView.swift:10`) | Binding ignores dismissal; tap-outside on iPad would re-present | Add `.interactiveDismissDisabled(true)` explicitly |
| Server pill with `glassEffect` in the principal slot | Wide nav bar, no sidebar | Move into sidebar header on iPad |
| `Menu` title picker, `searchable` bottom bar (iOS 26) assume a phone | `DefaultToolbarItem(kind: .search, placement: .bottomBar)` (`:863`) | iPad: search at top of content column (verify placement) |
| No arrow-key or Tab navigation in lists | List is `ScrollView` of `Button`s | Real `List(selection:)` |

### 2.10 Gateway status: what is there and what it should be

Today (`GatewayStatusBadge`, `GatewayHomeView.swift:5-35`): idle shows nothing; running blue "Running"; awaiting orange "Needs approval"; error red "Error"; unknown grey with the raw value. A text capsule, caption2 bold, low contrast (section 2.8). The approvals banner is separate. No row-level emphasis, no sorting by urgency, no glyph.

Target (section 3.5): one status pill per session with glyph and text; urgency decides the section order; "Needs you" is the one loud element in the app.

### 2.11 What works well (keep)

- `GatewayHomeLayout` is pure, ordered and tested. The sidebar and content column reuse it.
- Approvals design (D-040): never automatic, explicit buttons, busy state, "answered elsewhere" message, monospaced command. Keep the principle: no keyboard default-action may ever bind to an "allow" option.
- `GitChipText.accessibilityLabel` pattern; `ContentUnavailableView` use for empty logs; `ForkMediaRowView` image labels.
- Dark-mode card treatment and the diff colour pairs.
- Stable accessibility identifiers (list in Appendix B). Keep them on the iPad equivalents.
- `UIApplicationSupportsIndirectInputEvents`, all orientations, no full-screen requirement.
- Brand: SF Rounded wordmark, near-black primary action, white cards, a green "healthy" hue. Small and distinctive enough to keep.

## 3. iPad layout plan

### 3.1 Principles

1. The container is chosen by device idiom, not size class. iPhone keeps `NavigationStack`. Every iPad uses `NavigationSplitView`, which collapses itself in narrow windows. Reason: a size-class switch at runtime (Split View, Stage Manager resize) would swap container types and destroy navigation state. The iPhone Plus and Max models are regular width in landscape, so a size-class rule would also change phones.
2. One selection model (`ForkNavigationModel`), owned by the root, shared by all columns.
3. Gateway state (`GatewayHomeModel`, approvals) is owned above the columns.
4. Boldness in one place: the amber "Needs you" state. Everything else is quiet and monochrome.
5. Phone-first components (status pill, rows, tokens) are shared. Phase 1 improves the phone before any iPad work.

### 3.2 Columns

```
Landscape, 13-inch (about 1376 x 1032 pt)
+-- Sidebar 280-320 ---+-- Sessions 340-400 ----------+-- Conversation (flex) -----------+-- Inspector 320-360 --+
| (o) Bob gateway   v  | Needs you               2    | < Fix flaky auth test  main up1  | Git | Plan | Files    |
|     Connected        | | hand  Fix flaky auth..     | [Inspector] [Approvals] [...]    |                        |
| Needs you         2  | | hand  Migrate db           |                                  | (tab content)          |
| Running           1  | Running                      |      (readable column, 760 max)  |                        |
| All sessions         | o  Refactor billing          |   user bubble                    |                        |
| Projects        [+]  | Today                        |   agent markdown                 |                        |
|   api-service     1  |   Add retry to client        |   tool call rows                 |                        |
|   web-app            |   ...                        |                                  |                        |
| Folders (non-gw)     | [ + New session ]            | [ composer ..................... ] |                        |
| Settings   MCP  Logs |                              |                                  |                        |
+----------------------+------------------------------+----------------------------------+------------------------+

Portrait, 11-inch: sidebar overlays (toggle), Sessions + Conversation visible, inspector opens over the conversation (sheet-like when no room).
Compact (Slide Over, one-third Split View): the split view shows one column at a time. preferredCompactColumn = content when a scope is set, detail when a session is selected. Back goes to content, then sidebar.
```

Sidebar (list style sidebar, rows min 44 pt):
- Header: server switcher (name, connection pill, chevron). Menu lists all servers plus "Add ACP server", "Add Codex app server", "Manage servers".
- "Needs you" (count of awaiting approval + error sessions) and "Running" (count). Smart scopes, gateway only; hidden on servers without gateway.
- "All sessions".
- Projects (gateway) or Folders (other servers, derived from session cwd with `SessionFolderGroup`). Each row: name, awaiting and unread badges, git branch chip is not shown here (too noisy). A "+" slot in the header reserved for "Add project" if the owner wants it (decision 8).
- Footer: Settings, MCP servers (gateway), Developer logs (dev mode).
- Servers other than the selected one are not listed with live data. A "Servers" disclosure at the top of the sidebar lists them with last-connected time and an explicit "not connected" state (see decision 3).

Content column (sessions of the selected scope):
- `List(selection:)`, sections: Needs you (when scope is All), Running, then project or time sections (the current grouping toggle, as a labeled menu).
- Rows: title, one line of preview, project name when the scope is not a single project, relative time, status pill, unread count.
- Search field at the top of the column; scopes (all, needs you, running) as search scopes (verify).
- Toolbar: New session (plus), group menu, refresh. Command-N. Pull to refresh stays.
- Swipe: trailing "Archive" or "Delete" where the server supports it (`canArchiveSessions`, `canDeleteSessionsLocally` exist); leading "Mark read" (gateway `markRead`). Context menu with the same actions plus "Copy session link" (`agmente://session/...` exists in `DeepLink.swift`).
- Empty and error states render in this column (section 2.3).

Detail column:
- Existing `SessionDetailView` and `CodexSessionDetailView` (not rewritten). Title plus subtitle (project path; `navigationSubtitle` is iOS 26 only, verify; fallback is a small secondary line).
- Toolbar: inspector toggle, approvals popover, branch chip (existing `GitSessionToolbar`), ellipsis menu (delete session).
- Empty state: `ContentUnavailableView` "Select a session" with a New session button and, when relevant, "2 sessions need you".
- Inspector (`.inspector`, 320-360): tabs Git (the existing `GitTabView` content), Plan (`SessionPlanView`), Changes (file-change review), Usage. On compact widths the inspector becomes a sheet automatically (verify).

### 3.3 Which screens change and which stay

| Screen | iPhone | iPad |
| --- | --- | --- |
| Root container (`ContentView.containerView`) | Unchanged | New `ForkSplitRoot` (small branch) |
| Home / session list (`SessionListPage`) | Unchanged structure; new tokens, status pill, loading, errors (Phases 1 and 4) | Replaced by sidebar + content column (new files) |
| Gateway home sections / `GatewaySessionRow` | Restyled in place (it is already a Fork file) | Row reused in content column |
| New session | Sheet with detent (project picker) | Menu or popover anchored to the button; sheet only for the free-text path (non-gateway servers) |
| Approvals inbox | Sheet | Popover from the toolbar and "Needs you" scope; the card view is reused |
| Session detail | Unchanged layout; a11y and hit targets | Readable column, inspector, popovers, keyboard |
| Git tab, turn diff | Sheets | Inspector tab; turn diff stays a page-sized sheet (reading a diff needs width) |
| Add or edit server | Form sheet | Form sheet (`presentationSizing(.form)`), unchanged content |
| Settings | Sheet | Form sheet from the sidebar footer, unchanged content |
| MCP servers, Skills editor | Sheets | Form sheets, unchanged |
| Elicitation form | Sheet | Form sheet, `interactiveDismissDisabled` |
| HTML preview | Sheet | Page-sized sheet, unchanged |
| Developer logs, folder "show more" | Stack destinations | Folder "show more" disappears (the content column scope does it); logs stay a detail destination |
| macOS build | Unchanged (`#if os(macOS)` branches stay) | n/a |

### 3.4 Column behaviour and state

- `NavigationSplitView(columnVisibility:preferredCompactColumn:)`, style `.balanced` (verify against `.prominentDetail`). Visibility is stored per scene as a string in `@SceneStorage`. Sidebar scope and selected session id are stored the same way, then validated against the loaded server (an id from another server is dropped).
- `List(selection:)` on a `String?` session id. Selection set calls `model.openSession(id)` exactly once. The detail view must not call it again: the existing `destinationView` has `.task(id: sessionId) { model.openSession(sessionId) }` (`ContentView.swift:280`); `ForkSplitRoot` passes a detail builder that omits it. Add a test that counts subscribe calls (extend `GatewayOpenTests`).
- `model.serverSessionId` changes (new session created, deep link, push tap) drive the selection through `ForkNavigationModel`, guarded by equality to avoid a loop. The macOS-style `.onChange(of: model.serverSessionId)` block and the iOS `navigationPath` block in `ContentView` are skipped on iPad.
- Deep link and push tap (`openLinkedSession`, `.agmenteOpenDeepLink`): on iPad set scope to the session's project and select the session; reveal the detail column in compact mode.
- Compact collapse adds one level (sidebar, list, conversation). With `preferredCompactColumn = .content`, the person lands on the list.

Fallback if `NavigationSplitView` selection or compact collapse misbehaves on iOS 18 or 26 (it has known quirks; verify on both): a hand-built three-pane `HStack` with `ViewThatFits` and explicit toggles. This loses system sidebar behaviour and is the last resort.

### 3.5 Gateway status design

One pill per session. Priority when more than one is true: awaiting approval, error, running, idle. Unread is separate.

| State | Glyph | Colour token | Label | Row treatment | VoiceOver |
| --- | --- | --- | --- | --- | --- |
| awaiting_approval | `hand.raised.fill` | approval (amber) | Needs approval | 4 pt amber leading bar; listed first in "Needs you"; sidebar count badge | "Needs approval." plus custom action "Review approval" |
| error | `exclamationmark.triangle.fill` | error (red) | Failed | red glyph; listed in "Needs you" after approvals | "Failed" |
| running | small `ProgressView`; with Reduce Motion a static `circle.dotted` | running (blue) | Running | none | "Running" |
| idle, unread > 0 | none | ink capsule with count | n | bold title | "n unread" |
| idle, read | none | none | none | plain | none |
| unknown(x) | `questionmark.circle` | secondary | the raw value, capitalised | none | the value |

Never colour alone: every state has a glyph and a word (WCAG 1.4.1). Honour `accessibilityDifferentiateWithoutColor`.

Server connection (replaces the green or orange dot):

| State | Pill | Where explained |
| --- | --- | --- |
| connected | filled dot + name | name only |
| connecting | spinner + name | helper line "Connecting..." |
| disconnected | slashed bolt + name | banner "Not connected" with Connect |
| failed | warning triangle + name | banner with plain-language reason and Retry and Edit server |

Failure copy classes (Phase 4, each unit-tested; unknown errors fall back to the generic text and a "Details" disclosure with the raw string): refused by transport policy (D-018, D-019), certificate or SPKI pin mismatch, client certificate missing, 401 token, 403, 429 rate limit, unreachable or timed out, cancelled. Which raw error strings the app produces for each class is "verify" (read `AppViewModel` connect paths first).

Approvals: the card keeps its layout. Allow and reject are the same size; neither is the default action; no keyboard shortcut binds to Allow (D-009 spirit). Colour is a hint, the label carries the meaning.

### 3.6 Stage Manager, Split View and multi-window: risks

| Risk | Detail | Handling |
| --- | --- | --- |
| Continuous live resize | Stage Manager and iPadOS 26 windowing resize in small steps. Every width computes new heights in the UIKit transcript and adds cache entries. | Bucket widths (8 pt), cap the cache, test a scripted resize. Phase 8. |
| Very small windows | Windows can get narrower than the compact layout assumes. | Set a scene minimum size via `UIWindowScene.sizeRestrictions` (verify) around 320 x 480; test at 320 and 375. |
| Second scene | `UIApplicationSupportsMultipleScenes` is absent, so no new windows today. If enabled: each `ContentView` makes its own `AppViewModel` (second sockets, second connect, duplicated state), and the model has one selected session. The deep-link notification and `.onOpenURL` would reach every scene. | Stay single-scene. Phase 8 designs the hoist (app-level model, per-scene selection) behind a flag that is off. Decision 4. |
| `scenePhase` `.active` -> `resumeConnectionIfNeeded()` | Fires per scene. | Fine for one scene; must be idempotent before multi-scene. |
| Keyboard | Floating keyboard, external keyboard shortcut bar, Split View narrowing while the keyboard is up. | Verify composer visibility in each; no `ignoresSafeArea` changes. |
| Rotation | `HighPerformanceChatListView` re-queries heights at the new width; scroll position should hold. | Test: rotate with the transcript scrolled mid-way; acceptance is within one row. |
| Windows on an external display (iPadOS 26) | No `UIScreen` use exists in the app (checked), good. | Re-check in Phase 8. |
| Push tap with two windows | Not applicable while single-scene. | n/a |
| macOS build | Shares `ContentView`. All new iOS code is behind `#if os(iOS)` or the idiom check. | Compile the macOS destination in the check gate for each phase (verify whether `scripts/check.sh` already does). |

### 3.7 Sheet, popover, inspector, menu: decision table

| Today | Count / where | iPhone | iPad |
| --- | --- | --- | --- |
| New session project picker | `ContentView.swift:814` | Sheet, medium detent | Menu of projects (more than 8: popover with search); free-text path stays a form sheet |
| Approvals inbox | `:806` | Sheet | Popover from toolbar button; also content-column scope |
| Git tab | `GitView.swift:95,542` | Sheet | Inspector tab |
| Turn diff | `GitView.swift:545` | Sheet | Page-sized sheet |
| Working directory picker | `SessionDetailView.swift:147` | Sheet, medium | Popover |
| File changes review | `:151` | Sheet | Inspector "Changes" tab, or page sheet |
| Add or edit server | `ContentView.swift:77,78` | Sheet | Form sheet |
| Settings | `:80` | Sheet | Form sheet |
| MCP servers, Skills | `:81`, Skills editor | Sheet | Form sheet |
| Elicitation | `ElicitationFormView.swift:10` | Sheet | Form sheet, not dismissible by gesture |
| HTML preview | `agentHTMLPreviewSheet` | Sheet | Page sheet |
| Delete confirmations | `confirmationDialog` x3 | Action sheet | Popover anchored to the button |
| Log share | `ShareSheetView` in a sheet | Sheet | Verify popover anchoring; prefer `ShareLink` |

On iPhone a `.popover` adapts to a sheet by default (`presentationCompactAdaptation`, verify iOS 16.4+), so one implementation covers both where listed as popover.

### 3.8 Keyboard, pointer, menu bar

Menu bar (SwiftUI `Commands`, compiled for iOS; iPadOS 26 shows a menu bar for every app, earlier iPadOS shows the Command-hold shortcut overlay; verify):

| Menu | Item | Shortcut | Enabled when |
| --- | --- | --- | --- |
| File | New Session | Command-N | connected |
| File | New Session in Project | submenu | gateway |
| File | Close Session | Command-W | a session is selected (clears selection only) |
| Edit | Send Message | Command-Return | composer has text (exists) |
| Edit | Cancel Response | Command-. | turn running (exists) |
| Edit | Attach Image | Command-Shift-I | composer focused |
| Edit | Find Sessions | Command-F | content column visible |
| View | Show or Hide Sidebar | Control-Command-S | iPad |
| View | Show or Hide Inspector | Option-Command-I | detail visible |
| View | Group by Time or Project | Command-1, Command-2 | list visible |
| Go | Next / Previous Session | Command-] , Command-[ | list non-empty |
| Go | Needs You | Command-Shift-A | gateway |
| Go | Servers 1 to 9 | Command-1...9 conflicts with grouping; use Control-1...9 | n servers |
| Server | Reconnect | Command-R | not connected |
| Server | MCP Servers, Edit Server | none | gateway, selected |

Rules:
- Return in the composer stays a newline. Command-Return sends (matches the macOS commands). Optional setting "Return sends with a hardware keyboard", off by default (decision 5). `onKeyPress` (iOS 17) is the hook; verify it does not interfere with marked text input.
- Escape closes popovers and sheets (system). Sheets: confirm is the default action only for non-destructive forms.
- No shortcut or default action may approve a tool call.
- Hover: `.hoverEffect(.highlight)` and `contentShape(.hoverEffect, ...)` on rows and custom buttons (the plain button style removes system highlights; verify). Context menus on iOS rows. Pointer cursor for text areas is system.
- Drag and drop: drop images onto the composer (`dropDestination`); drag a session row out as its `agmente://` link.
- Focus: a `FocusState`-based focus ring on list rows and a `defaultFocus` on the composer when a session opens by keyboard (verify against the existing `isTextEditorFocused` scroll logic).

## 4. Visual system

Principle: keep what already identifies the app (rounded wordmark, near-black primary action, quiet cards, one healthy green), make every colour a named token with light, dark and high-contrast values, and spend colour on state, not on decoration.

### 4.1 Tokens (what changes versus today)

| Group | Token | Value / rule | Replaces |
| --- | --- | --- | --- |
| Surface | `surface.grouped` | `systemGroupedBackground` | `Color(.systemGray6)` transcript backdrop, literal greys |
| Surface | `surface.row` | `secondarySystemGroupedBackground` (white in light, `1C1C1E` in dark) | `colorScheme == .dark ? secondarySystemBackground : Color.white` |
| Surface | `surface.sidebar` | system sidebar material (do not set) | n/a |
| Line | `line.hairline` | `separator`; 1 px (0.5 pt dark) | `systemGray5` strokes |
| Ink | `ink` | `label` | black buttons, black send circle |
| Ink | `ink.inverse` | `systemBackground` | white glyph literals |
| Text | `text.primary / secondary` | `label` / `secondaryLabel`; informational text never `tertiary` | `.tertiary` info text |
| Status | `status.running` | light `#0057B8`, dark `#6EACFF` | `.blue` |
| Status | `status.approval` | light `#965500`, dark `#FFBD46` | `.orange` |
| Status | `status.error` | light `#C02018`, dark `#FF7D73` | `.red` |
| Status | `status.ok` | light `#1E7A3C`, dark `#5AD67D` | `healthyGreen` |
| Status | `status.fill` | the status colour at 12% (light) / 16% (dark) | 18% tint |
| Accent | `accent` | keep system tint for links and selection; unread uses `ink` capsule so it never reads as "running" blue | default `AccentColor` (empty asset) |

All status values are placeholders from my arithmetic (section 2.8). Phase 1 resolves them as asset-catalog colour sets with Any, Dark and High Contrast variants and a unit test that fails below 4.5:1 for text and 3:1 for glyphs against both surfaces. Increased-contrast values are chosen in that phase and checked by the same test.

Spacing (4 pt base): 4, 8, 12, 16, 20, 24, 32. Gutters: phone 16, pad content columns 20, sidebar 12. Row padding: vertical 12; minimum row height 56 (phone), 52 (pad), 44 (sidebar).

Radius: card 16 on phone (was 22), grouped list inset 10, control 10, pill capsule. On iPad the content column uses plain list rows, not free-floating cards.

Elevation: none in dark; light uses the existing soft shadow only on free cards; list rows have none.

Type (all Dynamic Type text styles; fixed point sizes are removed except the wordmark, which gets `@ScaledMetric`):

| Role | Style | Notes |
| --- | --- | --- |
| Wordmark | rounded semibold, `@ScaledMetric` 32 | brand only |
| Row title | `.body` semibold | two lines allowed at accessibility sizes |
| Row meta | `.subheadline` secondary | replaces `caption2` info |
| Pill / badge | `.caption` bold | minimum text style `.caption` |
| Section header | `.footnote` semibold secondary, sentence case | no forced uppercase (today `.textCase(.uppercase)`) |
| Code, paths, commands | `.callout` monospaced | existing |
| Transcript body | `.callout` via `UIFontMetrics` | existing preferred fonts; tool rows move to metrics |

Motion: only state-driven (running indicator, row insertion). One orchestrated moment: when an approval arrives, its row appears with a short highlight. Reduce Motion replaces it with a static mark.

Hit targets: `ForkHitTarget` min 44 x 44. Icon-only buttons require a label (lint test: UI audit).

### 4.2 Components to extract (names in `Agmente/Fork/Design/`)

`ForkColor`, `ForkSpacing`, `ForkType`, `ForkStatusPill`, `ForkStatusGlyph`, `ForkConnectionPill`, `ForkConnectionBanner`, `ForkCountBadge`, `ForkRowChrome` (surface, hover, selection, accessibility combine), `ForkHitTarget`, `ForkEmptyState`, `ForkSkeletonRows`.

## 5. Platform API notes (all rows "verify" until checked in Xcode)

Deployment target is iOS 18.0, so every row marked 16 to 18 needs no `#available`. The code already guards iOS 26 (`glassEffect`, bottom-bar search).

| API | Used for | Introduced (from memory) |
| --- | --- | --- |
| `NavigationSplitView` three columns, `columnVisibility`, `.navigationSplitViewColumnWidth`, `.navigationSplitViewStyle` | shell | iOS 16 |
| `preferredCompactColumn` | compact landing column | iOS 17 |
| `.inspector`, `.inspectorColumnWidth` | Git, plan, changes | iOS 17 |
| `List(selection:)`, `.listStyle(.sidebar)` | sidebar, content | iOS 14 / 16 |
| `.searchable`, `.searchScopes`, `.searchFocused` | search | iOS 15, 16, 18 |
| `.presentationCompactAdaptation` | popover as sheet on phone | iOS 16.4 |
| `.presentationSizing(.form / .page)` | sheets on iPad | iOS 18 |
| `ContentUnavailableView` | empty states | iOS 17 |
| `.onKeyPress`, `.focusedSceneValue`, `.focusedValue`, `@FocusState` | keyboard | iOS 17, 15, 15, 15 |
| `Commands`, `CommandGroup`, `.keyboardShortcut` | menu bar | iPadOS 14 (menu bar shown for all apps in iPadOS 26) |
| `.hoverEffect`, `contentShape(.hoverEffect, ...)` | pointer | iOS 13.4, 15 |
| `dropDestination`, `draggable` | drag and drop | iOS 16 |
| `ViewThatFits`, `@ScaledMetric`, `dynamicTypeSize` | Dynamic Type | iOS 16, 14, 15 |
| `@SceneStorage` | per-scene selection | iOS 14 |
| `UIWindowScene.sizeRestrictions` | minimum window size | iOS 16 |
| `performAccessibilityAudit(for:)` (XCUITest) | automated a11y audit | iOS 17 / Xcode 15 |
| `navigationSubtitle`, `glassEffect`, `ToolbarSpacer`, `DefaultToolbarItem` | subtitle, glass, bottom-bar search | iOS 26 |
| `TabView` `.sidebarAdaptable` | not used (not a tab app) | iOS 18 |

## 6. Phased build plan

Numbering follows PLAN.md: a new "Phase 7 — iPad and UX" with tasks 7.0 to 7.9. CLAUDE.md "How to work": plan mode per phase, stop for approval, run `scripts/check.sh` after each task, record results in `docs/RESULTS.md`, and add D-n entries (next free is D-091). Suggested decision entries: D-091 idiom-based container; D-092 token system and contrast rule; D-093 keyboard and approval-safety rule; D-094 multi-scene deferred (or accepted).

Each phase below is a stop. Screenshots are taken later on simulators (names as in section 1.1). Nothing here has been run.

### 6.1 Test matrix and commands (used by every phase, run later)

Devices: iPad Pro 13-inch (M5), iPad Air 11-inch (M4), iPad mini (A20 Pro), iPad (A16) for a non-Pro width, iPhone 17 for regression.

Orientations: portrait and landscape on each iPad. Appearance: light, dark. Text size: default, Accessibility XL (`accessibility-extra-extra-extra-large`). Increase Contrast on, off for the status screens.

```
xcodebuild -project Agmente.xcodeproj -scheme Agmente \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -resultBundlePath build/ipad-pro13.xcresult \
  test -only-testing:AgmenteUITests/ForkIPadScreenshotTests
xcrun simctl ui booted appearance dark
xcrun simctl ui booted content_size accessibility-extra-extra-extra-large
xcrun simctl ui booted increase_contrast enabled     # verify the subcommand exists on this Xcode
xcrun xcresulttool export attachments --path build/ipad-pro13.xcresult --output-path docs/design/shots/<date>/ipad-pro13   # verify subcommand
```

Existing gate: `scripts/check.sh` and `xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 17' test` (CLAUDE.md). Required suites from `Agmente/AGENTS.md` stay green: `CodexServerViewModelTests`, `ViewModelSyncTests`, `ACPSessionViewModelTests`, plus `GatewayHomeTests`, `GatewayOpenTests`, `NewSessionProjectPickTests` here.

Split View, Slide Over and Stage Manager cannot be driven by XCUITest (verify). Those are a manual checklist (Phase 8) with screenshots saved to `docs/design/shots/`.

Fixture: screenshots need no live gateway. A DEBUG-only launch argument (`-AgmenteUIFixture gateway-busy`) seeds projects, sessions in every status, two approvals and a canned transcript. Same pattern as the existing DEBUG `ChatComponentGalleryView`. Release builds must contain no fixture code (check: search the Release binary's strings for the fixture name; verify the method).

### Phase 7.0 — Baseline and harness (no UI change)

Files (new):
- `Agmente/Fork/Debug/ForkUIFixtures.swift` (`#if DEBUG`), seeds `GatewayHomeModel`, `ApprovalsInboxModel`, a transcript.
- `AgmenteUITests/ForkIPadScreenshotTests.swift`: launches with the fixture, attaches screenshots per device, orientation, appearance, text size.
- `scripts/ipad-shots.sh`: loops devices and settings (run later).
- `docs/design/shots/<date>/before/` for output (owner decides whether to commit images).

Upstream hooks: the launch-argument read in `AppViewModel` init or `ContentView.onAppear` (1 to 3 lines, `#if DEBUG`).

Acceptance:
1. With the fixture flag the app shows gateway projects, sessions in each status, approvals and a transcript with no network.
2. Running the test on each listed device produces the screenshots listed in the matrix (landscape and portrait, light and dark, default and AX3 text).
3. Release configuration builds and contains no fixture symbols.
4. Baseline images show the current iPad as the stretched phone layout (this is the "before").

How to test: the xcodebuild command above on each device; open the exported attachments.

Risks: UI test flake on cold simulators; the fixture drifting from real gateway payloads (mitigation: build it from `GatewaySession` and `GatewayApproval` types, not strings); screenshot size in the repo.

### Phase 7.1 — Tokens, status pill, accessibility quick wins (phone and pad)

Files (new): `Agmente/Fork/Design/ForkColor.swift`, `ForkSpacing.swift`, `ForkType.swift`, `ForkStatusPill.swift`, `ForkConnectionPill.swift`, `ForkHitTarget.swift`, `ForkRowChrome.swift`; new colour sets under `Assets.xcassets` (Any, Dark, High Contrast); `docs/DESIGN.md` (token table, component list, a11y rules); `AgmenteTests/ForkTokenContrastTests.swift`.

Upstream hooks (small): `GatewayHomeView.swift` (a Fork file, free to edit): `GatewayStatusBadge` becomes `ForkStatusPill`; `GatewaySessionRow` combined accessibility element and `ViewThatFits`. `ContentView.swift`: server pill (`:384-413`) uses `ForkConnectionPill`; `SessionRow` dot gets a label and token; `SessionCardStyle` and `DeveloperLogRow` use `surface.row` (no `colorScheme` branch); New Session buttons `.disabled(!connected)` and helper text (`:1120,1155,1189,1216`); `ApprovalsBanner` icon colour. `SessionDetailView.swift` (and the Codex twin): labels and 44 pt targets on send and stop, folder, slash, photo, xmark, scroll-to-bottom; send button uses `ink` with a visible disabled state; toolbar ellipsis gets a label. `GitView.swift` chip: hit target.

Acceptance:
1. `ForkTokenContrastTests` passes: every text token at least 4.5:1 and every glyph token at least 3:1 on `surface.row` and `surface.grouped`, in light, dark, and increased contrast (resolved `UIColor` for each trait collection).
2. No status is colour-only: each state has a glyph and a word; test asserts the label string for each `GatewaySessionStatus`.
3. Every icon-only button in `SessionDetailView`, `CodexSessionDetailView`, `ContentView` and `GitView` has an accessibility label and a hit area of at least 44 x 44 (UI audit `performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .contrast])` passes on the fixture home and a fixture session).
4. At Accessibility XL the gateway session row shows title, status and project without truncating the status or count; the title wraps.
5. Send button is visible in dark mode at 3:1 or better.
6. New Session while disconnected is disabled and explains why; VoiceOver reports it as dimmed.
7. Existing tests and accessibility identifiers unchanged.

How to test: unit tests; iPhone 17 and iPad Pro 13 screenshots of fixture home and session in light, dark, AX3, increased contrast; VoiceOver read-through of one row (manual, recorded in RESULTS); `performAccessibilityAudit`.

Risks: new colour sets change the look of the phone app (owner reviews screenshots); `performAccessibilityAudit` may flag unrelated upstream issues (record, do not fix in this phase); changing `SessionCardStyle` touches every card. The high-contrast values are my arithmetic and need a design check.

### Phase 7.2 — Navigation model and shared state (no visible change on phone)

Files (new): `Agmente/Fork/Navigation/ForkNavigationModel.swift` (scope enum: needsYou, running, all, project(id), folder(path); selected session; inspector tab; column visibility; Codable for `SceneStorage`), `ForkSessionScope.swift` (pure: scope -> sessions, using `GatewayHomeLayout` and a copy of the time and folder grouping), `AgmenteTests/ForkNavigationModelTests.swift`.

Upstream hooks: `private` removed on `SessionTimeGroup`, `SessionFolderGroup`, `SessionDisplay` in `ContentView.swift` (3 keywords) so the grouping is not copied. `GatewayHomeLayout` gets a pure `triage(sessions)` (Fork file).

Acceptance:
1. Unit tests: scope to session mapping for all scopes; search; ordering (approval, error, running, recent); selection survives a refresh that still contains it; selection clears when it does not; a restored selection from another server is dropped.
2. Gateway home and approvals are owned by the iPad root, not the list page (verified by the Phase 7.3 test; the phone page keeps its own for now).
3. Phone behaviour byte-for-byte unchanged (existing UI test and the three required unit suites).

How to test: `xcodebuild ... test` on iPhone 17. No screenshots.

Risks: the access-level change is the only upstream touch; the grouping copy risk is avoided by it.

### Phase 7.3 — iPad shell: sidebar, content column, detail

Files (new): `Agmente/Fork/Navigation/ForkSplitRoot.swift`, `ForkSidebarView.swift`, `ForkSessionListColumn.swift`, `ForkSessionRow.swift` (shared with the phone gateway home), `ForkDetailEmptyView.swift`, `AgmenteUITests/ForkIPadLayoutTests.swift`.

Upstream hooks: `ContentView.containerView` gets an iPad branch (about 4 lines: `if UIDevice.current.userInterfaceIdiom == .pad { ForkSplitRoot(...) } else { existing }`). `ContentView` `.onChange(of: model.serverSessionId)` and `.onAppear` iOS blocks and `openLinkedSession` skip the `navigationPath` work on iPad and call `ForkNavigationModel` (3 small `if`s). `destinationView` is passed as a closure (no access change). The existing sheets stay at `ContentView` root and are triggered by closures from the sidebar.

Acceptance (iPad Pro 13, Air 11, mini):
1. Landscape: three columns visible. Selecting a session in the content column shows the conversation in the detail column with no push. `openSession` and the gateway subscribe each happen exactly once per selection (spy count, extend `GatewayOpenTests`).
2. Portrait: sidebar overlays and toggles; content and detail visible on 11-inch and 13-inch; on mini portrait the system collapses as it chooses; no state is lost.
3. Rotation keeps scope, selected session and (within one row) transcript scroll.
4. Compact window (Slide Over and one-third Split View, manual): shows one column; back goes content then sidebar; launching into compact shows the content column.
5. Server switcher, Settings, MCP servers, Developer logs reachable from the sidebar; add, edit and delete server work from the sidebar menu. All existing accessibility identifiers (Appendix B) exist on the iPad equivalents.
6. Deep link and push tap select the right project and session and reveal the detail column.
7. New Session in a project scope starts in that project with one action; in the "All" scope it offers a project menu.
8. Empty, loading and error states render in the content column (Phase 7.4 refines them).
9. Search filters the column; Command-F focus arrives with Phase 7.7.
10. iPhone behaviour unchanged.

How to test: `ForkIPadLayoutTests` (selection, rotation via `XCUIDevice.shared.orientation`, scopes, identifiers); screenshot matrix; manual compact checks.

Risks: `NavigationSplitView` selection and compact quirks on iOS 18 and 26 (fallback in 3.4); selection feedback loop with `serverSessionId`; duplicate `openSession` from the old `.task`; sheet presentation from the root over a split view; toolbar placement (`principal` server pill must not render in the detail column on iPad); the session list `.refreshable` and polling loop must move to the root (one loop only).

### Phase 7.4 — Gateway status, "Needs you", connection and loading states (phone and pad)

Files (new): `Agmente/Fork/Gateway/ForkNeedsYouSection.swift`, `ForkConnectionBanner.swift`, `ConnectionFailureCopy.swift` (+ `AgmenteTests/ConnectionFailureCopyTests.swift`), `ForkSkeletonRows.swift`; `GatewayHomeLayout.triage` tests in `GatewayHomeTests`.

Upstream hooks: `ContentView.swift` phone home: replace the summary card block and `ApprovalsBanner` placement with the new sections (hook calls into Fork views); `summaryCard` content moves to a server header view (Fork).

Acceptance:
1. Home order: connection banner (when not connected), Needs you (approval, then error), Running, project or time sections. Same on the iPad content column.
2. The approvals banner keeps its identifier and count; "Needs you" count equals `awaitingApprovalCount` plus error sessions (unit test).
3. Loading shows skeleton rows until `hasLoaded`. Error shows reason, age of the last good data, and a Retry button; stale data stays visible.
4. Each failure class in `ConnectionFailureCopy` has a plain sentence; a raw string never appears as the headline; unknown errors show the generic sentence with a Details disclosure.
5. Reduce Motion: running indicator is static.
6. The server pill and banner agree (same state names) and VoiceOver reads "Server X, connected" and the banner text.
7. Summary card removed from the first screen; agent name and capabilities remain reachable (server header, tap to expand).

How to test: unit tests for triage and copy; fixture screenshots of each state on iPhone 17 and iPad Pro 13, light and dark; Reduce Motion screenshot pair.

Risks: which error strings the app really emits per failure class is unverified (read the connect paths first; CLAUDE.md says test or mark unknown); removing the summary card changes a familiar screen (owner review); the 15 s polling loop and the new banner must share one source.

### Phase 7.5 — Detail column: readable width, inspector, popovers, sheets

Files (new): `Agmente/Fork/Session/ForkReadableColumn.swift` (modifier + width logic), `ForkInspector.swift` (tabs host reusing `GitTabView`, `SessionPlanView`, file-changes review), `ForkPopoverAdaptation.swift` (`presentationCompactAdaptation` and `presentationSizing` helpers), `ForkNewSessionMenu.swift`.

Upstream hooks: `SessionDetailView.swift` and the Codex twin: pass computed `ChatTranscriptInsets` instead of `.zero` (`:354`); composer `frame(maxWidth:)`; one `.forkInspector(...)` modifier; sheets at `:147` and `:151` become popover or inspector on iPad; `confirmationDialog` moved to the triggering button; `GitView.swift` sheet sites route to the inspector on iPad; `ElicitationFormView.swift` adds `.interactiveDismissDisabled(true)`; `ContentView.swift` sheets get `.presentationSizing(.form)` via helper.

Acceptance:
1. 13-inch landscape: transcript text lines at most about 90 characters at default size; code blocks and diffs may use the full detail width. Verified by screenshot and a layout unit test of the inset function.
2. The composer matches the readable column and keeps its controls visible with the software keyboard up.
3. Inspector toggle shows Git, Plan, Changes; selecting a file shows its diff; in a compact window it presents as a sheet.
4. Approvals open as a popover on iPad and as a sheet on iPhone, same view.
5. Delete session confirmation anchors to its button on iPad (screenshot).
6. Elicitation sheet cannot be dismissed by gesture (UI test).
7. `ListViewKit` honours the insets or the plan switches to a SwiftUI width frame; either way rotation and resize keep the scroll position within one row.

How to test: screenshots 13-inch and 11-inch, landscape and portrait, with and without inspector; unit test the inset function; UI tests for popover and inspector presence.

Risks: whether `ListViewKit` lays out rows using the scroll view's bounds or its inset-adjusted width (verify; if not, wrap the representable in a SwiftUI `.frame(maxWidth:)` and accept that the scroll indicator sits at the column edge); inspector on small iPads; popover size for the approvals cards; the Codex twin must get identical hooks without sharing protocol logic.

### Phase 7.6 — Transcript accessibility and Dynamic Type (UIKit rows)

Files (edit, upstream UIKit): `ChatRendering/HighPerformanceChatListView/ToolCallRowView.swift` (`UIFontMetrics`), `UserRows.swift`, `MarkdownRows.swift`, `SystemRows.swift`, `FileChangesRows.swift`, `ChatHeightCache.swift`, `HighPerformanceChatListView.swift`. New: `Agmente/Fork/Design/ForkRowAccessibility.swift` (labels and roles as pure functions, unit-testable).

Acceptance:
1. Changing Dynamic Type while a session is open re-lays out the transcript with correct heights, no clipped text (UI test at default to AX3 to default).
2. Every row exposes an accessibility element with a role-prefixed label ("You", "Agent", "Tool call, running", "Files changed, 3"), and custom actions for Copy and Review where they exist. A VoiceOver read of a fixture transcript matches the expected sequence (manual, recorded).
3. `ChatHeightCache` key includes the size category; entries are bounded.
4. Tool-call fonts use metrics; no fixed `systemFont(ofSize:)` remains in rows.
5. `ChatRenderingTests` pass.

How to test: unit tests for label functions and the cache; UI test for size change; manual VoiceOver and Voice Control pass on iPad Pro 13.

Risks: the third-party `MarkdownTextView` and `ListViewKit` may limit accessibility control (verify before promising rotor support); row height changes could break the scroll-anchoring logic; this phase touches core rendering, so it is isolated from the layout phases.

### Phase 7.7 — Keyboard, pointer, menu bar, drag and drop

Files (new): `Agmente/Fork/Commands/ForkCommands.swift`, `ForkFocusedValues.swift` (navigation actions as a focused scene value), `ForkPointer.swift` (hover and context-menu helpers), `ForkDropTarget.swift`, `AgmenteTests/ForkCommandsTests.swift`.

Upstream hooks: `AgmenteApp.swift` `.commands { PromptComposerCommands(); ForkCommands() }` without the macOS-only guard (2 lines); `PromptComposerCommands.swift:26` `#if` guard removed (1 line); `SessionDetailView` composer `onKeyPress` for the optional Return setting; `SessionDetailView` `.dropDestination` (1 line).

Acceptance:
1. With a hardware keyboard: Command-N, Command-Return, Command-., Command-F, Command-[ and ], Control-Command-S, Option-Command-I work as listed; each is disabled when it does not apply (unit test of enablement from state).
2. Holding Command on iPad shows the shortcut overlay with these items (screenshot; menu bar visible on iPadOS 26 if the simulator supports it).
3. Arrow keys move through the session list, Return opens, Tab reaches the composer.
4. Hover shows an effect on rows and custom buttons; right-click shows the context menu with Copy link, Mark read, Archive or Delete, Open in new window only if Phase 7.8 allows it.
5. Dropping an image on the composer attaches it with the same limits as the picker (`ImageProcessor.maxAttachments`).
6. No shortcut or default action approves a tool call (test: enumerate the commands and the approval buttons).

How to test: XCUITest with `typeKey`; Simulator hardware keyboard on; pointer via the simulator's "Use Mac pointer" option (verify); screenshots of the overlay and context menu.

Risks: `Commands` on iOS inside a `WindowGroup` with `UIApplicationDelegateAdaptor`; shortcut conflicts with text input (Command-1/2 conflicts avoided by using Control for servers); Return handling versus marked text (IME); hover effects with `.buttonStyle(.plain)` may need explicit content shapes.

### Phase 7.8 — Stage Manager, resizing, scenes

Files (new): `Agmente/Fork/Navigation/ForkSceneSupport.swift` (minimum size, scene-aware deep-link target), notes in `docs/DESIGN.md`. Edit: `ChatHeightCache.swift` (width buckets, cap) if not done in 7.6.

Upstream hooks: none planned unless multi-scene is chosen (decision 4). If chosen: `Info.plist` `UIApplicationSupportsMultipleScenes`, `AgmenteApp.swift` model hoisted to an app-level `@StateObject`, `ContentView` taking the model, per-scene selection in `ForkNavigationModel`, `.handlesExternalEvents` for links.

Acceptance (single-scene default):
1. A scripted drag-resize from full to the minimum size (manual in the simulator with Stage Manager, plus a unit test of the width buckets) does not grow the height cache past its cap and keeps scroll position within one row.
2. Minimum window size is enforced; 320 and 375 pt layouts render the compact stack with no clipped controls.
3. Split View 50/50 and 33/67, Slide Over: manual checklist with screenshots in `docs/design/shots/`.
4. Rotating the iPad inside Split View keeps selection.
5. If multi-scene is accepted: two windows on two sessions each show their own conversation and only one socket set exists; links and pushes reach one scene. If not accepted: the plan records the flag as off and the reason in DECISIONS.

How to test: manual Stage Manager and Split View on iPad Pro 13 and iPad mini simulators; unit tests for buckets; log socket count (gateway audit line `connect` count per identity).

Risks: this is the highest-risk phase for the model (single selected session, per-scene `@StateObject`); gateway connection cap is 8 per identity (NFR-4), so more than one socket set per window needs care; `scenePhase` semantics across windows (verify).

### Phase 7.9 — Final QA, documentation, results

Files: `docs/DESIGN.md` (final), `docs/RESULTS.md` entry (date, command, output), `docs/design/shots/<date>/after/`.

Acceptance:
1. Whole matrix (section 6.1) captured and compared to the baseline; before and after pairs for home, session, approvals, git, empty, error, offline.
2. `performAccessibilityAudit` clean on the fixture screens, or each remaining finding recorded as accepted with a reason.
3. VoiceOver, Voice Control, Switch Control spot check (manual) recorded.
4. `scripts/check.sh` and the full `xcodebuild test` pass on iPhone 17 and on an iPad destination; macOS destination builds.
5. Decisions D-091 to D-094 written.

Risks: simulator-only evidence (no physical iPad pointer or Stage Manager hardware check); record that as a limit, as the PLAN does for device-only items.

### 6.2 Upstream hook inventory (all small, listed so none is a surprise)

| File | Change | Phase |
| --- | --- | --- |
| `ContentView.swift` | iPad branch in `containerView`; `private` removed on 3 grouping types; server pill, `SessionRow`, `SessionCardStyle` use tokens; disabled New Session; summary card moved | 7.1, 7.2, 7.3, 7.4 |
| `ContentView.swift` | skip `navigationPath` blocks on iPad (3 `if`s) | 7.3 |
| `AgmenteApp.swift` | ungate `.commands`, add `ForkCommands()` | 7.7 |
| `PromptComposerCommands.swift` | remove the macOS-only guard | 7.7 |
| `SessionDetailView.swift`, `CodexSessionDetailView.swift` | labels and hit targets; insets; inspector modifier; popovers; drop target; `onKeyPress` | 7.1, 7.5, 7.7 |
| `GitView.swift`, `ElicitationFormView.swift` | hit target; inspector routing; non-dismissible sheet | 7.1, 7.5 |
| `ChatRendering/*` | metrics, accessibility, cache | 7.6, 7.8 |
| `Assets.xcassets` | new colour sets (new files) | 7.1 |
| `Info.plist`, `project.pbxproj` | none, unless multi-scene is chosen | 7.8 |

### 6.3 Risk register (cross-phase)

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| `NavigationSplitView` quirks on iOS 18 or 26 | Medium | High | Prototype in 7.3 on both; fallback in 3.4 |
| Selection/subscribe loops with `serverSessionId` | Medium | High | Single writer, equality guards, subscribe-count test |
| Hidden regressions on phone from token changes | Medium | Medium | Screenshots before and after on iPhone 17 each phase |
| UIKit transcript (`ListViewKit`) limits | Medium | Medium | Isolate in 7.6; verify before promising |
| Single-model assumption (one selected session) | High if multi-scene | High | Keep single-scene by default |
| Estimates from memory of APIs wrong | Medium | Low | "verify" column; check `@available` first in each phase |
| UI test flake / fixture drift | Medium | Low | Build fixtures from real types; keep identifiers stable |
| macOS build breaks | Low | Medium | `#if os(iOS)` guards; build the macOS destination each phase |
| The high-contrast and increased-contrast values are my arithmetic | Medium | Low | The contrast test decides, not my numbers |

## 7. Owner decisions (with recommendation)

1. Container choice. Recommend: idiom-based `NavigationSplitView` on every iPad; iPhone keeps `NavigationStack`. Alternative (size-class switch) risks state loss on resize.
2. iPhone scope. Recommend: improve the phone in place (tokens, status, a11y, error states) and do not move it to a split view.
3. Sidebar and servers. Recommend: one live server at a time; sidebar shows a server switcher plus the selected server's scopes, other servers listed as "not connected". Concurrent multi-server connections need a model rewrite; not now.
4. Multi-window. Recommend: stay single-scene now; decide again after 7.8 documents the hoist cost. Do not set `UIApplicationSupportsMultipleScenes` until then.
5. Return key. Recommend: Command-Return sends, Return is a newline; an optional "Return sends on hardware keyboards" setting, default off.
6. Brand colour. Recommend: no new brand hue; keep near-black ink and the system tint; the amber "Needs you" is the one accent. A branded accent is a separate pass.
7. Setup-guide link. Recommend: point it at this fork's docs (or remove it); it currently opens the upstream project's site.
8. App-side "Add project". Recommend: not in this plan; reserve the "+" slot in the sidebar and decide with the gateway roadmap.
9. Screenshots in the repo. Recommend: commit only the final "after" set; keep "before" local.
10. Phase 7.6 (UIKit transcript) timing. Recommend: after the layout phases, as written; it carries the highest regression risk and the most accessibility value, so it should not be dropped.

## Appendix A. Findings ranked by impact

1. iPad is the stretched phone stack; no idiom or size-class handling (`ContentView.swift:63`). The macOS split view exists but is not used.
2. Selection state is split across `navigationPath`, `splitSelection` and `serverSessionId`; gateway home state is private to the list page. Both block a split view.
3. Menu commands, context menus and hover are compiled only for macOS; no hardware-keyboard send or navigation on iPad.
4. Status and contrast failures, measured: badge text 1.9 to 3.2:1 (light), active dot 1.95:1, black send button 1.23:1 in dark, tertiary info text 1.74:1; "active" is colour-only.
5. Connection state is a green or orange dot; failures are invisible outside dev mode; New Session silently does nothing when disconnected.
6. Transcript: full-width lines on iPad, fixed UIKit fonts, size-blind height cache that also grows under resize, almost no VoiceOver configuration.
7. Touch targets of 20 to 38 pt on common controls; send, stop, folder, photo and slash buttons have no labels.
8. 18 full sheets with no popover, inspector or sizing; detents ignored at regular width; confirmations anchored to the screen; elicitation sheet dismissal binding.
9. Home hierarchy: summary card first, no loading state, generic empty states, misleading "Custom Working Directory..." on gateway servers.
10. Multi-window is unsafe today: one `AppViewModel` per scene and a single selected session.

## Appendix B. Accessibility identifiers to keep on iPad equivalents

`newSessionButton`, `newSessionMenuButton`, `moreMenuButton`, `sessionGroupingToggle`, `addACPServerMenuAction`, `addCodexServerMenuAction`, `gatewayMCPServers`, `emptyStateAddServerButton`, `gatewayStatus.<status>`, `gatewaySession.<id>`, `gatewayProject.<id>`, `gatewayHomeError`, `gatewayHomeEmpty`, `gatewayProjectChoice.<id>`, `gatewayCreateSession`, `gatewayNoProjects`, `approvalsBanner`, `approvalsNotice`, `approvalsError`, `approvalsEmpty`, `approval.<id>`, `approvalOption.<id>.<option>`, `approvalCancel.<id>`, `showMoreFolder_<path>`, `newSessionInFolder_<path>`, `gitBranchChip`, `gitOpenButton`, `gitSectionPicker`, `gitTabDone`, `turnDiffSheet`, `ServerNameField`, `ServerTypePicker`, `LocalOnlyToggle`, `ProtocolPicker`, `SaveServerButton`, `saveToolbarButton`.

## Appendix C. Files read

`Agmente/CLAUDE.md`, `Agmente/AGENTS.md` (app layer), `AgmenteUITests/AGENTS.md`, `Agmente.xcodeproj/project.pbxproj` (settings), `Agmente/Info.plist`, `Agmente/AgmenteApp.swift`, `ContentView.swift` (all), `SessionDetailView.swift` (parts: body, transcript, composer, mode picker), `SessionSidebarView.swift`, `SessionWindowStore.swift`, `PromptComposerCommands.swift`, `SettingsView.swift` (parts), `ServerManagementViews.swift` (parts), `SessionSupplementalViews.swift` (parts), `Fork/Gateway/*`, `Fork/Git/GitView.swift` (parts), `Fork/MCP/MCPEntryPoint.swift`, `Fork/Skills/SkillsEditorView.swift` (start), `Fork/Elicitation/ElicitationFormView.swift` (start), `ChatRendering/ChatTranscriptContainerView.swift`, `ChatHeightCache.swift`, `HighPerformanceChatListView.swift` (parts), `UserRows.swift`, `RowViewSupport.swift`, `ACPClient/.../Gateway/GatewayClient.swift` (function list), `Assets.xcassets/AccentColor`. Contrast arithmetic: `scratchpad/contrast.py`.
