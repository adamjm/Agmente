import Foundation
import ACP
import ACPClient

/// The three answers the agent can get (ACP elicitation, D-090).
enum ElicitationAction: String, Equatable, Sendable {
    case accept
    case decline
    case cancel
}

/// Sends one answer to the gateway. Tests use a fake; the app uses `GatewayClient`.
protocol ElicitationAnswering: Sendable {
    /// `content` is non-nil only with `.accept`.
    func answerElicitation(elicitationId: String, action: ElicitationAction, content: [String: ACP.Value]?) async throws
}

extension GatewayClient: ElicitationAnswering {
    func answerElicitation(elicitationId: String, action: ElicitationAction, content: [String: ACP.Value]?) async throws {
        try await sendElicitationAnswer(elicitationId: elicitationId, action: action.rawValue, content: content)
    }
}

/// The form's state and its three answers (PLAN 6C.3). Accept builds the content from the supported
/// fields; decline and cancel send only the action. Nothing here logs or prints a value the person typed.
@MainActor
final class ElicitationFormModel: ObservableObject, Identifiable {
    let request: ElicitationRequest
    private let answering: ElicitationAnswering

    /// Text and number fields, and the chosen option of a choice field, by field name.
    @Published var texts: [String: String] = [:]
    /// Boolean fields, by field name. An untouched switch reads as false.
    @Published var toggles: [String: Bool] = [:]
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isClosed = false

    /// Called once when the form is finished. The argument is a note for the person when the form closed
    /// because someone else answered first, and nil after the app's own answer.
    var onFinish: ((String?) -> Void)?

    var id: String { request.id }

    enum SubmitError: Error, Equatable, Sendable {
        /// Required fields the app cannot render: accept is not allowed.
        case unsupportedRequired([String])
        case missingRequired([String])
        case invalidValue(String)
    }

    init(request: ElicitationRequest, answering: ElicitationAnswering) {
        self.request = request
        self.answering = answering
    }

    /// Why accept is blocked, or nil when it may be sent. Decline and cancel are never blocked.
    var blockingReason: String? {
        let blocked = request.fields.filter { $0.required && !$0.isSupported }.map(\.name)
        guard blocked.isEmpty else { return "This form is not supported in this app; you can decline or cancel." }
        return nil
    }

    var hasUnsupportedRequiredFields: Bool { request.hasUnsupportedRequiredFields }

    /// The content for `accept`, built from the supported fields only. Throws without sending anything.
    func contentForAccept() throws -> [String: ACP.Value] {
        let unsupported = request.fields.filter { $0.required && !$0.isSupported }.map(\.name)
        if !unsupported.isEmpty { throw SubmitError.unsupportedRequired(unsupported) }

        var content: [String: ACP.Value] = [:]
        var missing: [String] = []
        for field in request.fields where field.isSupported {
            let text = texts[field.name] ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.kind {
            case .text:
                if trimmed.isEmpty {
                    if field.required { missing.append(field.name) }
                } else {
                    content[field.name] = .string(text)
                }
            case .choice(let options):
                if text.isEmpty {
                    if field.required { missing.append(field.name) }
                } else if options.contains(where: { $0.value == text }) {
                    content[field.name] = .string(text)
                } else {
                    throw SubmitError.invalidValue(field.name)
                }
            case .number:
                if trimmed.isEmpty {
                    if field.required { missing.append(field.name) }
                } else if let number = Double(trimmed), number.isFinite {
                    content[field.name] = .double(number)
                } else {
                    throw SubmitError.invalidValue(field.name)
                }
            case .integer:
                if trimmed.isEmpty {
                    if field.required { missing.append(field.name) }
                } else if let number = Int(trimmed) {
                    content[field.name] = .int(number)
                } else {
                    throw SubmitError.invalidValue(field.name)
                }
            case .boolean:
                content[field.name] = .bool(toggles[field.name] ?? false)
            case .unsupported:
                break // optional and not rendered: left out of the content
            }
        }
        if !missing.isEmpty { throw SubmitError.missingRequired(missing) }
        return content
    }

    /// Accept: sends the content of the supported fields.
    func submit() async {
        let content: [String: ACP.Value]
        do {
            content = try contentForAccept()
        } catch let error as SubmitError {
            errorMessage = Self.message(for: error)
            return
        } catch {
            errorMessage = "The answer could not be built."
            return
        }
        await send(.accept, content: content)
    }

    /// Decline: sends only the action.
    func decline() async {
        await send(.decline, content: nil)
    }

    /// Cancel: sends only the action.
    func cancel() async {
        await send(.cancel, content: nil)
    }

    private func send(_ action: ElicitationAction, content: [String: ACP.Value]?) async {
        guard !isSending, !isClosed else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await answering.answerElicitation(elicitationId: request.id, action: action, content: content)
            finish(note: nil)
        } catch let error as GatewayError where error.isAlreadyClosed {
            finish(note: "Already closed: \(error.message)")
        } catch {
            // The form stays open so the person can try again.
            errorMessage = (error as? GatewayError)?.message ?? "Could not send the answer."
        }
    }

    private func finish(note: String?) {
        guard !isClosed else { return }
        isClosed = true
        onFinish?(note)
    }

    /// The gateway closed the form (an `answered elsewhere` or timeout event).
    func closedByGateway(note: String) {
        finish(note: note)
    }

    static func message(for error: SubmitError) -> String {
        switch error {
        case .unsupportedRequired:
            return "This form is not supported in this app; you can decline or cancel."
        case .missingRequired(let names):
            return "Fill in the required fields: \(names.joined(separator: ", "))."
        case .invalidValue(let name):
            return "The value of \(name) is not valid."
        }
    }
}
