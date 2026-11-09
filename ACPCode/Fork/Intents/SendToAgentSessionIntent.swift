import AppIntents
import Foundation

/// "Send to agent session": a Shortcut step that sends one prompt to an existing session on the selected gateway
/// server. It runs in the app process (no extension). It does not open the session and does not change the screen:
/// navigation happens only if the person chooses it in the app.
///
/// Privacy: the prompt goes through Shortcuts and may be kept in Siri and Dictation history on this device (Apple's
/// Siri and Dictation privacy page). The app writes it nowhere else. The description below says so.
struct SendToAgentSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Send to agent session"
    static let description = IntentDescription(
        "Sends a prompt to an existing session on your ACP Code gateway. It does not open the session. The prompt is passed through Shortcuts and may be kept in Siri and Dictation history on this device. Do not include passwords or keys."
    )

    /// Needs the device unlocked, as the start does: the token can only be read then.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    /// Below iOS 26 the app is opened for the run, which is how the intent reaches the app process there. It must be
    /// a compile-time constant. From iOS 26 `supportedModes` (below) takes over, so this value is ignored there.
    @available(iOS, introduced: 16.0, deprecated: 26.0, message: "Use supportedModes")
    static let openAppWhenRun: Bool = true

    /// The run stays in the background. Nothing here asks the app to come forward.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Session", requestValueDialog: IntentDialog("Which session?"))
    var session: GatewaySessionEntity

    @Parameter(title: "Prompt", requestValueDialog: IntentDialog("What should the agent do?"))
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$prompt) to \(\.$session)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentSendResultEntity> & ProvidesDialog {
        guard let target = session.target else { throw SendToSessionError.malformedSession }
        let sender = AgentSessionSender(host: ForkProcessModel.shared)
        let outcome = try await sender.send(prompt: prompt, to: target)
        return .result(value: AgentSendResultEntity(outcome: outcome),
                       dialog: IntentDialog(stringLiteral: Self.dialog(for: outcome)))
    }

    /// The spoken and shown result. It names the status only, never the prompt or the session title.
    static func dialog(for outcome: AgentSendOutcome) -> String {
        switch outcome.status {
        case .accepted:
            return "Sent to the session. The agent has started the turn."
        case .busy:
            return "Nothing was sent. A turn is already running in that session. Try again when it finishes."
        case .failed:
            let reason = outcome.detail.map { " \($0)" } ?? ""
            return "The gateway did not confirm the prompt.\(reason) It may or may not have been sent, so check the session before sending again."
        }
    }
}

extension AgentSendStatus: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Send status"
    static let caseDisplayRepresentations: [AgentSendStatus: DisplayRepresentation] = [
        .accepted: "Sent",
        .busy: "Already running",
        .failed: "Not confirmed",
    ]
}

/// The result of a send: the session it was sent to, the turn the gateway started (when it did), and the status.
struct AgentSendResultEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Send result"
    static let defaultQuery = AgentSendResultQuery()

    /// `<serverUUID>/<sessionId>`, the same id as the session entity it was sent to.
    let id: String
    let turnId: String?
    let status: AgentSendStatus

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(Self.label(for: status))")
    }

    init(outcome: AgentSendOutcome) {
        id = outcome.entityID
        turnId = outcome.turnId
        status = outcome.status
    }

    private static func label(for status: AgentSendStatus) -> String {
        switch status {
        case .accepted: return "Sent"
        case .busy: return "Already running"
        case .failed: return "Not confirmed"
        }
    }
}

/// A send result is not stored, so a reference from an earlier run does not resolve. The result from the run is
/// what a Shortcut passes to its next step.
struct AgentSendResultQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AgentSendResultEntity] {
        []
    }
}
