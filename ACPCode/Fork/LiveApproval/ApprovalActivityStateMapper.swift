import Foundation
import ACPClient
import ACPCodeLiveApproval

/// The Live Activity content for the open approvals of one gateway (la-decision, section 4). Pure: the only
/// clock is the `now` it is given, so the rules can be tested. The card shows the count, the project of the
/// oldest approval and the session link. It never reads an approval's title, command or raw input.
enum ApprovalActivityStateMapper {
    /// The activity goes stale this long after it was last checked.
    static let staleAfter: TimeInterval = 5 * 60
    /// The gateway's default approval timeout (`limits.approvalTimeoutSeconds`, D-031: 12 h).
    static let approvalTimeout: TimeInterval = 43_200

    struct Content: Equatable {
        let state: ApprovalActivityAttributes.ContentState
        let staleDate: Date
    }

    /// Nil when no approval is open, which means the activity should end.
    static func content(
        for approvals: [GatewayApproval],
        serverId: UUID,
        now: Date,
        projectName: (String) -> String
    ) -> Content? {
        let ordered = approvals.sorted { ($0.sinceDate ?? .distantFuture) < ($1.sinceDate ?? .distantFuture) }
        guard let oldest = ordered.first else { return nil }

        let state = ApprovalActivityAttributes.ContentState(
            pendingCount: approvals.count,
            projectName: projectName(oldest.projectId),
            approvalId: oldest.approvalId,
            allowOnceOptionId: oldest.options.first { ApprovalOptionMapping.role(forKind: $0.kind) == .once }?.optionId,
            denyOptionId: oldest.options.first { ApprovalOptionMapping.role(forKind: $0.kind) == .deny }?.optionId,
            openLink: openLink(serverId: serverId, sessionId: oldest.sessionId)
        )

        let since = oldest.sinceDate ?? now
        let checked = max(now, since)
        let stale = min(checked.addingTimeInterval(staleAfter), since.addingTimeInterval(approvalTimeout))
        return Content(state: state, staleDate: stale)
    }

    /// The Open button's link: the existing session deep link (D-041). Nil when the session id is not a valid link part.
    static func openLink(serverId: UUID, sessionId: String) -> String? {
        guard DeepLink.isValidSessionId(sessionId) else { return nil }
        return DeepLink.session(serverId: serverId, sessionId: sessionId).url.absoluteString
    }
}
