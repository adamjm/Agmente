import XCTest
import ACP
@testable import ACPCode
import ACPClient

/// Model selection for ACP sessions (unstable `models` field, verify: not in upstream ACP schema).
@MainActor
final class ACPSessionModelTests: XCTestCase {

    private final class SetModelRecorder {
        var payloads: [ACPSessionSetModelPayload] = []
        var error: Error?
    }

    private struct FakeSetModelError: Error {}

    private var appendMessages: [String] = []

    private func makeViewModel(recorder: SetModelRecorder? = nil) -> ACPSessionViewModel {
        var setSessionModel: ((ACPSessionSetModelPayload) async throws -> Void)? = nil
        if let recorder {
            setSessionModel = { payload in
                recorder.payloads.append(payload)
                if let error = recorder.error {
                    throw error
                }
            }
        }
        let dependencies = ACPSessionViewModel.Dependencies(
            getService: { nil },
            append: { [weak self] message in
                self?.appendMessages.append(message)
            },
            logWire: { _, _ in },
            setSessionModel: setSessionModel
        )
        return ACPSessionViewModel(dependencies: dependencies)
    }

    /// Parses a session/new result with a `models` object, as the app does.
    private func parsedModels(sessionId: String, current: String) -> ACPSessionModelInfo? {
        let result: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "models": .object([
                "availableModels": .array([
                    .object([
                        "modelId": .string("fast"),
                        "name": .string("Fast")
                    ]),
                    .object([
                        "modelId": .string("deep"),
                        "name": .string("Deep")
                    ])
                ]),
                "currentModelId": .string(current)
            ])
        ])
        return ACPSessionResponseParser.parseSessionNew(result: result)?.models
    }

    /// Polls until the main-actor condition holds or about one second passes.
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testNewSessionModelsAreAppliedToViewModel() {
        let serverId = UUID()
        let viewModel = makeViewModel()

        viewModel.applySessionModels(parsedModels(sessionId: "s1", current: "fast"), serverId: serverId, sessionId: "s1")

        XCTAssertEqual(viewModel.availableModels.map(\.id), ["fast", "deep"])
        XCTAssertEqual(viewModel.availableModels.map(\.name), ["Fast", "Deep"])
        XCTAssertEqual(viewModel.currentModelId, "fast")
    }

    func testSetModelSendsSetModelPayloadAndUpdatesCurrentModel() async {
        let serverId = UUID()
        let recorder = SetModelRecorder()
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.applySessionModels(parsedModels(sessionId: "s1", current: "fast"), serverId: serverId, sessionId: "s1")

        viewModel.sendSetModel("deep", sessionId: "s1", serverId: serverId)
        await waitFor { viewModel.currentModelId == "deep" }

        XCTAssertEqual(recorder.payloads.count, 1)
        XCTAssertEqual(recorder.payloads.first?.sessionId, "s1")
        XCTAssertEqual(recorder.payloads.first?.modelId, "deep")
        XCTAssertEqual(viewModel.currentModelId, "deep")
        XCTAssertEqual(viewModel.cachedModels(for: serverId, sessionId: "s1")?.currentModelId, "deep")
        XCTAssertTrue(appendMessages.contains("Set model to: deep"))
    }

    func testFailedSetModelKeepsOldModelAndShowsError() async {
        let serverId = UUID()
        let recorder = SetModelRecorder()
        recorder.error = FakeSetModelError()
        let viewModel = makeViewModel(recorder: recorder)
        viewModel.applySessionModels(parsedModels(sessionId: "s1", current: "fast"), serverId: serverId, sessionId: "s1")

        viewModel.sendSetModel("deep", sessionId: "s1", serverId: serverId)
        await waitFor { self.appendMessages.contains { $0.hasPrefix("Failed to set model") } }

        XCTAssertEqual(recorder.payloads.count, 1)
        XCTAssertEqual(viewModel.currentModelId, "fast")
        XCTAssertEqual(viewModel.cachedModels(for: serverId, sessionId: "s1")?.currentModelId, "fast")
        XCTAssertTrue(appendMessages.contains { $0.hasPrefix("Failed to set model") })
    }

    func testSessionWithoutModelsShowsNoModelState() {
        let serverId = UUID()
        let viewModel = makeViewModel()
        let plain = ACPSessionResponseParser.parseSessionNew(result: .object(["sessionId": .string("plain")]))

        XCTAssertNil(plain?.models)
        viewModel.applySessionModels(plain?.models, serverId: serverId, sessionId: "plain")

        XCTAssertTrue(viewModel.availableModels.isEmpty)
        XCTAssertNil(viewModel.currentModelId)
        XCTAssertNil(viewModel.cachedModels(for: serverId, sessionId: "plain"))
    }

    func testSwitchingSessionsRestoresEachSessionsModelFromCache() {
        let serverId = UUID()
        let viewModel = makeViewModel()
        viewModel.applySessionModels(parsedModels(sessionId: "a", current: "fast"), serverId: serverId, sessionId: "a")
        viewModel.applySessionModels(parsedModels(sessionId: "b", current: "deep"), serverId: serverId, sessionId: "b")

        viewModel.restoreSessionModels(serverId: serverId, sessionId: "a")
        XCTAssertEqual(viewModel.currentModelId, "fast")
        XCTAssertEqual(viewModel.availableModels.count, 2)

        viewModel.restoreSessionModels(serverId: serverId, sessionId: "b")
        XCTAssertEqual(viewModel.currentModelId, "deep")

        viewModel.restoreSessionModels(serverId: serverId, sessionId: "never-seen")
        XCTAssertNil(viewModel.currentModelId)
        XCTAssertTrue(viewModel.availableModels.isEmpty)
    }

    func testModelConfigOptionIsPreferredAndHiddenFromGenericOptions() {
        let serverId = UUID()
        let viewModel = makeViewModel()
        let modelOption = ACPSessionConfigOption(
            id: "llm",
            name: "Model",
            category: "model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "a", name: "A")]),
            currentValue: .string("a")
        )
        let otherOption = ACPSessionConfigOption(
            id: "temperature",
            name: "Temperature",
            category: "model_config",
            kind: .boolean,
            currentValue: .bool(true)
        )

        viewModel.applySessionConfigOptions([modelOption, otherOption], serverId: serverId, sessionId: "s1")

        XCTAssertEqual(viewModel.modelConfigOption?.id, "llm")
        XCTAssertEqual(viewModel.visibleConfigOptions().map(\.id), ["temperature"])
    }
}
