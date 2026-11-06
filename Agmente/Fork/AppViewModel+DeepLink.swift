import Foundation

extension AppViewModel {
    /// Reads a link and selects the server it names. The caller then opens the session. A link to a
    /// server this device does not know changes nothing.
    func resolveDeepLink(_ url: URL) -> DeepLinkOutcome {
        guard let link = DeepLink.parse(url) else { return .invalid }
        switch link {
        case .session(let serverId, let sessionId):
            guard servers.contains(where: { $0.id == serverId }) else { return .unknownServer }
            
            if selectedServerId != serverId { selectServer(serverId) }
            return .open(sessionId: sessionId)
        }
    }
}
