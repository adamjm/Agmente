import Foundation
import ACPClient

/// The state of the Connections screen (D-097): the client pairings waiting for the phone's answer and
/// the grants already made. Nothing changes without a person's tap. A row leaves the list only after
/// the gateway confirms the change, and the lists are read again on appear, on pull, and every few
/// seconds while the screen is visible (the view owns that timer; no push is used).
@MainActor
final class GatewayConnectionsModel: ObservableObject {
    /// The two scopes the approve sheet offers. One session is the default; it is the test scope.
    enum ScopeChoice: Equatable, Hashable, CaseIterable {
        case oneSession
        case allProjects
    }

    /// How often the view re-reads the lists while it is on screen.
    static let pollSeconds: UInt64 = 5

    @Published private(set) var pairings: [GatewayConnectorPairing] = []
    @Published private(set) var grants: [GatewayConnectorGrant] = []
    /// The sessions the one-session scope can pick from, newest first.
    @Published private(set) var sessions: [GatewaySession] = []
    @Published var selectedSessionId: String?
    /// Pairings and grants with a request in flight, so a second tap does not send it twice.
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var sessionsMessage: String?
    @Published private(set) var isLoading = false

    private let clientProvider: () -> GatewayClient?
    private var generation = 0
    /// Ids this screen has approved, denied or revoked. A list read that started before the answer
    /// must not bring the row back.
    private var resolved: Set<String> = []

    init(clientProvider: @escaping () -> GatewayClient?) {
        self.clientProvider = clientProvider
    }

    func isBusy(_ id: String) -> Bool { busy.contains(id) }

    /// The sentence a person sees for a failed gateway call. The raw error goes to the log, not the screen.
    /// A gateway without Claude connections answers -32601 (method not found). A refusal of the state, -32001,
    /// is the gateway's own sentence and is kept. Any other error gets the generic sentence.
    static func userMessage(for error: Error, log: (String) -> Void = { NSLog("%@", $0) }) -> String {
        log("Claude connections gateway error: \(error)")
        let generic = "The gateway could not finish this. Try again."
        guard let gatewayError = error as? GatewayError else { return generic }
        if gatewayError.isMethodNotFound { return "This gateway does not support Claude connections yet." }
        switch gatewayError {
        case .rpc(-32001, let message): return message
        case .disconnected: return "Not connected to the gateway."
        case .missingPairingCode: return gatewayError.message
        case .rpc, .invalidResponse, .sessionCreatedPromptNotSent: return generic
        }
    }

    /// The scope a choice means right now, or nil when one session is chosen and no session is picked.
    func scope(for choice: ScopeChoice) -> GatewayConnectorScope? {
        switch choice {
        case .allProjects:
            return .allProjects
        case .oneSession:
            guard let id = selectedSessionId, let session = sessions.first(where: { $0.sessionId == id }) else { return nil }
            return .oneSession(session)
        }
    }

    /// Reads the pairings and the grants. A failure keeps what was shown and says why.
    func refresh() async {
        guard let client = clientProvider() else {
            errorMessage = "Not connected to the gateway."
            return
        }
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let waiting = try await client.connectorPending()
            let granted = try await client.connectorGrants()
            guard mine == generation else { return }
            pairings = waiting.filter { !resolved.contains($0.pairingId) }
            grants = granted.filter { !resolved.contains($0.grantId) }
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            errorMessage = Self.userMessage(for: error)
        }
    }

    /// Reads the sessions for the one-session choice. The newest is picked when none is.
    func loadSessions() async {
        guard let client = clientProvider() else {
            sessionsMessage = "Not connected to the gateway."
            return
        }
        let mine = generation
        do {
            let list = try await client.sessions()
            guard mine == generation else { return }
            sessions = list.sorted { ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast) }
            sessionsMessage = nil
            if selectedSessionId == nil || !sessions.contains(where: { $0.sessionId == selectedSessionId }) {
                selectedSessionId = sessions.first?.sessionId
            }
        } catch {
            guard mine == generation else { return }
            sessionsMessage = Self.userMessage(for: error)
        }
    }

    /// Approves a pairing with the chosen scope, sending the row's code so the gateway can check it.
    /// Returns true when the gateway made the grant. A row with no code is refused here and nothing is sent.
    @discardableResult
    func approve(_ pairing: GatewayConnectorPairing, choice: ScopeChoice) async -> Bool {
        guard !pairing.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = GatewayError.missingPairingCode.message
            return false
        }
        guard let scope = scope(for: choice), !busy.contains(pairing.pairingId), let client = clientProvider() else { return false }
        let id = pairing.pairingId
        let mine = generation
        busy.insert(id)
        defer { if mine == generation { busy.remove(id) } }
        do {
            _ = try await client.approveConnectorPairing(pairingId: id, code: pairing.code, scope: scope)
            guard mine == generation else { return true }
            resolved.insert(id)
            pairings.removeAll { $0.pairingId == id }
            errorMessage = nil
            await reloadGrants(client: client)
            return true
        } catch {
            guard mine == generation else { return false }
            await refresh()
            errorMessage = Self.userMessage(for: error)
            return false
        }
    }

    /// Refuses a pairing. The client's page is told, and the row leaves the list.
    func deny(_ pairing: GatewayConnectorPairing) async {
        let id = pairing.pairingId
        guard !busy.contains(id), let client = clientProvider() else { return }
        let mine = generation
        busy.insert(id)
        defer { if mine == generation { busy.remove(id) } }
        do {
            try await client.denyConnectorPairing(pairingId: id)
            guard mine == generation else { return }
            resolved.insert(id)
            pairings.removeAll { $0.pairingId == id }
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            await refresh()
            errorMessage = Self.userMessage(for: error)
        }
    }

    /// Revokes a grant. The client loses access at once and must pair again to get it back.
    func revoke(_ grant: GatewayConnectorGrant) async {
        let id = grant.grantId
        guard !busy.contains(id), let client = clientProvider() else { return }
        let mine = generation
        busy.insert(id)
        defer { if mine == generation { busy.remove(id) } }
        do {
            try await client.revokeConnectorGrant(grantId: id)
            guard mine == generation else { return }
            resolved.insert(id)
            grants.removeAll { $0.grantId == id }
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            await refresh()
            errorMessage = Self.userMessage(for: error)
        }
    }

    private func reloadGrants(client: GatewayClient) async {
        if let granted = try? await client.connectorGrants() {
            grants = granted.filter { !resolved.contains($0.grantId) }
        }
    }

    /// "4:59 left", or "Expired" once the time has passed. Nil expiry (a time the app cannot read) says so.
    static func timeLeftText(expiresAt: Date?, now: Date) -> String {
        guard let expiresAt else { return "Time unknown" }
        let seconds = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        if seconds <= 0 { return "Expired" }
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    /// A six-digit code as it is read aloud: "482 913".
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<middle]) \(code[middle...])"
    }
}
