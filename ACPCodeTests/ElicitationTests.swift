import XCTest
import ACP
@testable import ACPCode
import ACPClient

// PLAN 6C.3 and D-090: parsing of the gateway's elicitation event, the form model's answers, and the
// wire shape of the answer. Fakes record what would be sent; nothing here talks to a gateway.

private func elicitationMessage(
    mode: String? = "form",
    schema: ACP.Value? = nil,
    message: String = "Accept the Bob licence?",
    id: String = "acpcode-elic-0a1b2c"
) -> ACP.Value {
    var params: [String: ACP.Value] = [
        "sessionId": .string("s1"),
        "toolCallId": .string("call-7"),
        "message": .string(message),
        "requestedSchema": schema ?? defaultSchema(),
    ]
    if let mode { params["mode"] = .string(mode) }
    return .object(["id": .string(id), "method": .string("elicitation/create"), "params": .object(params)])
}

private func defaultSchema() -> ACP.Value {
    .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object(["type": .string("string"), "title": .string("Name")]),
            "color": .object(["type": .string("string"), "enum": .array([.string("red"), .string("blue")])]),
            "count": .object(["type": .string("integer")]),
            "ratio": .object(["type": .string("number")]),
            "agree": .object(["type": .string("boolean")]),
            "avatar": .object(["type": .string("array")]),
        ]),
        "required": .array([.string("name")]),
    ])
}

private func field(_ request: ElicitationRequest, _ name: String) -> ElicitationField? {
    request.fields.first { $0.name == name }
}

final class ElicitationParsingTests: XCTestCase {
    func testValidFormParsesMessageSessionAndFields() throws {
        let request = try ElicitationRequest.parse(elicitationMessage())
        XCTAssertEqual(request.id, "acpcode-elic-0a1b2c")
        XCTAssertEqual(request.sessionId, "s1")
        XCTAssertEqual(request.toolCallId, "call-7")
        XCTAssertEqual(request.message, "Accept the Bob licence?")
        XCTAssertEqual(request.fields.map(\.name), ["agree", "avatar", "color", "count", "name", "ratio"])
        XCTAssertEqual(field(request, "name")?.kind, .text)
        XCTAssertEqual(field(request, "name")?.label, "Name")
        XCTAssertEqual(field(request, "name")?.required, true)
        XCTAssertEqual(field(request, "color")?.kind, .choice([
            ElicitationOption(value: "red", title: "red"),
            ElicitationOption(value: "blue", title: "blue"),
        ]))
        XCTAssertEqual(field(request, "count")?.kind, .integer)
        XCTAssertEqual(field(request, "ratio")?.kind, .number)
        XCTAssertEqual(field(request, "agree")?.kind, .boolean)
    }

