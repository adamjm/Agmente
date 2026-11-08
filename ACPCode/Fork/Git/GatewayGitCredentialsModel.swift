import Foundation
import ACPClient

/// Git support and the credential profiles of the selected gateway (D-105). It holds metadata only. A token
/// is passed to `save` once, and is not kept here or anywhere else in the app.
@MainActor
final class GatewayGitCredentialsModel: ObservableObject {
    /// Whether the gateway has the git methods. Detected by calling `_acpcode/git/credentials/list`: a
    /// gateway without them answers -32601 (`extensions` does not list git, so the call is the only signal).
    enum Support: Equatable {
        case checking
        case supported
        case unsupported
        /// Any other failure, with `loadMessage` saying what. The Git controls stay usable.
        case unknown
    }

    enum SaveOutcome: Equatable {
        case saved(id: String)
        /// Refused before anything was sent (the connection is not wss, or a field is invalid).
        case refused(String)
        case failed(String)
    }

    @Published private(set) var support: Support = .checking
    @Published private(set) var credentials: [GatewayGitCredential] = []
    @Published private(set) var loadMessage: String?
    @Published private(set) var isBusy = false

    private let clientProvider: () -> GatewayClient?
    /// The scheme of the connection the person chose for this server ("wss" or "ws").
    let connectionScheme: String

    init(clientProvider: @escaping () -> GatewayClient?, connectionScheme: String = "wss") {
        self.clientProvider = clientProvider
        self.connectionScheme = connectionScheme
    }

    /// False over ws:// (any scheme but wss): a secret is never entered or sent (D-105).
    var canEnterSecrets: Bool { GatewayGitSecretPolicy.allowsSecret(overScheme: connectionScheme) }

    /// Loads the profiles (metadata only) and sets `support`.
    func load() async {
        guard let client = clientProvider() else {
            support = .unknown
            loadMessage = "Not connected to the gateway."
            return
        }
        do {
            credentials = try await client.gitCredentials()
            support = .supported
            loadMessage = nil
        } catch let error as GatewayError where error.isMethodNotFound {
            credentials = []
            support = .unsupported
            loadMessage = nil
        } catch {
            support = .unknown
            loadMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }

    /// Stores a token as a new profile (`id` nil) or replaces the token of `id`. The token is an argument
    /// only: the caller clears its own copy once this returns, whatever the outcome.
    func save(id: String?, name: String, host: String, token: String) async -> SaveOutcome {
        guard GatewayGitSecretPolicy.allowsSecret(overScheme: connectionScheme) else {
            return .refused(GatewayGitSecretPolicy.insecureMessage)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = GatewayGitCredentialRules.nameProblem(trimmedName, existing: credentials, replacing: id) {
            return .refused(problem)
        }
        if let problem = GatewayGitCredentialRules.hostProblem(host) { return .refused(problem) }
        if let problem = GatewayGitCredentialRules.tokenProblem(token) { return .refused(problem) }
        guard let client = clientProvider() else { return .failed("Not connected to the gateway.") }
        isBusy = true
        defer { isBusy = false }
        do {
            let savedId = try await client.setGitCredential(id: id, name: trimmedName, host: host, token: token)
            await load()
            return .saved(id: savedId)
        } catch {
            return .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }

    /// Deletes a profile and its token. Returns the failure text, or nil on success.
    func delete(_ credential: GatewayGitCredential) async -> String? {
        guard let client = clientProvider() else { return "Not connected to the gateway." }
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.deleteGitCredential(id: credential.id)
            await load()
            return nil
        } catch {
            return (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }
}
