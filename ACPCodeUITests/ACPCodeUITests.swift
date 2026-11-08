import XCTest

final class ACPCodeUITests: XCTestCase {

    private enum E2E {
        static let enabledEnv = "ACPCODE_E2E_CODEX_ENABLED"
        static let endpointEnv = "ACPCODE_E2E_CODEX_ENDPOINT"
        static let hostEnv = "ACPCODE_E2E_CODEX_HOST"
        static let promptEnv = "ACPCODE_E2E_CODEX_PROMPT"
        static let configPathEnv = "ACPCODE_E2E_CODEX_CONFIG_PATH"
        static let defaultConfigPath = "/tmp/acpcode_codex_e2e_config.env"
        static let defaultPrompt = "hello from codex e2e"
        static let emptyStateAddServerButtonId = "emptyStateAddServerButton"
        static let saveToolbarButtonId = "saveToolbarButton"
        static let summaryConfirmButtonId = "serverSummaryConfirmButton"
        static let promptEditorId = "codexPromptEditor"
        static let sendButtonId = "codexSendButton"
        static let assistantBubbleId = "codexAssistantBubble"
        static let thinkingBubbleId = "codexThinkingBubble"
        static let systemBubbleId = "codexSystemBubble"
    }

    private struct CodexE2EConfiguration {
        let scheme: String
        let host: String
        let serverName: String
        let prompt: String
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    @MainActor
    func testCodexDirectWebSocketConnectInitializeAndSessionFlow() throws {
        let config = try codexE2EConfiguration()
        let app = XCUIApplication()

        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            let allowButtons = ["Allow", "OK", "Continue", "允许"]
            for label in allowButtons where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()

        let addServerButton = app.buttons[E2E.emptyStateAddServerButtonId]
        XCTAssertTrue(
            addServerButton.waitForExistence(timeout: 20),
            "Expected clean first-run server list state. Ensure pre-run uninstall happened. UI:\n\(app.debugDescription)"
        )
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        replaceText(in: nameField, with: config.serverName)

        // Explicitly pick Codex mode.
        if app.buttons["ServerTypeCodex"].waitForExistence(timeout: 3) {
            app.buttons["ServerTypeCodex"].tap()
        } else {
            let picker = app.segmentedControls["ServerTypePicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 6))
            picker.buttons.element(boundBy: 1).tap()
        }

        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons[config.scheme].exists {
            protocolPicker.buttons[config.scheme].tap()
        }

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8))
        replaceText(in: hostField, with: config.host)

