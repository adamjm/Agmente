import Foundation
import ACPClient

// The logic behind the "Start agent session" Shortcut (app process only). It starts a session on the selected
// gateway server, in a registered project, and sends the first prompt. It never selects a server, never makes the
// session the one on screen, and never navigates. The prompt text is never put in a notification, a dialog, a
// log line or an index: the outcome carries ids and fixed text only.

/// Why a Shortcut run stopped before a session existed. Each case has the text the person sees (the intent throws it).
enum AgentSessionError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noServer
    case notGateway
    case otherServer
    case unreachable
    case noProjects
    case projectRequired
    case projectMissing
    case emptyPrompt
    case promptTooLong
    /// The gateway refused or failed; its own text, which never contains the prompt.
    case gateway(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: return "Choose a gateway server in ACP Code first."
        case .notGateway: return "Sessions from a Shortcut need an ACP Code gateway server."
        case .otherServer: return "Switch to that server in ACP Code first."
        case .unreachable: return "Can't reach your Mac. Check that it is awake and connected."
        case .noProjects: return "No projects are set up on this Mac yet."
        case .projectRequired: return "Choose a project for this session."
        case .projectMissing: return "That project is no longer on your Mac. Choose another in ACP Code."
        case .emptyPrompt: return "Say what the agent should do."
        case .promptTooLong: return "That prompt is over 8 KB. Shorten it."
        case .gateway(let message): return LocalizedStringResource(stringLiteral: "Your Mac returned an error: \(message)")
        }
    }
}

/// How a started session stands when the run ends. Both statuses are successes for the session: it exists.
enum AgentStartStatus: String, CaseIterable, Equatable, Sendable {
    /// The gateway accepted the prompt and no approval was asked for in the window.
    case running
    /// The turn is blocked on a tool approval. Answer it in ACP Code.
    case waitingForApproval
    /// The session was created, but its first prompt was not sent. `detail` says why.
    case createdNotSent
}

/// What a run produced: the session it started, with a status.
struct AgentSessionOutcome: Equatable, Sendable {
    let serverID: UUID
    let sessionId: String
    let projectName: String
    let status: AgentStartStatus
    /// For `createdNotSent`, the gateway's reason. Nil otherwise.
    let detail: String?

    /// `<serverUUID>/<sessionId>`: unique across servers, and stable for Shortcuts to store.
    var entityID: String { "\(serverID.uuidString)/\(sessionId)" }
}

/// A project the person picked: the server it belongs to, and its gateway id.
struct AgentProjectChoice: Equatable, Sendable {
    let serverID: UUID
    let projectID: String
}

/// What the starter needs from the app. The app's model conforms; tests use a fake.
@MainActor
protocol AgentSessionHost: AnyObject {
    /// The selected server, or nil when none is selected.
    var selectedServerID: UUID? { get }

    /// Connects to the selected server and makes sure it is initialised, then returns its gateway client.
    /// Throws `AgentSessionError` (`noServer`, `notGateway` or `unreachable`). It never changes the selection.
    func connectSelectedGateway() async throws -> GatewayClient

    /// Never called by the starter. It is in this protocol only so a test can check that nothing selects another
    /// server, and so nothing can call it without the test noticing.
    func selectServer(_ id: UUID)
}

/// Runs the start. The durations are injected so tests run in milliseconds. The defaults are the product's:
/// a 10 s connect deadline, a 20 s window for an approval, and a poll every 2 s inside it.
@MainActor
final class AgentSessionStarter {
    static let maxPromptBytes = 8_192
    static let defaultConnectDeadline: Duration = .seconds(10)
    static let defaultApprovalWindow: Duration = .seconds(20)
    static let defaultPollInterval: Duration = .seconds(2)

    private let host: AgentSessionHost
    private let connectDeadline: Duration
    private let approvalWindow: Duration
    private let pollInterval: Duration

