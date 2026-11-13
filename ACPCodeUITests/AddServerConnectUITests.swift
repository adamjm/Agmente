import XCTest

/// Add Server must connect the new gateway after "Acknowledge and Add", then load its projects and sessions.
///
/// Skipped unless `ACPCODE_UI_GATEWAY_URL` (host:port of a running gateway) is set. The bearer token is read
/// from the file named by `ACPCODE_UI_GATEWAY_TOKEN_FILE`, so it never appears in the source or the command line.
/// The gateway's audit log (`ACPCODE_UI_GATEWAY_LOG`) is polled for the connect and the list requests.
final class AddServerConnectUITests: XCTestCase {

    private enum Env {
        static let url = "ACPCODE_UI_GATEWAY_URL"
        static let tokenFile = "ACPCODE_UI_GATEWAY_TOKEN_FILE"
        static let logFile = "ACPCODE_UI_GATEWAY_LOG"
        static let shotDir = "ACPCODE_UI_SHOT_DIR"
    }

    private enum Needle {
        static let initialize = "\"method\":\"initialize\""
        static let projectsList = "projects/list"
        static let sessionsIndex = "sessions/index"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddServerConnectsAndLoadsGatewaySessions() throws {
        let env = ProcessInfo.processInfo.environment
        guard let hostPort = env[Env.url], !hostPort.isEmpty else {
            throw XCTSkip("Set \(Env.url) to host:port of a running gateway to run this test.")
        }
        var token = ""
        if let tokenPath = env[Env.tokenFile] {
            token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let logPath = env[Env.logFile]
        let shotDir = env[Env.shotDir]

        let app = XCUIApplication()
        app.launch()

        let addServerButton = app.buttons["emptyStateAddServerButton"]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 30), "empty state Add Server button missing")
        shot("01_empty_state", dir: shotDir)
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "server name field missing")
        nameField.tap()
        nameField.typeText("Gateway A")

        let localOnly = app.switches["LocalOnlyToggle"]
        if localOnly.waitForExistence(timeout: 5), (localOnly.value as? String) != "1" {
            localOnly.tap()
        }

        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons["ws"].exists {
            protocolPicker.buttons["ws"].tap()
        }

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8), "host field missing")
        hostField.tap()
        hostField.typeText(hostPort)

        let tokenField = app.secureTextFields["Bearer token (optional)"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5), "token field missing")
        tokenField.tap()
        tokenField.typeText(token)
        shot("02_form_filled", dir: shotDir)

        let save = app.buttons["saveToolbarButton"].exists
            ? app.buttons["saveToolbarButton"]
            : app.navigationBars.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8), "Save button missing")
        save.tap()

        let confirm = app.buttons["serverSummaryConfirmButton"]
        let summaryShown = confirm.waitForExistence(timeout: 45)
        shot("03_summary", dir: shotDir)
        XCTAssertTrue(summaryShown, "summary overlay did not appear after Save")

        let initializeBefore = gatewayCount(Needle.initialize, logPath)
        let listBefore = gatewayCount(Needle.projectsList, logPath)
        let sessionsBefore = gatewayCount(Needle.sessionsIndex, logPath)

        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Acknowledge button disappeared")
        confirm.tap()

        // iOS offers "Save Password?" after Acknowledge. Dismiss it so it does not cover the app.
        for label in ["Not Now", "Don\u{2019}t Save", "Don't Save"] where app.buttons[label].waitForExistence(timeout: 3) {
            app.buttons[label].tap()
            break
        }
        shot("04_after_acknowledge", dir: shotDir)

        // Poll the gateway log for up to 15 seconds for the connect and the first list requests.
        var initializeAfter = initializeBefore
        var listAfter = listBefore
        var sessionsAfter = sessionsBefore
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            initializeAfter = gatewayCount(Needle.initialize, logPath)
            listAfter = gatewayCount(Needle.projectsList, logPath)
            sessionsAfter = gatewayCount(Needle.sessionsIndex, logPath)
            if initializeAfter > initializeBefore, listAfter > listBefore, sessionsAfter > sessionsBefore {
                break
            }
        }
        shot("05_after_15s", dir: shotDir)

        let summary = """
        initialize \(initializeBefore) -> \(initializeAfter)
        projects/list \(listBefore) -> \(listAfter)
        sessions/index \(sessionsBefore) -> \(sessionsAfter)
        """
        let attachment = XCTAttachment(string: summary)
        attachment.name = "gateway_counts"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThan(initializeAfter, initializeBefore,
                             "no new initialize after Acknowledge and Add. \(summary)")
        XCTAssertGreaterThan(listAfter, listBefore,
                             "no new projects/list after Acknowledge and Add. \(summary)")
        XCTAssertGreaterThan(sessionsAfter, sessionsBefore,
                             "no new sessions/index after Acknowledge and Add. \(summary)")
    }

    private func gatewayCount(_ needle: String, _ path: String?) -> Int {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "\n").filter { $0.contains(needle) }.count
    }

    private func shot(_ name: String, dir: String?) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
