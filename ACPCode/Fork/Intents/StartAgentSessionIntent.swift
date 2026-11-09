import AppIntents
import Foundation

/// "Start agent session": a Shortcut step that starts a session on the selected gateway server, in a project, and
/// sends the first prompt. It runs in the app process (no extension), so it can use the app's one connection.
///
/// Privacy: the prompt goes through Shortcuts and may be kept in Siri and Dictation history on this device (Apple's
/// Siri and Dictation privacy page). The app writes it nowhere else. The description below says so.
struct StartAgentSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start agent session"
    static let description = IntentDescription(
        "Starts a session on your ACP Code gateway in a project and sends the first prompt. The prompt is passed through Shortcuts and may be kept in Siri and Dictation history on this device. Do not include passwords or keys."
    )

    /// Needs the device unlocked. The default (always allowed) would run while locked, where the token cannot be read.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    /// Below iOS 26 the app is opened for the run, which is how the intent reaches the app process there. It must be
    /// a compile-time constant. From iOS 26 `supportedModes` (below) takes over, so this value is ignored there.
    @available(iOS, introduced: 16.0, deprecated: 26.0, message: "Use supportedModes")
    static let openAppWhenRun: Bool = true

    /// From iOS 26 the run stays in the background. It only needs the foreground for an approval, which is answered
    /// in the app, not from here.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Prompt", requestValueDialog: IntentDialog("What should the agent do?"))
    var prompt: String

    @Parameter(title: "Project")
    var project: GatewayProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Start an agent session with \(\.$prompt)") {
            \.$project
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<AgentSessionEntity> & ProvidesDialog {
        let starter = AgentSessionStarter(host: ForkProcessModel.shared)
        let outcome = try await starter.start(prompt: prompt, project: project?.choice)
        let entity = AgentSessionEntity(outcome: outcome)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: Self.dialog(for: outcome)))
    }

    /// The spoken and shown result. It names the project and the status only, never the prompt.
    static func dialog(for outcome: AgentSessionOutcome) -> String {
        switch outcome.status {
        case .running:
            return "Started a session in \(outcome.projectName)."
        case .waitingForApproval:
            return "Started a session in \(outcome.projectName). It is waiting for an approval: answer it in ACP Code."
        case .createdNotSent:
            let reason = outcome.detail.map { " \($0)" } ?? ""
            return "Session created in \(outcome.projectName), but the prompt was not sent.\(reason) Open it in ACP Code to send it again."
        }
    }
}