    init(
        host: AgentSessionHost,
        connectDeadline: Duration = AgentSessionStarter.defaultConnectDeadline,
        approvalWindow: Duration = AgentSessionStarter.defaultApprovalWindow,
        pollInterval: Duration = AgentSessionStarter.defaultPollInterval
    ) {
        self.host = host
        self.connectDeadline = connectDeadline
        self.approvalWindow = approvalWindow
        self.pollInterval = pollInterval
    }

    /// Starts a session with `prompt`. Refusals throw before any `session/new` is sent. Once a session exists, the
    /// result is returned, never thrown: a `createdNotSent` outcome carries the session id.
    func start(prompt: String, project: AgentProjectChoice?) async throws -> AgentSessionOutcome {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentSessionError.emptyPrompt }
        guard text.utf8.count <= Self.maxPromptBytes else { throw AgentSessionError.promptTooLong }

        guard let selected = host.selectedServerID else { throw AgentSessionError.noServer }
        if let project, project.serverID != selected { throw AgentSessionError.otherServer }

        let client = try await withDeadline(connectDeadline) { [host] in
            try await host.connectSelectedGateway()
        }
        // The selection can move while connecting. The run stays on the server it started on, or stops.
        guard host.selectedServerID == selected else { throw AgentSessionError.otherServer }

        let projects = try await translating { try await client.projects() }
        guard !projects.isEmpty else { throw AgentSessionError.noProjects }
        let chosen: GatewayProject
        if let project {
            guard let match = projects.first(where: { $0.id == project.projectID }) else {
                throw AgentSessionError.projectMissing
            }
            chosen = match
        } else if projects.count == 1, let only = projects.first {
            chosen = only
        } else {
            throw AgentSessionError.projectRequired
        }

        let created: GatewaySessionCreateResult
        do {
            created = try await client.createSession(cwd: chosen.path, prompt: text)
        } catch GatewayError.sessionCreatedPromptNotSent(let sessionId, let message) {
            return AgentSessionOutcome(serverID: selected, sessionId: sessionId, projectName: chosen.name,
                                       status: .createdNotSent, detail: message)
        } catch {
            throw Self.translate(error)
        }

        // Subscribing gives this device the session's events, including permission requests, which keeps the
        // approval inbox current. A failure here does not undo the session, so it is not reported as one.
        _ = try? await client.subscribe(sessionId: created.sessionId, afterSeq: 0)

        let needsApproval = await waitForApproval(client, sessionId: created.sessionId)
        return AgentSessionOutcome(serverID: selected, sessionId: created.sessionId, projectName: chosen.name,
                                   status: needsApproval ? .waitingForApproval : .running, detail: nil)
    }

    /// Polls the gateway's open approvals for the session until one shows, or the window ends.
    private func waitForApproval(_ client: GatewayClient, sessionId: String) async -> Bool {
        let end = ContinuousClock.now.advanced(by: approvalWindow)
        while true {
            if let approvals = try? await client.pendingApprovals(),
               approvals.contains(where: { $0.sessionId == sessionId }) {
                return true
            }
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func translating<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw Self.translate(error)
        }
    }

    /// Maps a gateway failure to the text the person sees. A lost connection is "can't reach your Mac".
    static func translate(_ error: Error) -> AgentSessionError {
        if let known = error as? AgentSessionError { return known }
        if let gateway = error as? GatewayError {
            if case .disconnected = gateway { return .unreachable }
            return .gateway(gateway.message)
        }
        return .gateway(error.localizedDescription)
    }
}

/// Runs `work` and gives up after `limit`. Throws `AgentSessionError.unreachable` on timeout. Work that is still
/// running after the timeout is not cancelled here; its result is dropped.
@MainActor
func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = ResumeOnce()
        Task { @MainActor in
            do {
                let value = try await work()
                gate.run { continuation.resume(returning: value) }
            } catch {
                gate.run { continuation.resume(throwing: error) }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            gate.run { continuation.resume(throwing: AgentSessionError.unreachable) }
        }
    }
}

/// Lets exactly one of two racing outcomes resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ action: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { action() }
    }
}
