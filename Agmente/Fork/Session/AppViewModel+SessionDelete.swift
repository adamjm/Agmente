import Foundation

extension AppViewModel {
    /// FR-36: deletes the selected session on the agent when it supports `session/delete`, then on
    /// this device. Throws when the agent refuses or the call fails; the session then stays.
    func deleteSessionOnAgent(_ sessionId: String) async throws {
        guard let serverViewModel = selectedServerViewModel else { return }
        try await serverViewModel.deleteSessionOnAgent(sessionId)
    }
}
