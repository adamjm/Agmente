import Foundation
import ACPClient

// The record access of a gateway server (D-106): the re-attach load and removal from this phone. There is no delete
// on the agent here, and `session/delete` is never sent for a record the gateway does not know.
extension ServerViewModel: GatewayRecordAccess {
    func loadSession(sessionId: String, cwd: String) async throws {
        try await loadGatewaySessionOnAgent(sessionId: sessionId, cwd: cwd)
    }

    func removeFromPhone(sessionId: String) {
        deleteSession(sessionId)
    }
}
