import Foundation
import ACP

/// The sessions of `_acpcode/sessions/index` with each session's usage (contract C1, D-093).
public struct GatewaySessionsWithUsage: Equatable, Sendable {
    public let sessions: [GatewaySession]
    /// Usage by session id, for the rows whose `usage` object is present and well formed. A session
    /// with no usage is absent from this map.
    public let usage: [String: GatewayUsage]

    public init(sessions: [GatewaySession], usage: [String: GatewayUsage]) {
        self.sessions = sessions
        self.usage = usage
    }
}

extension GatewayClient {
    /// `_acpcode/sessions/index` for one project or all, with the optional `usage` of each row (C1).
    /// Sessions decode exactly as `sessions(projectId:)` decodes them; a malformed `usage` is ignored.
    public func sessionsWithUsage(projectId: String? = nil) async throws -> GatewaySessionsWithUsage {
        var params: [String: ACP.Value] = [:]
        if let projectId { params["projectId"] = .string(projectId) }
        let result = try await call("_acpcode/sessions/index", .object(params))
        let rows = result["sessions"]
        let sessions = try decode([GatewaySession].self, from: rows, what: "sessions")
        var usage: [String: GatewayUsage] = [:]
        if case let .array(items)? = rows {
            for item in items {
                guard let sessionId = item["sessionId"]?.stringValue,
                      let figures = GatewayUsage(gatewayValue: item["usage"]) else { continue }
                usage[sessionId] = figures
            }
        }
        return GatewaySessionsWithUsage(sessions: sessions, usage: usage)
    }
}
