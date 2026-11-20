import XCTest

/// Exploration of the Settings panel (connections, MCP servers, Agent, App, Developer).
///
/// Every test skips itself unless `ACPCODE_UI_GATEWAY_URL` is set, because they need the throwaway
/// loopback gateways. The environment is passed with the `TEST_RUNNER_` prefix:
/// - ACPCODE_UI_GATEWAY_URL, ACPCODE_UI_GATEWAY_TOKEN_FILE: gateway A (a file holding its test token)
/// - ACPCODE_UI_GATEWAY2_URL, ACPCODE_UI_GATEWAY2_TOKEN_FILE: gateway B
/// - ACPCODE_UI_SHOT_DIR: directory for PNG copies of each screenshot
/// - ACPCODE_UI_REPORT_FILE: a text file that receives one finding per line
///
/// Tokens are read from files at run time and are never written to the report or to stdout.
@MainActor
final class SettingsExplorationUITests: XCTestCase {

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        // Exploration: keep going after a failed check so every flow is reached and reported.
        continueAfterFailure = true
        try XCTSkipUnless(env["ACPCODE_UI_GATEWAY_URL"] != nil, "Needs the throwaway gateway (ACPCODE_UI_GATEWAY_URL)")
    }

    // MARK: - Gateway targets

    private struct GatewayTarget {
        let name: String
        /// host:port as typed into the Host field. The scheme is chosen separately (ws, Debug loopback, D-019).
        let host: String
        let tokenFile: String
    }

    private func target(urlKey: String, tokenKey: String, name: String) -> GatewayTarget? {
        guard let raw = env[urlKey], let url = URL(string: raw), let host = url.host, let port = url.port,
              let tokenFile = env[tokenKey] else { return nil }
        return GatewayTarget(name: name, host: "\(host):\(port)", tokenFile: tokenFile)
    }

    private var gatewayA: GatewayTarget? {
        target(urlKey: "ACPCODE_UI_GATEWAY_URL", tokenKey: "ACPCODE_UI_GATEWAY_TOKEN_FILE", name: "UI gateway A")
    }

    private var gatewayB: GatewayTarget? {
        target(urlKey: "ACPCODE_UI_GATEWAY2_URL", tokenKey: "ACPCODE_UI_GATEWAY2_TOKEN_FILE", name: "UI gateway B")
    }

    private func token(for target: GatewayTarget) -> String {
        ((try? String(contentsOfFile: target.tokenFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reporting

    private func log(_ line: String) {
        print("SETTINGS-UI: " + line)
        guard let path = env["ACPCODE_UI_REPORT_FILE"], let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["ACPCODE_UI_SHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
        log("shot \(name)")
    }

    // MARK: - Helpers

    @discardableResult
    private func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = 8) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Opens Settings from the root. Returns the entry point used, or nil. Tries each known entry point in turn.
    private func openSettings(_ app: XCUIApplication) -> String? {
        let close = app.buttons["settingsCloseButton"]
        if close.exists { return "already open" }
        let avatar = app.buttons["sidebarAvatarButton"]
        if avatar.waitForExistence(timeout: 3) {
            avatar.tap()
            if close.waitForExistence(timeout: 10) { return "sidebarAvatarButton" }
        }
        // The root's More menu holds Settings, Refresh and Disconnect. A sidebar drawer left open covers the
        // More button, so tap the right edge first to close it (the nav bar can hold two copies: take the first).
        let more = app.buttons["moreMenuButton"].firstMatch
        if more.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            _ = waitGone(app.buttons["sidebarAvatarButton"], 2)
            more.tap()
            let item = app.buttons["Settings"].firstMatch
            if item.waitForExistence(timeout: 3) {
                item.tap()
                if close.waitForExistence(timeout: 10) { return "moreMenuButton then Settings" }
            }
            log("openSettings: More menu did not offer Settings; items=\(app.buttons.allElementsBoundByIndex.map { $0.label }.filter { !$0.isEmpty })")
        }
        let drawer = app.buttons["drawerMenuButton"].firstMatch
        if drawer.waitForExistence(timeout: 3) {
            drawer.tap()
            if avatar.waitForExistence(timeout: 5) {
                avatar.tap()
                if close.waitForExistence(timeout: 10) { return "drawerMenuButton then sidebarAvatarButton" }
            }
        }
        return nil
    }

    /// Each xcodebuild run starts a fresh simulator clone with no saved connections. A test adds gateway A when it
    /// is missing, then relaunches once (the known bug: a new server connects only after a restart).
    private func ensureSaved(_ app: XCUIApplication, _ target: GatewayTarget, shotPrefix: String) {
        if connectionRow(host: target.host, app).waitForExistence(timeout: 3) { return }
        log("precondition: \(target.name) not saved in this run; adding it first")
        addConnection(app, target, shotPrefix: shotPrefix)
        app.terminate()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        log("precondition: relaunched after adding \(target.name): settings opened via \(openSettings(app) ?? "NONE")")
    }

    /// Pops the pushed screen with its back button. A sheet leaves the app's own nav bars in the tree, so take the
    /// topmost bar that is not the main "Projects" bar or the presentation host.
    private func popBack(_ app: XCUIApplication) {
        let bars = app.navigationBars.allElementsBoundByIndex.filter {
            $0.identifier != "Projects" && !$0.identifier.contains("Presentation")
        }
        guard let top = bars.last else { log("popBack: no pushed nav bar found"); return }
        let back = top.buttons.element(boundBy: 0)
        log("popBack: tapping back in nav bar \"\(top.identifier)\" (button \"\(back.label)\")")
        back.tap()
    }

    private func closeSettings(_ app: XCUIApplication) {
        let close = app.buttons["settingsCloseButton"]
        guard close.exists else { log("close: settings close button not found"); return }
        close.tap()
        log("close dismissed settings root: \(waitGone(close))")
    }

    private func connectionRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settingsConnection.'"))
    }

    private func connectionRow(host: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'settingsConnection.' AND label CONTAINS %@", host)).firstMatch
    }

    private func dotLabels(_ app: XCUIApplication) -> [String] {
        ["Connected", "Connecting", "Disconnected", "Connection failed"].filter {
            app.descendants(matching: .any)[$0].exists
        }
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    /// Adds a gateway connection through Settings > Add connection. Returns true when the sheet closed.
    @discardableResult
    private func addConnection(_ app: XCUIApplication, _ target: GatewayTarget, shotPrefix: String) -> Bool {
        let addRow = app.buttons["settingsAddConnection"]
        guard addRow.waitForExistence(timeout: 10) else { log("add: settingsAddConnection not found"); return false }
        addRow.tap()
        let nameField = app.textFields["ServerNameField"]
        guard nameField.waitForExistence(timeout: 10) else { log("add: add sheet did not appear"); return false }
        nameField.tap()
        nameField.typeText(target.name)

        let picker = app.segmentedControls["ProtocolPicker"]
        let ws = picker.buttons["ws"].exists ? picker.buttons["ws"] : app.buttons["ws"]
        if ws.waitForExistence(timeout: 3) { ws.tap() } else { log("add: ws segment not found") }

        let hostField = app.textFields["HostField"]
        hostField.tap()
        hostField.typeText(target.host)

        let tokenField = app.secureTextFields["Bearer token (optional)"]
        if tokenField.waitForExistence(timeout: 3) {
            tokenField.tap()
            tokenField.typeText(token(for: target))
        } else {
            log("add: token field not found")
        }
        shot("\(shotPrefix)_form_filled", app)

        let save = app.buttons["saveToolbarButton"]
        log("add: save toolbar enabled before tap=\(save.isEnabled)")
        save.tap()

        let confirm = app.buttons["serverSummaryConfirmButton"]
        if !confirm.waitForExistence(timeout: 30) {
            let alert = app.alerts.firstMatch
            if alert.exists {
                log("add: error alert \(alert.label): \(alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))")
                shot("\(shotPrefix)_add_error", app)
                alert.buttons.firstMatch.tap()
            } else {
                log("add: no summary overlay and no alert within 30 s")
                shot("\(shotPrefix)_add_timeout", app)
            }
            return false
        }
        shot("\(shotPrefix)_summary_overlay", app)
        confirm.tap()
        let gone = waitGone(nameField, 15)
        log("add \(target.name): sheet closed=\(gone)")
        return gone
    }

    // MARK: - Flow 1 and 2: entry point, root look, no servers, add (cancel, then real)

    func testA_EntryPointsNoServersAddCancelAndAdd() throws {
        guard let a = gatewayA else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()

        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        log("flow1 launch: sidebarAvatarButton=\(app.buttons["sidebarAvatarButton"].exists) drawerMenuButton=\(app.buttons["drawerMenuButton"].exists) moreMenuButton=\(app.buttons["moreMenuButton"].exists) emptyStateAddServerButton=\(app.buttons["emptyStateAddServerButton"].exists)")
        shot("01_launch_root", app)

        let entry = openSettings(app)
        log("flow1 entry point used: \(entry ?? "NONE")")
        guard entry != nil else { XCTFail("No Settings entry point reached"); return }
        shot("02_settings_root_no_servers", app)

        log("flow1 nav title Settings present=\(app.navigationBars["Settings"].exists)")
        let close = app.buttons["settingsCloseButton"]
        log("flow1 close button exists=\(close.exists) label=\"\(close.label)\" frame=\(close.frame)")
        for section in ["Connections", "MCP servers", "App", "Developer", "Agent"] {
            log("flow1 section label \"\(section)\" visible=\(app.staticTexts[section].exists)")
        }
        log("flow1 settings identifiers: \(app.buttons.allElementsBoundByIndex.map { $0.identifier }.filter { $0.hasPrefix("settings") }.joined(separator: ", "))")

        // Flow 2: no servers.
        log("flow2 connection rows with no servers: \(connectionRows(app).count)")
        log("flow2 MCP placeholder row present=\(app.descendants(matching: .any)["settingsMCPSelectConnectionFirst"].exists)")

        app.buttons["settingsAddConnection"].tap()
        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "add sheet should open")
        shot("03_add_sheet_empty", app)
        log("flow2 add sheet: save toolbar enabled with empty form=\(app.buttons["saveToolbarButton"].isEnabled) nav title present=\(app.navigationBars["Add Server"].exists)")
        app.buttons["Cancel"].firstMatch.tap()
        log("flow2 cancel dismissed add sheet=\(waitGone(nameField))")
        shot("04_after_cancel", app)
        log("flow2 connection rows after cancel: \(connectionRows(app).count)")

        let added = addConnection(app, a, shotPrefix: "05_add_A")
        log("flow2 add real connection A ok=\(added)")
        XCTAssertTrue(added, "adding gateway A should succeed")

        // Known bug: a new server does not connect until restart. Relaunch once, then check.
        app.terminate()
        app.launch()
        log("flow2 relaunch after adding A: terminate then launch done")
        let entryAfter = openSettings(app)
        log("flow2 settings reopened after relaunch via: \(entryAfter ?? "NONE")")
        shot("06_settings_after_relaunch_A", app)
        log("flow2 rows after relaunch: \(connectionRows(app).count) dots=\(dotLabels(app)) selectedCheck=\(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selected'")).count)")
        log("flow2 agent section visible=\(app.buttons["settingsClaudeConnections"].exists) MCP row=\(app.buttons["settingsMCPServers"].exists)")
        closeSettings(app)
    }

    // MARK: - Flow 3 and 4: two connections, detail facts, use, edit, delete

    func testB_TwoConnectionsDetailUseEditDelete() throws {
        guard let a = gatewayA, let b = gatewayB else { throw XCTSkip("gateway B not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")
        ensureSaved(app, a, shotPrefix: "pre_A")
        log("flow3 rows before adding B: \(connectionRows(app).count)")

        let addedB = addConnection(app, b, shotPrefix: "07_add_B")
        log("flow3 add connection B ok=\(addedB)")
        app.terminate()
        app.launch()
        log("flow3 relaunch after adding B: terminate then launch done")
        _ = openSettings(app)
        shot("08_two_connections_root", app)
        log("flow3 rows=\(connectionRows(app).count) dots=\(dotLabels(app)) selectedChecks=\(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Selected'")).count)")
        for row in connectionRows(app).allElementsBoundByIndex {
            log("flow3 row label=\"\(row.label)\" identifier=\(row.identifier)")
        }

        // Detail of B (not selected at this point, or the other way round; the screen says which).
        XCTAssertTrue(connectionRow(host: b.host, app).waitForExistence(timeout: 8), "row for B should exist")
        connectionRow(host: b.host, app).tap()
        XCTAssertTrue(app.buttons["settingsEditConnection"].waitForExistence(timeout: 8), "detail for B should open")
        shot("09_detail_B", app)
        log("flow3 detail B nav title=\(app.navigationBars[b.name].exists) useButtonEnabled=\(app.buttons["settingsUseConnection"].isEnabled) useRowValue \"In use\" visible=\(app.staticTexts["In use"].exists)")
        for label in ["Scheme", "Host", "Client certificate", "Agent", "Details"] {
            log("flow3 detail fact \"\(label)\" visible=\(app.staticTexts[label].exists)")
        }
        log("flow3 detail values: host \(b.host) visible=\(app.staticTexts[b.host].exists) \"Stored on this device\" visible=\(app.staticTexts["Stored on this device"].exists) \"Not known until connected\" visible=\(app.staticTexts["Not known until connected"].exists)")

        let tree = app.debugDescription
        log("flow3 token A text present in accessibility tree (detail B): \(tree.contains(token(for: a)))")
        log("flow3 token B text present in accessibility tree (detail B): \(tree.contains(token(for: b)))")
        log("flow3 the word \"Bearer\" present in tree: \(tree.contains("Bearer"))")

        popBack(app)
        _ = waitGone(app.buttons["settingsEditConnection"], 5)
        shot("09b_after_back_to_root", app)
        dumpTree("tree_after_back.txt", app)
        log("flow3 after back: navbars=\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier }) buttons=\(app.buttons.allElementsBoundByIndex.map { $0.label }.prefix(20))")
        XCTAssertTrue(connectionRow(host: a.host, app).waitForExistence(timeout: 8), "back to root should show A")
        log("flow3 back from detail B to root: rows=\(connectionRows(app).count)")

        // Flow 4: Use. B was selected when it was added, so use A (the other connection) and check the sheet and checkmark.
        log("flow4 before Use: B selected=\(connectionRow(host: b.host, app).descendants(matching: .any)["Selected"].exists) A selected=\(connectionRow(host: a.host, app).descendants(matching: .any)["Selected"].exists)")
        connectionRow(host: a.host, app).tap()
        XCTAssertTrue(app.buttons["settingsUseConnection"].waitForExistence(timeout: 8))
        let useButton = app.buttons["settingsUseConnection"]
        log("flow4 A detail before Use: useButtonEnabled=\(useButton.isEnabled) \"In use\" visible=\(app.staticTexts["In use"].exists)")
        shot("10a_detail_A_before_use", app)
        if useButton.isEnabled {
            useButton.tap()
            log("flow4 tapped Use on A")
        }
        _ = app.staticTexts["In use"].waitForExistence(timeout: 8)
        shot("10_use_A_detail", app)
        log("flow4 after Use on A: useButtonEnabled=\(useButton.isEnabled) \"In use\" visible=\(app.staticTexts["In use"].exists)")
        popBack(app)
        _ = connectionRow(host: a.host, app).waitForExistence(timeout: 8)
        shot("11_root_after_use_A", app)
        log("flow4 root after Use on A: B selected=\(connectionRow(host: b.host, app).descendants(matching: .any)["Selected"].exists) A selected=\(connectionRow(host: a.host, app).descendants(matching: .any)["Selected"].exists) dots=\(dotLabels(app)) rowA=\"\(connectionRow(host: a.host, app).label)\" rowB=\"\(connectionRow(host: b.host, app).label)\"")

        // Edit B: change name, save, check the row.
        connectionRow(host: b.host, app).tap()
        XCTAssertTrue(app.buttons["settingsEditConnection"].waitForExistence(timeout: 8))
        app.buttons["settingsEditConnection"].tap()
        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "edit sheet should open")
        shot("12_edit_sheet_B", app)
        log("flow4 edit sheet nav title \"Edit Server\" present=\(app.navigationBars["Edit Server"].exists) name value=\"\((nameField.value as? String) ?? "")\" token field present=\(app.secureTextFields["Bearer token (optional)"].exists)")
        replaceText(nameField, with: "UI gateway B edited")
        app.buttons["saveToolbarButton"].tap()
        let confirm = app.buttons["serverSummaryConfirmButton"]
        if confirm.waitForExistence(timeout: 30) {
            shot("13_edit_summary_B", app)
            confirm.tap()
        } else {
            log("flow4 edit: no summary overlay within 30 s; alert exists=\(app.alerts.firstMatch.exists)")
        }
        log("flow4 edit sheet closed=\(waitGone(nameField, 15))")
        _ = app.navigationBars["UI gateway B edited"].waitForExistence(timeout: 8)
        shot("14_detail_B_after_edit", app)
        log("flow4 detail nav title shows edited name=\(app.navigationBars["UI gateway B edited"].exists)")
        popBack(app)
        _ = app.buttons["settingsCloseButton"].waitForExistence(timeout: 5)
        log("flow4 root row label after edit: \(connectionRow(host: b.host, app).label)")
        shot("15_root_after_edit", app)

        // Delete B: cancel first, then delete.
        connectionRow(host: b.host, app).tap()
        XCTAssertTrue(app.buttons["settingsDeleteConnection"].waitForExistence(timeout: 8))
        app.buttons["settingsDeleteConnection"].tap()
        let alert = app.alerts["Delete Server"]
        log("flow4 delete alert appeared=\(alert.waitForExistence(timeout: 8))")
        shot("16_delete_alert", app)
        if alert.exists {
            log("flow4 delete alert message: \(alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))")
            alert.buttons["Cancel"].tap()
            log("flow4 cancel closed the alert=\(waitGone(alert))")
        }
        log("flow4 after cancel still on detail=\(app.buttons["settingsEditConnection"].exists)")
        app.buttons["settingsDeleteConnection"].tap()
        if alert.waitForExistence(timeout: 8) { alert.buttons["Delete"].tap() }
        log("flow4 deleted B; detail gone=\(waitGone(app.buttons["settingsEditConnection"], 10))")
        _ = app.buttons["settingsCloseButton"].waitForExistence(timeout: 5)
        shot("17_root_after_delete", app)
        log("flow4 rows after delete: \(connectionRows(app).count) labels=\(connectionRows(app).allElementsBoundByIndex.map { $0.label })")
        log("flow4 B row still listed=\(connectionRow(host: b.host, app).exists)")
        closeSettings(app)
    }

    // MARK: - Flow 5 and 6: MCP section, Agent section, App, Developer

    func testC_MCPAgentAppDeveloper() throws {
        guard let a = gatewayA else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")

        ensureSaved(app, a, shotPrefix: "pre_A")
        // Make A the selected connection and wait for it to connect.
        let rowA = connectionRow(host: a.host, app)
        XCTAssertTrue(rowA.waitForExistence(timeout: 8), "row for A should exist")
        rowA.tap()
        if app.buttons["settingsUseConnection"].waitForExistence(timeout: 8), app.buttons["settingsUseConnection"].isEnabled {
            app.buttons["settingsUseConnection"].tap()
            log("flow5 selected A via Use")
        }
        popBack(app)
        _ = app.descendants(matching: .any)["Connected"].waitForExistence(timeout: 15)
        log("flow5 root with A selected: dots=\(dotLabels(app)) rows=\(connectionRows(app).count)")
        shot("18_root_A_selected", app)

        // Flow 5: MCP servers for the gateway connection.
        let mcpRow = app.buttons["settingsMCPServers"]
        XCTAssertTrue(mcpRow.waitForExistence(timeout: 8), "MCP servers row should exist")
        log("flow5 MCP row value/label: \"\(mcpRow.label)\"")
        mcpRow.tap()
        let mcpNav = app.navigationBars["MCP servers"]
        log("flow5 MCP screen opened=\(mcpNav.waitForExistence(timeout: 8))")
        shot("19_mcp_list_A", app)
        log("flow5 global entries listed: ui-docs-http=\(app.staticTexts["ui-docs-http"].exists) ui-local-http=\(app.staticTexts["ui-local-http"].exists)")
        log("flow5 MCP list: rows labels=\(app.cells.allElementsBoundByIndex.map { $0.label })")
        log("flow5 MCP list shows toggles=\(app.switches.count) enable toggles")
        let footer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'sent when a session'")).firstMatch
        log("flow5 footer copy visible=\(footer.exists) text=\"\(footer.label)\"")
        let tree = app.debugDescription
        log("flow5 header secret value present in MCP tree: \(tree.contains("UI-SECRET-HDR-7721"))")
        log("flow5 token A present in MCP tree: \(tree.contains(token(for: a)))")
        log("flow5 Add button enabled=\(app.buttons["Add"].isEnabled)")
        app.buttons["Add"].firstMatch.tap()
        let editorNav = app.navigationBars["Add MCP server"]
        log("flow5 MCP editor opened=\(editorNav.waitForExistence(timeout: 8))")
        shot("20_mcp_editor_new", app)
        app.buttons["Cancel"].firstMatch.tap()
        log("flow5 editor cancel dismissed=\(waitGone(editorNav))")
        popBack(app)
        _ = app.buttons["settingsMCPServers"].waitForExistence(timeout: 5)
        log("flow5 back to Settings root: MCP row value=\"\(app.buttons["settingsMCPServers"].label)\"")

        // Flow 6: Agent section (gateway only).
        log("flow6 Agent section visible with gateway A selected=\(app.buttons["settingsClaudeConnections"].exists)")
        if app.buttons["settingsClaudeConnections"].exists {
            app.buttons["settingsClaudeConnections"].tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 8)
            shot("21_claude_connections", app)
            log("flow6 Claude connections nav bars=\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })")
            // Scope to the sheet's own nav bar: the Settings root's Close button is in the tree behind the sheet.
            let sheetBar = app.navigationBars["Connections"]
            let done = sheetBar.buttons["Done"]
            if done.exists { done.tap(); log("flow6 Claude connections dismissed by its Done button") } else { log("flow6 Claude connections: no Done button in its nav bar") }
            _ = sheetBar.waitForExistence(timeout: 1)
            log("flow6 Claude connections sheet still open after Done=\(sheetBar.exists)")
            shot("22_after_claude_connections", app)
        }
        if app.buttons["settingsGitCredentials"].exists {
            app.buttons["settingsGitCredentials"].tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 8)
            shot("23_git_credentials", app)
            log("flow6 Git credentials nav bars=\(app.navigationBars.allElementsBoundByIndex.map { $0.identifier })")
            popBack(app)
            _ = app.buttons["settingsGitCredentials"].waitForExistence(timeout: 5)
            log("flow6 Git credentials back to root=\(app.buttons["settingsGitCredentials"].exists)")
        }

        // App section.
        log("flow6 App: Send Feedback row=\(app.buttons["settingsSendFeedback"].exists) notification row texts=\(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'notif'")).allElementsBoundByIndex.map { $0.label })")
        shot("24_app_section", app)

        // Developer section: logging on, share, delete (cancel), off.
        let devSwitch = app.switches["settingsDeveloperMode"]
        log("flow6 developer mode switch exists=\(devSwitch.exists) value=\(devSwitch.value ?? "nil")")
        if devSwitch.exists { devSwitch.tap() }
        let logSwitch = app.switches["settingsCodexSessionLogging"]
        log("flow6 codex logging switch exists=\(logSwitch.exists)")
        if logSwitch.exists { logSwitch.tap() }
        _ = app.buttons["settingsShareSessionLogs"].waitForExistence(timeout: 5)
        log("flow6 after enabling logging: share row=\(app.buttons["settingsShareSessionLogs"].exists) delete row=\(app.buttons["settingsDeleteAllLogs"].exists)")
        shot("25_developer_logging_on", app)
        if app.buttons["settingsShareSessionLogs"].exists {
            app.buttons["settingsShareSessionLogs"].tap()
            _ = app.staticTexts["No log files found."].waitForExistence(timeout: 8)
            log("flow6 share logs: 'No log files found.' visible=\(app.staticTexts["No log files found."].exists) share sheet=\(app.sheets.count)")
            shot("26_share_logs_result", app)
            if app.sheets.firstMatch.exists { app.sheets.firstMatch.buttons.firstMatch.tap(); log("flow6 dismissed share sheet") }
        }
        if app.buttons["settingsDeleteAllLogs"].exists {
            app.buttons["settingsDeleteAllLogs"].tap()
            let alert = app.alerts["Delete All Logs?"]
            log("flow6 delete logs alert shown=\(alert.waitForExistence(timeout: 8))")
            shot("27_delete_logs_alert", app)
            if alert.exists { alert.buttons["Cancel"].tap(); log("flow6 delete logs: cancelled") }
        }
        if logSwitch.exists { logSwitch.tap() }
        if devSwitch.exists { devSwitch.tap() }
        shot("28_developer_restored", app)
        closeSettings(app)
    }

    // MARK: - Flow 7: navigation and reopen

    func testD_NavigationAndReopen() throws {
        guard let a = gatewayA else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")

        ensureSaved(app, a, shotPrefix: "pre_A")
        // Push and pop each pushed screen.
        connectionRow(host: a.host, app).tap()
        log("flow7 detail A pushed=\(app.buttons["settingsEditConnection"].waitForExistence(timeout: 8))")
        popBack(app)
        log("flow7 back from detail A to root=\(app.buttons["settingsAddConnection"].waitForExistence(timeout: 8))")

        app.buttons["settingsAddConnection"].tap()
        let nameField = app.textFields["ServerNameField"]
        log("flow7 add sheet presented=\(nameField.waitForExistence(timeout: 8))")
        app.buttons["Cancel"].firstMatch.tap()
        log("flow7 add sheet cancel closed=\(waitGone(nameField))")

        if app.buttons["settingsMCPServers"].exists {
            app.buttons["settingsMCPServers"].tap()
            _ = app.navigationBars["MCP servers"].waitForExistence(timeout: 8)
            popBack(app)
            log("flow7 back from MCP screen to root=\(app.buttons["settingsMCPServers"].waitForExistence(timeout: 8))")
        }

        // Open a detail, then close Settings from the detail: the sheet should close and reopen at the root.
        connectionRow(host: a.host, app).tap()
        _ = app.buttons["settingsEditConnection"].waitForExistence(timeout: 8)
        let close = app.buttons["settingsCloseButton"]
        log("flow7 close button visible on detail screen=\(close.exists)")
        if close.exists {
            close.tap()
        } else {
            popBack(app)
            _ = app.buttons["settingsCloseButton"].waitForExistence(timeout: 5)
            app.buttons["settingsCloseButton"].tap()
        }
        log("flow7 settings closed=\(waitGone(app.buttons["settingsCloseButton"]))")
        shot("29_after_close_from_detail", app)

        let reopened = openSettings(app)
        log("flow7 reopened via \(reopened ?? "NONE")")
        log("flow7 reopened at root (connection rows visible, detail not)=\(connectionRow(host: a.host, app).exists && !app.buttons["settingsEditConnection"].exists)")
        shot("30_reopened_root", app)
        closeSettings(app)
    }

    // MARK: - Flow 1 in dark mode (run after the simulator is set to dark)

    func testE_DarkModeRootAndDetail() throws {
        guard gatewayA != nil else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")
        if let a = gatewayA { ensureSaved(app, a, shotPrefix: "pre_A") }
        shot("31_dark_root", app)
        if let a = gatewayA, connectionRow(host: a.host, app).waitForExistence(timeout: 8) {
            connectionRow(host: a.host, app).tap()
            _ = app.buttons["settingsEditConnection"].waitForExistence(timeout: 8)
            shot("32_dark_detail", app)
            popBack(app)
        }
        closeSettings(app)
    }

    // MARK: - Flow 8: large text and landscape (run after the content size is set)

    func testF_LargeTextAndLandscape() throws {
        guard gatewayA != nil else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")
        if let a = gatewayA { ensureSaved(app, a, shotPrefix: "pre_A") }
        shot("33_xxxl_root", app)
        reportOverflow("xxxl portrait", app)
        log("flow8 close button label=\"\(app.buttons["settingsCloseButton"].label)\" frame=\(app.buttons["settingsCloseButton"].frame)")

        XCUIDevice.shared.orientation = .landscapeLeft
        _ = app.buttons["settingsCloseButton"].waitForExistence(timeout: 5)
        shot("34_xxxl_landscape_root", app)
        reportOverflow("xxxl landscape", app)
        if let a = gatewayA, connectionRow(host: a.host, app).waitForExistence(timeout: 8) {
            connectionRow(host: a.host, app).tap()
            _ = app.buttons["settingsEditConnection"].waitForExistence(timeout: 8)
            shot("35_xxxl_landscape_detail", app)
            reportOverflow("xxxl landscape detail", app)
            popBack(app)
        }
        XCUIDevice.shared.orientation = .portrait
        closeSettings(app)
    }

    /// Checks what the Edit form loads as the working directory for a connection saved with an empty one.
    /// Cancels the edit, so nothing is saved.
    func testG_EditFormWorkingDirectory() throws {
        guard let a = gatewayA else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        XCTAssertNotNil(openSettings(app), "Settings should open")
        ensureSaved(app, a, shotPrefix: "pre_A")
        connectionRow(host: a.host, app).tap()
        XCTAssertTrue(app.buttons["settingsEditConnection"].waitForExistence(timeout: 8))
        app.buttons["settingsEditConnection"].tap()
        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "edit sheet should open")
        // The field sits below the fold of the form: scroll until it is in the tree.
        var wd = app.textFields["Working directory"]
        for _ in 0..<5 where !wd.exists {
            app.swipeUp()
            wd = app.textFields["Working directory"]
        }
        if !wd.exists { wd = app.textViews["Working directory"] }
        log("flow4-wd edit form for A: working directory field exists=\(wd.exists) value=\"\((wd.value as? String) ?? "")\" placeholder=\"\(wd.placeholderValue ?? "")\"")
        shot("40_edit_form_A_working_directory", app)
        app.buttons["Cancel"].firstMatch.tap()
        log("flow4-wd edit cancelled without saving: sheet closed=\(waitGone(nameField, 10))")
    }

    /// Diagnostic: dumps the accessibility tree at the root and after opening the drawer, to find the Settings entry.
    func testZ_DumpRootAndDrawerTree() throws {
        guard gatewayA != nil else { throw XCTSkip("gateway A not configured") }
        let app = XCUIApplication()
        app.launch()
        _ = app.buttons["moreMenuButton"].firstMatch.waitForExistence(timeout: 20)
        shot("z1_root", app)
        dumpTree("tree_root.txt", app)
        let drawer = app.buttons["drawerMenuButton"].firstMatch
        log("z drawer button exists=\(drawer.exists)")
        if drawer.exists { drawer.tap() }
        _ = app.buttons["sidebarAvatarButton"].waitForExistence(timeout: 5)
        log("z after drawer tap: sidebarAvatarButton exists=\(app.buttons["sidebarAvatarButton"].exists)")
        shot("z2_after_drawer", app)
        dumpTree("tree_drawer.txt", app)

        // Close the drawer, then open the More menu on the root and dump what it offers.
        if app.buttons["Select server"].firstMatch.exists == false { log("z select server pill not found") }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        _ = waitGone(app.buttons["sidebarAvatarButton"], 3)
        let more = app.buttons["moreMenuButton"].firstMatch
        log("z more exists=\(more.exists) hittable=\(more.isHittable) frame=\(more.frame)")
        more.tap()
        _ = app.buttons["Settings"].firstMatch.waitForExistence(timeout: 4)
        log("z after More tap: Settings item exists=\(app.buttons["Settings"].firstMatch.exists) menuItems=\(app.menuItems.allElementsBoundByIndex.map { $0.label })")
        shot("z3_more_menu", app)
        dumpTree("tree_more.txt", app)
    }

    private func dumpTree(_ name: String, _ app: XCUIApplication) {
        guard let dir = env["ACPCODE_UI_SHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        log("tree dumped to \(name)")
    }

    private func reportOverflow(_ label: String, _ app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        var clipped: [String] = []
        for element in app.descendants(matching: .any).allElementsBoundByIndex where !element.identifier.isEmpty && element.identifier.hasPrefix("settings") {
            let f = element.frame
            if f.maxX > window.maxX + 0.5 || f.minX < window.minX - 0.5 {
                clipped.append("\(element.identifier) frame=\(f)")
            }
        }
        log("overflow check \(label): window=\(window) clipped=\(clipped)")
    }
}
