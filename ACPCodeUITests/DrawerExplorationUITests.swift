import XCTest

/// Exploration of the iOS drawer, the Projects view and the all-sessions list (branch test/ui-drawer).
///
/// Needs two throwaway gateways on loopback. The test skips itself unless ACPCODE_UI_GATEWAY_URL is set,
/// so a normal test run is unaffected. Environment:
/// - ACPCODE_UI_GATEWAY_URL: any value turns the test on (the gateway on 127.0.0.1:18411).
/// - ACPCODE_UI_TOKENS_FILE: a file with TOKEN_A=... and TOKEN_B=... lines (test values only).
/// - ACPCODE_UI_SHOT_DIR: where PNG screenshots and flow-log.txt are written.
/// Every check prints a `FLOW|` line; the same lines are attached to the result bundle.
@MainActor
final class DrawerExplorationUITests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    private var lines: [String] = []

    private let nameA = "Gateway A"
    private let nameB = "Gateway B"
    private let hostA = "127.0.0.1:18411"
    private let hostB = "127.0.0.1:18412"
    private let promptAlpha = "ui drawer alpha one"
    private let promptBeta = "ui drawer beta one"
    private let promptGamma = "ui drawer gamma one"

    private var shotDir: URL? {
        env["ACPCODE_UI_SHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard env["ACPCODE_UI_GATEWAY_URL"] != nil else {
            throw XCTSkip("Needs the throwaway gateways: set ACPCODE_UI_GATEWAY_URL, ACPCODE_UI_TOKENS_FILE and ACPCODE_UI_SHOT_DIR.")
        }
    }

    override func tearDownWithError() throws {
        let text = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "flow-log"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            try? text.write(to: dir.appendingPathComponent("flow-log.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Flows

    func testDrawerExploration() throws {
        guard let tokens = readTokens() else {
            throw XCTSkip("ACPCODE_UI_TOKENS_FILE is missing or has no TOKEN_A/TOKEN_B lines.")
        }

        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            for label in ["Not Now", "Allow", "OK", "Continue"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // F1: cold launch, no server.
        _ = waitForAny([element("emptyStateAddServerButton"), app.buttons["drawerMenuButton"]], timeout: 25)
        pause(1)
        shot("01_cold_launch")
        note("F1", "emptyAdd=\(element("emptyStateAddServerButton").exists) drawerMenu=\(app.buttons["drawerMenuButton"].exists) projectsRow=\(element("sidebarProjectsRow").exists) drawerOpenNow=\(isDrawerOpen())")

        // F2: add gateway A through the real Add Server form.
        let emptyAdd = element("emptyStateAddServerButton")
        if emptyAdd.waitForExistence(timeout: 3) {
            emptyAdd.tap()
        } else {
            openConnectionMenu(named: nameA)
            app.buttons["addACPServerMenuAction"].tap()
        }
        let addedA = addServer(name: nameA, host: hostA, token: tokens.a, flow: "F2")
        record("F2", addedA, "gateway A saved and connected (home or drawer control visible)")
        shot("02_gateway_a_connected")

        openDrawer()
        shot("03_drawer_open_gateway_a")
        record("F2", isDrawerOpen(), "drawer opens from drawerMenuButton and shows Projects row")
        note("F2", "gatewayProject sections=\(elements(prefix: "gatewayProject.").count) gatewaySession rows=\(elements(prefix: "gatewaySession.").count) projectRow(main)=\(elements(prefix: "projectRow.").count)")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        pause(0.9)
        shot("04_after_scrim_tap")
        record("F2", !isDrawerOpen(), "tapping the scrim closes the drawer")

        dragFromLeftEdge()
        pause(1)
        shot("05_edge_drag_open")
        record("F2", isDrawerOpen(), "left-edge drag (x=2% of width) opens the drawer")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        pause(1)
        shot("06_drag_left_close")
        record("F2", !isDrawerOpen(), "drag left on the open drawer closes it")

        // F3: Projects view from the drawer.
        openDrawer()
        element("sidebarProjectsRow").tap()
        let newProjectButton = element("projectsNewProjectButton")
        record("F3", newProjectButton.waitForExistence(timeout: 10), "Projects view shows the floating New project button")
        pause(0.6)
        shot("07_projects_view")
        let projectRows = elements(prefix: "projectRow.")
        note("F3", "project rows=\(projectRows.count) labels=\(labels(projectRows))")
        if projectRows.count > 0 {
            let last = projectRows.element(boundBy: projectRows.count - 1)
            note("F3", "top: button \(frameText(newProjectButton)) lastRow \(frameText(last))")
            scrollToBottom()
            pause(0.6)
            let stillOverlaps = last.frame.intersects(newProjectButton.frame)
            note("F3", "bottom: button \(frameText(newProjectButton)) lastRow \(frameText(last)) overlap=\(stillOverlaps)")
            shot("08_projects_scrolled_bottom")
            record("F3", !stillOverlaps, "floating New project button does not cover the last project row when scrolled to the end")
            scrollToTop()
        }

        let alpha = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "projectRow.", "project-alpha")).firstMatch
        if alpha.waitForExistence(timeout: 3) {
            alpha.tap()
        }
        let projectNewSession = element("projectNewSessionButton")
        record("F3", projectNewSession.waitForExistence(timeout: 10), "tapping project-alpha opens project detail with New session")
        pause(0.5)
        shot("09_project_detail_empty")
        record("F3", app.staticTexts["No sessions yet"].exists, "project with no sessions shows the 'No sessions yet' empty state")

        // F4: new session from the project, prompt, answer, navigation closes the drawer.
        let rowsBeforeProjectSession = elements(prefix: "gatewaySession.").count
        projectNewSession.tap()
        let createButton = app.buttons["gatewayCreateSession"]
        record("F4", createButton.waitForExistence(timeout: 8), "New session sheet opens from project detail")
        shot("10_new_session_sheet_from_project")
        createButton.tap()
        sendPrompt(promptAlpha, flow: "F4", shotName: "11_session_answered_alpha")
        returnHome()
        openDrawer()
        shot("12_drawer_after_project_session")
        let rowsAfterProjectSession = elements(prefix: "gatewaySession.").count
        record("F4", rowsAfterProjectSession == rowsBeforeProjectSession + 1, "drawer lists the new session once (rows \(rowsBeforeProjectSession) -> \(rowsAfterProjectSession))")
        note("F4", "gatewaySession labels=\(labels(elements(prefix: "gatewaySession.")))")

        // F4b: new session from the drawer's New session button, into project-beta.
        app.buttons["newSessionButton"].tap()
        let createFromDrawer = app.buttons["gatewayCreateSession"]
        record("F4", createFromDrawer.waitForExistence(timeout: 8), "New session button in the drawer opens the new-session sheet")
        pickProject(containing: "project-beta")
        shot("13_new_session_sheet_from_drawer")
        createFromDrawer.tap()
        sendPrompt(promptBeta, flow: "F4b", shotName: "14_session_answered_beta")
        returnHome()
        openDrawer()
        record("F4", elements(prefix: "gatewaySession.").count == rowsAfterProjectSession + 1, "drawer lists the drawer-created session once")

        // F5: second connection B. Create a session there, then go back to A and look at the all-sessions list.
        openConnectionMenu(named: nameA)
        app.buttons["addACPServerMenuAction"].tap()
        let addedB = addServer(name: nameB, host: hostB, token: tokens.b, flow: "F5")
        record("F5", addedB, "gateway B saved and connected")
        shot("15_gateway_b_connected")
        openDrawer()
        app.buttons["newSessionButton"].tap()
        let createOnB = app.buttons["gatewayCreateSession"]
        _ = createOnB.waitForExistence(timeout: 8)
        pickProject(containing: "project-gamma")
        createOnB.tap()
        sendPrompt(promptGamma, flow: "F5", shotName: "16_session_answered_on_b")
        returnHome()

        openConnectionMenu(named: nameB)
        let switchToA = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", nameA)).firstMatch
        if switchToA.waitForExistence(timeout: 5) { switchToA.tap() } else { note("F5", "FAIL no menu item for gateway A") }
        _ = waitForAny([element("sidebarProjectsRow"), app.buttons["drawerMenuButton"]], timeout: 45)
        pause(1)
        openDrawer()
        shot("17_drawer_on_a_all_sessions")

        let allRows = elements(prefix: "allSessionRow_")
        let allIds = (0..<allRows.count).map { allRows.element(boundBy: $0).identifier }
        note("F5", "all-session rows=\(allRows.count) uniqueIds=\(Set(allIds).count)")
        for index in 0..<allRows.count {
            let row = allRows.element(boundBy: index)
            note("F5", "row[\(index)] id=\(row.identifier) label=\(row.label) frame=\(frameText(row))")
        }
        record("F5", app.staticTexts["Other connections"].exists || allRows.count > 0, "Other connections section present on connection A")
        let rowsForB = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "allSessionRow_", nameB))
        record("F5", rowsForB.count >= 1, "a session from connection B is listed while A is selected (count \(rowsForB.count))")
        let rowsForAHome = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "allSessionRow_", nameA))
        note("F5", "rows labelled with A while A is selected: \(rowsForAHome.count)")
        record("F5", uniqueCount(allIds) == allIds.count, "no session row is listed twice (identifiers unique)")

        // F5: tap the B row.
        if rowsForB.count >= 1 {
            rowsForB.element(boundBy: 0).tap()
            let echoOnB = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "echo: \(promptGamma)")).firstMatch
            record("F5", echoOnB.waitForExistence(timeout: 30), "tapping the B row switches to connection B and opens that session")
            pause(0.8)
            shot("18_after_tap_row_b")
            record("F5", !isDrawerOpen(), "drawer closes after tapping a row from another connection")
        }

        // F6: left-edge drag with a session open.
        let composerBefore = app.textViews.firstMatch.exists
        dragFromLeftEdge()
        pause(1)
        let drawerAfterEdge = isDrawerOpen()
        let composerAfterEdge = app.textViews.firstMatch.exists
        note("F6", "composerBefore=\(composerBefore) drawerOpenedByEdge=\(drawerAfterEdge) composerAfterEdge=\(composerAfterEdge) navButtons=\(app.navigationBars.buttons.count)")
        shot("19_edge_drag_in_session")
        record("F6", drawerAfterEdge && composerAfterEdge, "left-edge drag with a session open opens the drawer and keeps the session (not popped)")
        closeDrawer()

        // F7: landscape drawer.
        openDrawer()
        XCUIDevice.shared.orientation = .landscapeLeft
        pause(1.5)
        shot("20_landscape_drawer")
        let rowInLandscape = element("sidebarProjectsRow")
        note("F7", "app frame \(frameText(app)) projectsRow \(frameText(rowInLandscape)) drawerOpen=\(isDrawerOpen())")
        closeDrawer()
        pause(0.6)
        shot("21_landscape_main")
        XCUIDevice.shared.orientation = .portrait
        pause(1)

        // F8: accessibility labels for the controls the drawer uses.
        openDrawer()
        note("F8", "drawerMenuButton label=\(app.buttons["drawerMenuButton"].label)")
        note("F8", "sidebarProjectsRow label=\(element("sidebarProjectsRow").label)")
        note("F8", "newSessionButton label=\(app.buttons["newSessionButton"].label) newSessionMenuButton label=\(app.buttons["newSessionMenuButton"].label)")
        let firstAll = elements(prefix: "allSessionRow_").firstMatch
        if firstAll.exists {
            note("F8", "first all-session row label=\(firstAll.label)")
        }
        shot("22_final_drawer")
        closeDrawer()
    }

    // MARK: - Steps

    /// Fills the Add Server form and saves. Returns true when the server is connected (a control of the main screen shows).
    private func addServer(name: String, host: String, token: String, flow: String) -> Bool {
        let nameField = app.textFields["ServerNameField"]
        guard nameField.waitForExistence(timeout: 10) else {
            note(flow, "FAIL no ServerNameField")
            return false
        }
        replaceText(in: nameField, with: name)

        let localOnly = app.switches["LocalOnlyToggle"]
        if localOnly.waitForExistence(timeout: 3), (localOnly.value as? String) != "1" {
            localOnly.tap()
        }
        let wsButton = app.segmentedControls["ProtocolPicker"].buttons["ws"]
        if wsButton.waitForExistence(timeout: 2) {
            wsButton.tap()
        }

        let hostField = app.textFields["HostField"]
        if hostField.waitForExistence(timeout: 5) {
            replaceText(in: hostField, with: host)
        }

        // The token is a SecureField; the form has no other secure field, so take the first one.
        let tokenField = app.secureTextFields.firstMatch
        if tokenField.waitForExistence(timeout: 3) {
            tokenField.tap()
            tokenField.typeText(token)
        } else {
            note(flow, "no bearer token field found; secure fields=\(app.secureTextFields.count) text fields=\(app.textFields.count)")
        }

        let save = app.buttons["saveToolbarButton"].exists ? app.buttons["saveToolbarButton"] : app.buttons["SaveServerButton"]
        guard save.waitForExistence(timeout: 8) else {
            note(flow, "FAIL no save button")
            return false
        }
        _ = waitForEnabled(save, timeout: 8)
        save.tap()

        let acknowledge = app.buttons["serverSummaryConfirmButton"].exists
            ? app.buttons["serverSummaryConfirmButton"]
            : app.buttons["Acknowledge and Add"]
        if acknowledge.waitForExistence(timeout: 20) {
            shot("summary_\(flow)_\(name.replacingOccurrences(of: " ", with: "_"))")
            acknowledge.tap()
        } else {
            note(flow, "no summary overlay appeared")
        }

        // The iOS "Save Password?" sheet can cover the app after the form is saved: decline it.
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 6) {
            note(flow, "Save Password sheet shown; tapping Not Now")
            notNow.tap()
            pause(1)
        }

        // A failed connection shows an alert ("Unable to Add Server"): report it and dismiss it.
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 8) {
            note(flow, "ALERT \(alert.label): \(alert.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " | "))")
            shot("alert_\(flow)_\(name.replacingOccurrences(of: " ", with: "_"))")
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
            return false
        }

        // Connected means the main screen's own controls appear, not the toolbar (which shows on the failed form too).
        return waitForAny([
            element("sidebarProjectsRow"),
            element("projectsNewProjectButton"),
            app.buttons["newSessionButton"],
        ], timeout: 60)
    }

    /// Types a prompt into the open session's composer, sends it, and waits for the fake agent's echo.
    private func sendPrompt(_ prompt: String, flow: String, shotName: String) {
        let composer = app.textViews.firstMatch
        record(flow, composer.waitForExistence(timeout: 30), "session detail with composer is open")
        composer.tap()
        composer.typeText(prompt)
        let send = app.buttons["Send message"]
        if send.waitForExistence(timeout: 10) {
            _ = waitForEnabled(send, timeout: 10)
            send.tap()
        } else {
            note(flow, "FAIL no 'Send message' button")
        }
        let echo = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "echo: \(prompt)")).firstMatch
        record(flow, echo.waitForExistence(timeout: 45), "fake agent answers 'echo: \(prompt)'")
        pause(1)
        shot(shotName)
        note(flow, "drawerOpenAfterNavigation=\(isDrawerOpen())")
    }

    private func pickProject(containing text: String) {
        let choice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "gatewayProjectChoice.", text)).firstMatch
        if choice.waitForExistence(timeout: 4) {
            choice.tap()
        } else {
            note("PICK", "no project choice containing \(text); labels=\(labels(elements(prefix: "gatewayProjectChoice.")))")
        }
    }

    /// Goes back through the navigation stack until the drawer's menu button is on screen (max 4 steps).
    private func returnHome() {
        for _ in 0..<4 {
            let menu = app.buttons["drawerMenuButton"]
            if menu.exists && menu.isHittable { return }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable, !back.label.contains("Gateway") else { return }
            back.tap()
            pause(0.7)
        }
    }

    private func openDrawer() {
        if isDrawerOpen() { return }
        let menu = app.buttons["drawerMenuButton"]
        if menu.waitForExistence(timeout: 5) {
            menu.tap()
        } else {
            note("DRAWER", "FAIL drawerMenuButton not found")
        }
        _ = element("sidebarProjectsRow").waitForExistence(timeout: 5)
        pause(0.7)
    }

    private func closeDrawer() {
        guard isDrawerOpen() else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        pause(0.8)
    }

    private func isDrawerOpen() -> Bool {
        let row = element("sidebarProjectsRow")
        return row.exists && row.isHittable
    }

    private func dragFromLeftEdge() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
    }

    /// Opens the principal connection menu (the navigation title button that shows `currentName`).
    private func openConnectionMenu(named currentName: String) {
        let byNav = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", currentName)).firstMatch
        if byNav.waitForExistence(timeout: 4) {
            byNav.tap()
        } else {
            let anywhere = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", currentName)).firstMatch
            if anywhere.waitForExistence(timeout: 3) { anywhere.tap() } else { note("MENU", "FAIL no connection menu for \(currentName)") }
        }
        pause(0.6)
    }

    private func scrollToBottom() {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<4 { list.swipeUp() }
    }

    private func scrollToTop() {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<4 { list.swipeDown() }
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elements(prefix: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func labels(_ query: XCUIElementQuery) -> [String] {
        (0..<query.count).map { query.element(boundBy: $0).label }
    }

    private func uniqueCount(_ values: [String]) -> Int {
        Set(values).count
    }

    private func frameText(_ element: XCUIElement) -> String {
        let f = element.frame
        return "x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))"
    }

    private func readTokens() -> (a: String, b: String)? {
        guard let path = env["ACPCODE_UI_TOKENS_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let a = values["TOKEN_A"], let b = values["TOKEN_B"] else { return nil }
        return (a, b)
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.tap()
        if let existing = element.value as? String, !existing.isEmpty, existing != element.placeholderValue {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        element.typeText(value)
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true && enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAny(_ candidates: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if candidates.contains(where: { $0.exists }) { return true }
            pause(0.25)
        } while Date() < deadline
        return false
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func note(_ flow: String, _ text: String) {
        let line = "FLOW|\(flow)|\(text)"
        lines.append(line)
        print(line)
    }

    private func record(_ flow: String, _ pass: Bool, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        note(flow, "\(pass ? "PASS" : "FAIL") \(text)")
        if !pass {
            XCTFail("\(flow): \(text)", file: file, line: line)
        }
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
        note("SHOT", name)
    }
}