    func testTitledOneOfChoiceBecomesSelectableOptions() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "objective": .object([
                    "type": .string("string"),
                    "title": .string("Primary objective"),
                    "oneOf": .array([
                        .object(["const": .string("eval"), "title": .string("Evaluate")]),
                        .object(["const": .string("build"), "title": .string("Build a prototype")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("objective")]),
        ])
        let request = try ElicitationRequest.parse(elicitationMessage(schema: schema))
        let objective = try XCTUnwrap(field(request, "objective"))
        XCTAssertTrue(objective.isSupported)
        XCTAssertEqual(objective.label, "Primary objective")
        XCTAssertEqual(objective.kind, .choice([
            ElicitationOption(value: "eval", title: "Evaluate"),
            ElicitationOption(value: "build", title: "Build a prototype"),
        ]))
        XCTAssertFalse(request.hasUnsupportedFields)
    }

    func testAnyOfWithoutTitlesUsesTheConstAsLabel() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "size": .object(["type": .string("string"), "anyOf": .array([.object(["const": .string("S")]), .object(["const": .string("M")])])]),
            ]),
        ])
        let request = try ElicitationRequest.parse(elicitationMessage(schema: schema))
        XCTAssertEqual(field(request, "size")?.kind, .choice([
            ElicitationOption(value: "S", title: "S"),
            ElicitationOption(value: "M", title: "M"),
        ]))
    }

    func testEnumNamesGiveTheLabels() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "tier": .object([
                    "type": .string("string"),
                    "enum": .array([.string("t1"), .string("t2")]),
                    "enumNames": .array([.string("Tier one"), .string("Tier two")]),
                ]),
            ]),
        ])
        let request = try ElicitationRequest.parse(elicitationMessage(schema: schema))
        XCTAssertEqual(field(request, "tier")?.kind, .choice([
            ElicitationOption(value: "t1", title: "Tier one"),
            ElicitationOption(value: "t2", title: "Tier two"),
        ]))
    }

    func testAChoiceEntryWithoutAConstMakesTheListUnsupported() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "pick": .object(["type": .string("string"), "oneOf": .array([.object(["title": .string("No value")])])]),
            ]),
        ])
        let request = try ElicitationRequest.parse(elicitationMessage(schema: schema))
        XCTAssertEqual(field(request, "pick")?.kind, .unsupported("choice list"))
    }

    func testURLModeIsRefused() {
        XCTAssertThrowsError(try ElicitationRequest.parse(elicitationMessage(mode: "url"))) { error in
            XCTAssertEqual(error as? ElicitationRequest.ParseError, .unsupportedMode("url"))
        }
    }

    func testMissingModeIsRefused() {
        XCTAssertThrowsError(try ElicitationRequest.parse(elicitationMessage(mode: nil))) { error in
            XCTAssertEqual(error as? ElicitationRequest.ParseError, .unsupportedMode(nil))
        }
    }

    func testSchemaThatIsNotAnObjectIsRefused() {
        let arraySchema: ACP.Value = .object(["type": .string("array"), "properties": .object([:])])
        XCTAssertThrowsError(try ElicitationRequest.parse(elicitationMessage(schema: arraySchema))) { error in
            XCTAssertEqual(error as? ElicitationRequest.ParseError, .schemaNotObject)
        }
        XCTAssertThrowsError(try ElicitationRequest.parse(elicitationMessage(schema: .string("object")))) { error in
            XCTAssertEqual(error as? ElicitationRequest.ParseError, .schemaNotObject)
        }
    }

    func testUnsupportedFieldIsKeptAndMarked() throws {
        let request = try ElicitationRequest.parse(elicitationMessage())
        let avatar = try XCTUnwrap(field(request, "avatar"))
        XCTAssertEqual(avatar.kind, .unsupported("array"))
        XCTAssertFalse(avatar.isSupported)
        XCTAssertFalse(avatar.required)
        XCTAssertTrue(request.hasUnsupportedFields)
    }

    func testRequiredNameWithoutPropertyIsKeptAsUnsupportedAndRequired() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "required": .array([.string("ghost")]),
        ])
        let request = try ElicitationRequest.parse(elicitationMessage(schema: schema))
        let ghost = try XCTUnwrap(field(request, "ghost"))
        XCTAssertFalse(ghost.isSupported)
        XCTAssertTrue(ghost.required)
    }

    func testOtherMethodIsNotAnElicitation() {
        let message: ACP.Value = .object(["id": .string("acpcode-elic-1"), "method": .string("session/update"), "params": .object([:])])
        XCTAssertThrowsError(try ElicitationRequest.parse(message)) { error in
            XCTAssertEqual(error as? ElicitationRequest.ParseError, .notAnElicitation)
        }
    }
}

/// Records each answer, as the gateway would receive it.
private final class FakeElicitationAnswering: ElicitationAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(id: String, action: ElicitationAction, content: [String: ACP.Value]?)] = []
    var error: Error?

    var answers: [(id: String, action: ElicitationAction, content: [String: ACP.Value]?)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func answerElicitation(elicitationId: String, action: ElicitationAction, content: [String: ACP.Value]?) async throws {
        lock.lock(); recorded.append((elicitationId, action, content)); lock.unlock()
        if let error { throw error }
    }
}

