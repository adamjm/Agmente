import Foundation

/// Links into the app: `agmente://session/<server id>/<session id>` opens a session (PLAN 3.20).
///
/// Any app or web page can open this URL, so a link only ever navigates: it opens a session the
/// person could open by hand. It never sends a prompt, answers an approval or changes a setting.
/// The parser is strict: a wrong scheme, host, id or an extra path part is refused.
enum DeepLink: Equatable {
    case session(serverId: UUID, sessionId: String)

    static let scheme = "agmente"
    static let maxSessionIdLength = 200

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "session",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let serverId = UUID(uuidString: parts[0]), isValidSessionId(parts[1]) else { return nil }
        return .session(serverId: serverId, sessionId: parts[1])
    }

    /// The link for a session. `parse(link.url)` gives the link back.
    var url: URL {
        switch self {
        case .session(let serverId, let sessionId):
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove("/")
            let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) ?? sessionId
            return URL(string: "\(Self.scheme)://session/\(serverId.uuidString)/\(encoded)")!
        }
    }

    static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty
            && id.count <= maxSessionIdLength
            && !id.contains("/")
            && id.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// The session id in a push notification's payload (D-038: `sessionId` and `event`, nothing else
    /// that matters here). The payload names no server, so the caller says which one it came from.
    static func fromPush(userInfo: [AnyHashable: Any], serverId: UUID) -> DeepLink? {
        guard let sessionId = userInfo["sessionId"] as? String, isValidSessionId(sessionId) else { return nil }
        return .session(serverId: serverId, sessionId: sessionId)
    }
}

enum DeepLinkOutcome: Equatable {
    /// Open this session on the (now selected) server.
    case open(sessionId: String)
    /// Not a link this app understands.
    case invalid
    /// A link to a server this device does not have.
    case unknownServer
}
