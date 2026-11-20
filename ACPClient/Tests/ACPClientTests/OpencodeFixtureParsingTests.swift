import XCTest
import ACP
@testable import ACPClient

/// Parses output captured from a real `opencode acp` process (opencode 1.2.15, run on 2026-11-12
/// against a local oMLX model). The fixtures live in `Fixtures/opencode/` and hold no secrets.
/// They show the model picker form opencode uses: a `models` object on session/new, not configOptions.
final class OpencodeFixtureParsingTests: XCTestCase {

    private func fixture(_ name: String) throws -> ACP.Value {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opencode/\(name)")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ACP.Value.self, from: data)
    }

    func testSessionNewFromOpencodeOffersModelsAndModes() throws {
        let result = try fixture("session-new-result.json")

        let parsed = try XCTUnwrap(ACPSessionResponseParser.parseSessionNew(result: result))

        XCTAssertEqual(parsed.sessionId, "ses_e3338fb81ffemYNZBSDO4XZIOl")

        // Model picker form (D-112 form 2): the `models` object is parsed, with the current id.
        let models = try XCTUnwrap(parsed.models)
        XCTAssertEqual(models.currentModelId, "omlx/Qwen3.8-27B-MLX-4bit")
        XCTAssertEqual(models.availableModels.count, 11)
        let local = try XCTUnwrap(models.availableModels.first { $0.id == "omlx/Qwen3.8-27B-MLX-4bit" })
        XCTAssertEqual(local.name, "oMLX (local test)/Qwen3.8 27B 4bit (oMLX)")

        // opencode sends no configOptions, so the picker comes from `models` alone.
        XCTAssertTrue(parsed.configOptions.isEmpty)
        XCTAssertFalse(parsed.configOptions.contains { $0.isModelSelector })

        // Modes parse from the `modes` object.
        let modes = try XCTUnwrap(parsed.modes)
        XCTAssertEqual(modes.currentModeId, "build")
        XCTAssertEqual(modes.availableModes.map(\.id), ["build", "plan"])
    }

    func testInitializeFromOpencodeReportsAgentInfoAndAuthMethods() throws {
        let result = try fixture("initialize-result.json")

        let parsed = try XCTUnwrap(ACPInitializeParser.parse(result: result))
        XCTAssertEqual(parsed.agentInfo?.name, "OpenCode")
        XCTAssertEqual(parsed.authMethods.map(\.id), ["opencode-login"])
        XCTAssertNil(parsed.gateway, "a plain ACP server sends no acpcode/gateway meta")
    }

    func testPermissionRequestFromOpencodeParsesOptionKinds() throws {
        let params = try fixture("permission-request-edit.json")

        let request = try XCTUnwrap(ACPPermissionRequestParser.parse(params: params))

        XCTAssertEqual(request.toolCallTitle, "edit")
        XCTAssertEqual(request.toolCallKind, "edit")
        XCTAssertEqual(request.toolCallId, "call_deb7414c")
        // opencode's ids are "once", "always" and "reject"; the kinds are the ACP ones.
        XCTAssertEqual(request.options.map(\.optionId), ["once", "always", "reject"])
        XCTAssertEqual(request.options.map(\.kind), [.allowOnce, .allowAlways, .rejectOnce])
    }

    func testSessionUpdatesFromOpencodeSummarizeAndExtractText() throws {
        let message = try fixture("session-update-agent-message-chunk.json")
        let parsedMessage = ACPSessionUpdateParser.parse(params: message)
        XCTAssertEqual(parsedMessage.kind, "agent_message_chunk")
        XCTAssertEqual(ACPSessionUpdateParser.extractText(from: parsedMessage.update), "\n\npong")

        let toolCall = try fixture("session-update-tool-call.json")
        let parsedCall = ACPSessionUpdateParser.parse(params: toolCall)
        XCTAssertEqual(parsedCall.kind, "tool_call")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallTitle(from: parsedCall.update), "write")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallKind(from: parsedCall.update), "edit")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallId(from: parsedCall.update), "call_b9986046")

        let completed = try fixture("session-update-tool-call-update-completed.json")
        let parsedDone = ACPSessionUpdateParser.parse(params: completed)
        XCTAssertEqual(ACPSessionUpdateParser.toolCallStatus(from: parsedDone.update), "completed")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallOutput(from: parsedDone.update), "Wrote file successfully.")

        let failed = try fixture("session-update-tool-call-update-failed.json")
        let parsedFailed = ACPSessionUpdateParser.parse(params: failed)
        XCTAssertEqual(ACPSessionUpdateParser.toolCallStatus(from: parsedFailed.update), "failed")
        XCTAssertEqual(ACPSessionUpdateParser.toolCallOutput(from: parsedFailed.update), "Error: The user rejected permission to use this specific tool call.")
    }

    func testUsageAndCommandUpdatesAreRecognised() throws {
        let usage = ACPSessionUpdateParser.parse(params: try fixture("session-update-usage-update.json"))
        XCTAssertEqual(usage.kind, "usage_update")
        let commands = ACPSessionUpdateParser.parse(params: try fixture("session-update-available-commands-update.json"))
        XCTAssertEqual(commands.kind, "available_commands_update")
        XCTAssertEqual(ACPSessionUpdateParser.summarize(params: try fixture("session-update-available-commands-update.json")),
                       "session/update [ses_e33283185ffeiuZZrgmmWr9tM8] available commands updated")
    }
}