/// A plain fake of the connection under `GatewayClient`, to check the wire params.
private final class FakeGatewayCalls: GatewayCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(method: String, params: ACP.Value?)] = []

    var calls: [(method: String, params: ACP.Value?)] { lock.lock(); defer { lock.unlock() }; return recorded }

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        lock.lock(); recorded.append((method, params)); lock.unlock()
        return .object([:])
    }
}

@MainActor
final class ElicitationFormModelTests: XCTestCase {
    private func form(_ answering: FakeElicitationAnswering, schema: ACP.Value? = nil) throws -> ElicitationFormModel {
        ElicitationFormModel(request: try ElicitationRequest.parse(elicitationMessage(schema: schema)), answering: answering)
    }

    func testAcceptBuildsContentFromSupportedFieldsOnly() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"
        model.texts["color"] = "blue"
        model.texts["count"] = "3"
        model.texts["ratio"] = "0.5"
        model.toggles["agree"] = true

        await model.submit()

        XCTAssertEqual(answering.answers.count, 1)
        let sent = try XCTUnwrap(answering.answers.first)
        XCTAssertEqual(sent.id, "acpcode-elic-0a1b2c")
        XCTAssertEqual(sent.action, .accept)
        XCTAssertEqual(sent.content, [
            "name": .string("Ada"),
            "color": .string("blue"),
            "count": .int(3),
            "ratio": .double(0.5),
            "agree": .bool(true),
        ])
        XCTAssertTrue(model.isClosed)
    }

    func testRequiredEmptyFieldBlocksAccept() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "   "

        await model.submit()

        XCTAssertTrue(answering.answers.isEmpty, "nothing is sent while a required field is empty")
        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(model.errorMessage, "Fill in the required fields: name.")
    }

    func testRequiredUnsupportedFieldBlocksAcceptButCancelStillWorks() async throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object(["avatar": .object(["type": .string("array")])]),
            "required": .array([.string("avatar")]),
        ])
        let answering = FakeElicitationAnswering()
        let model = try form(answering, schema: schema)

        XCTAssertNotNil(model.blockingReason)
        await model.submit()
        XCTAssertTrue(answering.answers.isEmpty)

        await model.cancel()
        XCTAssertEqual(answering.answers.map(\.action), [.cancel])
    }

    func testOptionalUnsupportedFieldIsLeftOutOfAccept() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"

        await model.submit()

        XCTAssertNil(answering.answers.first?.content?["avatar"])
        XCTAssertEqual(answering.answers.first?.action, .accept)
    }

    // The "not supported in this app" note shows only for a required field that cannot be answered.
    func testOnlyOptionalUnsupportedFieldShowsNoNote() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "avatar": .object(["type": .string("array")]),
            ]),
            "required": .array([.string("name")]),
        ])
        let model = try form(FakeElicitationAnswering(), schema: schema)

        XCTAssertTrue(model.request.hasUnsupportedFields)
        XCTAssertFalse(model.hasUnsupportedRequiredFields)
    }

    func testRequiredUnsupportedFieldShowsNote() throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object(["avatar": .object(["type": .string("array")])]),
            "required": .array([.string("avatar")]),
        ])
        let model = try form(FakeElicitationAnswering(), schema: schema)

        XCTAssertTrue(model.hasUnsupportedRequiredFields)
    }

    func testChoiceOutsideTheListIsRefused() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"
        model.texts["color"] = "green"

        await model.submit()

        XCTAssertTrue(answering.answers.isEmpty)
        XCTAssertEqual(model.errorMessage, "The value of color is not valid.")
    }

    func testNumberFieldRejectsText() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"
        model.texts["count"] = "three"

        await model.submit()

        XCTAssertTrue(answering.answers.isEmpty)
        XCTAssertEqual(model.errorMessage, "The value of count is not valid.")
    }

    func testCancelSendsOnlyTheAction() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"

        await model.cancel()

        XCTAssertEqual(answering.answers.count, 1)
        XCTAssertEqual(answering.answers.first?.action, .cancel)
        XCTAssertNil(answering.answers.first?.content)
        XCTAssertTrue(model.isClosed)
    }

    func testDeclineSendsOnlyTheAction() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["name"] = "Ada"

        await model.decline()

        XCTAssertEqual(answering.answers.count, 1)
        XCTAssertEqual(answering.answers.first?.action, .decline)
        XCTAssertNil(answering.answers.first?.content)
    }

    func testAlreadyClosedAnswerClosesTheFormWithANote() async throws {
        let answering = FakeElicitationAnswering()
        answering.error = GatewayError.rpc(code: -32001, message: "answered elsewhere")
        let model = try form(answering)
        var note: String?
        model.onFinish = { note = $0 }
        model.texts["name"] = "Ada"

        await model.submit()

        XCTAssertTrue(model.isClosed)
        XCTAssertEqual(note, "Already closed: answered elsewhere")
    }

    func testOtherFailureKeepsTheFormOpen() async throws {
        let answering = FakeElicitationAnswering()
        answering.error = GatewayError.disconnected
        let model = try form(answering)
        model.texts["name"] = "Ada"

        await model.submit()

        XCTAssertFalse(model.isClosed)
        XCTAssertEqual(model.errorMessage, "Not connected")
    }

    func testAnswerParamsOmitContentForDecline() async throws {
        let calls = FakeGatewayCalls()
        let client = GatewayClient(calls)

        try await client.sendElicitationAnswer(elicitationId: "acpcode-elic-0a1b2c", action: "decline", content: ["name": .string("Ada")])

        let sent = try XCTUnwrap(calls.calls.first)
        XCTAssertEqual(sent.method, "_acpcode/elicitation/answer")
        XCTAssertEqual(sent.params, .object(["elicitationId": .string("acpcode-elic-0a1b2c"), "action": .string("decline")]))
    }

    /// The model keeps content values out of logs and out of the console: no print, dump or logger call.
    func testContentValuesAreNeverLogged() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ACPCode/Fork/Elicitation/ElicitationFormModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for forbidden in ["print(", "debugPrint(", "dump(", "NSLog", "os_log", "Logger", "startupLog("] {
            XCTAssertFalse(text.contains(forbidden), "ElicitationFormModel.swift must not contain \(forbidden)")
        }
    }
}