        // Prefer the navigation bar action because Form rows can be virtualized off-screen.
        let toolbarSaveButton = app.buttons[E2E.saveToolbarButtonId].exists ? app.buttons[E2E.saveToolbarButtonId] : app.navigationBars.buttons["Save"]
        if toolbarSaveButton.waitForExistence(timeout: 8) {
            XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 8))
            toolbarSaveButton.tap()
        } else {
            let inlineSaveButton = app.buttons["SaveServerButton"]
            XCTAssertTrue(inlineSaveButton.waitForExistence(timeout: 8))
            XCTAssertTrue(waitForEnabled(inlineSaveButton, timeout: 8))
            inlineSaveButton.tap()
        }
        app.tap()

        // Validation summary overlay confirmation.
        let acknowledgeButton = app.buttons[E2E.summaryConfirmButtonId].exists ? app.buttons[E2E.summaryConfirmButtonId] : app.buttons["Acknowledge and Add"]
        XCTAssertTrue(acknowledgeButton.waitForExistence(timeout: 45))
        acknowledgeButton.tap()

        // Wait until app is connected+initialized enough to allow creating a session.
        let newSessionButton = app.buttons["newSessionButton"].exists
            ? app.buttons["newSessionButton"]
            : app.buttons["New Session"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 45))
        XCTAssertTrue(waitForEnabled(newSessionButton, timeout: 45))
        newSessionButton.tap()

        // New session opens session detail composer.
        let composer = app.textViews[E2E.promptEditorId].exists ? app.textViews[E2E.promptEditorId] : app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        composer.tap()
        composer.typeText(config.prompt)

        let sendButton = app.buttons[E2E.sendButtonId].exists ? app.buttons[E2E.sendButtonId] : app.buttons["Send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(sendButton, timeout: 10))
        sendButton.tap()

        // User message should appear in transcript quickly.
        let messagePredicate = NSPredicate(format: "label CONTAINS[c] %@", config.prompt)
        let echoed = app.staticTexts.containing(messagePredicate).firstMatch
        XCTAssertTrue(echoed.waitForExistence(timeout: 20))

        // Verify we observed server-side progress (assistant content or active thinking state).
        let anyElement = app.descendants(matching: .any)
        let assistantBubble = anyElement.matching(identifier: E2E.assistantBubbleId).firstMatch
        let thinkingBubble = anyElement.matching(identifier: E2E.thinkingBubbleId).firstMatch
        let systemBubble = anyElement.matching(identifier: E2E.systemBubbleId).firstMatch
        XCTAssertTrue(waitForAny([assistantBubble, thinkingBubble, systemBubble], timeout: 45))
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        element.tap()

        if let existingValue = element.value as? String, !existingValue.isEmpty {
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count)
            element.typeText(deleteSequence)
        }

        element.typeText(value)
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true && enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return elements.contains(where: { $0.exists })
    }

    private func codexE2EConfiguration() throws -> CodexE2EConfiguration {
        let env = mergedCodexE2EEnvironment()

        guard isTruthy(env[E2E.enabledEnv]) else {
            throw XCTSkip(
                """
                Codex E2E is disabled by default. Set \(E2E.enabledEnv)=1 and provide either \
                \(E2E.endpointEnv)=ws://127.0.0.1:8788 or \(E2E.hostEnv)=127.0.0.1:8788 after starting codex app-server. \
                You can also provide these values via \(E2E.defaultConfigPath).
                """
            )
        }

        let parsed: (scheme: String, host: String)?
        if let endpoint = env[E2E.endpointEnv], !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed = parseEndpoint(endpoint)
        } else if let host = env[E2E.hostEnv], !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parsed = parseEndpoint(host)
        } else {
            parsed = nil
        }

        guard let parsed else {
            throw XCTSkip("Missing Codex endpoint. Set \(E2E.endpointEnv) or \(E2E.hostEnv).")
        }

        let prompt = env[E2E.promptEnv]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? env[E2E.promptEnv]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : E2E.defaultPrompt

        let serverName = "Codex Local E2E \(UUID().uuidString.prefix(8))"
        return CodexE2EConfiguration(
            scheme: parsed.scheme,
            host: parsed.host,
            serverName: serverName,
            prompt: prompt
        )
    }

    private func parseEndpoint(_ rawValue: String) -> (scheme: String, host: String)? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            guard
                let components = URLComponents(string: trimmed),
                let host = components.host,
                let scheme = components.scheme?.lowercased(),
                scheme == "ws" || scheme == "wss"
            else {
                return nil
            }
            let hostWithPort = components.port.map { "\(host):\($0)" } ?? host
            return (scheme: scheme, host: hostWithPort)
        }

        let host = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { return nil }
        return (scheme: "ws", host: host)
    }

    private func mergedCodexE2EEnvironment() -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        let configPath = processEnvironment[E2E.configPathEnv] ?? E2E.defaultConfigPath
        let fileEnvironment = loadConfigFileEnvironment(at: configPath)
        return fileEnvironment.merging(processEnvironment) { _, processValue in
            processValue
        }
    }

    private func loadConfigFileEnvironment(at path: String) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }

            values[key] = value
        }

        return values
    }

    private func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y":
            return true
        default:
            return false
        }
    }
}