/// An answer that stays in flight until the test releases it, so an event can arrive while it is sending.
private final class GatedElicitationAnswering: ElicitationAnswering, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    /// True once an answer is in flight and waiting for `release()`.
    var isWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiting != nil
    }

    func answerElicitation(elicitationId: String, action: ElicitationAction, content: [String: ACP.Value]?) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting = continuation
                lock.unlock()
            }
        }
    }

    /// Lets the in-flight answer finish. Safe to call before the answer has started.
    func release() {
        lock.lock()
        released = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }
}

@MainActor
final class ElicitationInboxEchoTests: XCTestCase {
    /// The gateway sends the answered event to the device that answered, before the answer's response.
    /// That echo must not close the form or show the "answered elsewhere" notice.
    func testEchoOfThisDevicesOwnAnswerDoesNotCloseTheForm() async throws {
        let answering = GatedElicitationAnswering()
        let inbox = ElicitationInboxModel()
        let request = try ElicitationRequest.parse(elicitationMessage())
        inbox.present(request, answering: answering)
        let form = try XCTUnwrap(inbox.current)
        form.texts["name"] = "Ada"

        let submitting = Task { await form.submit() }
        while !answering.isWaiting { await Task.yield() }
        XCTAssertTrue(form.isSending)

        inbox.closed(elicitationId: request.id, answeredBy: "owner/iphone-owner")
        XCTAssertFalse(form.isClosed, "the echo of this device's own answer must not close the form")
        XCTAssertNil(inbox.notice)

        answering.release()
        await submitting.value
        XCTAssertTrue(form.isClosed)
        XCTAssertNil(inbox.notice, "an accepted answer shows no note")
    }

    /// A close that arrives while this device is not answering is another device's answer.
    func testAnotherDevicesAnswerStillClosesTheForm() throws {
        let inbox = ElicitationInboxModel()
        let request = try ElicitationRequest.parse(elicitationMessage())
        inbox.present(request, answering: GatedElicitationAnswering())

        inbox.closed(elicitationId: request.id, answeredBy: "owner/other-phone")

        XCTAssertTrue(inbox.forms.isEmpty)
        XCTAssertEqual(inbox.notice, "The agent's question was answered elsewhere or closed (owner/other-phone).")
    }

    func testChoiceAnswerSendsTheSelectedValue() async throws {
        let schema: ACP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "objective": .object([
                    "type": .string("string"),
                    "oneOf": .array([.object(["const": .string("eval"), "title": .string("Evaluate")])]),
                ]),
            ]),
            "required": .array([.string("objective")]),
        ])
        let answering = FakeElicitationAnswering()
        let model = ElicitationFormModel(request: try ElicitationRequest.parse(elicitationMessage(schema: schema)), answering: answering)
        model.texts["objective"] = "eval"

        await model.submit()

        XCTAssertEqual(answering.answers.first?.content, ["objective": .string("eval")])
    }
}

/// The request Bob 2.0.9 sent on 2026-11-07 (gateway.db, seq 44): one string property `answer` whose
/// `oneOf` entries hold the agent's options as full sentences (`const` and `title` are the same text),
/// plus a free-text property `other`. Neither property is required.
@MainActor
final class ElicitationAgentQuestionShapeTests: XCTestCase {
    private static let options = [
        "Yes, the plan is complete and covers all requirements. Please switch to Agent mode to begin execution.",
        "Let's modify the sub-tasks before proceeding.",
        "The scope is good, but let's add a specific focus on comparing startup latency alongside memory consumption.",
        "Please emphasize local macOS development integration over cloud-based execution.",
    ]

    private func agentQuestionSchema() -> ACP.Value {
        .object([
            "type": .string("object"),
            "properties": .object([
                "answer": .object([
                    "type": .string("string"),
                    "title": .string("Answer"),
                    "oneOf": .array(Self.options.map { .object(["const": .string($0), "title": .string($0)]) }),
                ]),
                "other": .object([
                    "type": .string("string"),
                    "title": .string("Or type your own answer"),
                ]),
            ]),
        ])
    }

    private func form(_ answering: FakeElicitationAnswering) throws -> ElicitationFormModel {
        let message = elicitationMessage(schema: agentQuestionSchema(), message: "Does this plan capture the full scope of your requirements for evaluating low-memory AI agent code isolation?")
        return ElicitationFormModel(request: try ElicitationRequest.parse(message), answering: answering)
    }

    func testEachAgentSentenceBecomesItsOwnChoiceAndTheTypedFieldStaysText() throws {
        let request = try ElicitationRequest.parse(elicitationMessage(schema: agentQuestionSchema()))

        XCTAssertEqual(request.fields.map(\.name), ["answer", "other"])
        XCTAssertFalse(request.hasUnsupportedFields)
        let answer = try XCTUnwrap(field(request, "answer"))
        XCTAssertEqual(answer.label, "Answer")
        XCTAssertFalse(answer.required)
        XCTAssertEqual(answer.kind, .choice(Self.options.map { ElicitationOption(value: $0, title: $0) }))
        let other = try XCTUnwrap(field(request, "other"))
        XCTAssertEqual(other.label, "Or type your own answer")
        XCTAssertEqual(other.kind, .text)
    }

    func testAcceptSendsTheChosenSentenceUnderTheAnswerProperty() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["answer"] = Self.options[1]

        await model.submit()

        XCTAssertEqual(answering.answers.first?.action, .accept)
        XCTAssertEqual(answering.answers.first?.content, ["answer": .string(Self.options[1])])
    }

    func testTypedOwnAnswerIsSentUnderTheOtherProperty() async throws {
        let answering = FakeElicitationAnswering()
        let model = try form(answering)
        model.texts["other"] = "Use the existing sandbox."

        await model.submit()

        XCTAssertEqual(answering.answers.first?.content, ["other": .string("Use the existing sandbox.")])
    }
}
