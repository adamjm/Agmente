import ActivityKit
import Foundation
import ACPCodeLiveApproval

/// Starts, updates and ends the approval Live Activity (la-decision, section 4). Main actor, like the app.
@MainActor
final class ApprovalActivityController {
    private var activity: Activity<ApprovalActivityAttributes>?
    private var shownApprovalId: String?
    private var alertGate = ApprovalAlertGate(minimumInterval: 3)

    /// Brings the activity in line with the open approvals. A nil `content` means none is open, so the activity
    /// ends. A new activity starts only when `canStart` is true: ActivityKit refuses a request from the background,
    /// so the caller passes true only in the foreground or while the gateway is connected.
    func sync(_ content: ApprovalActivityStateMapper.Content?, canStart: Bool, now: Date = Date()) async {
        guard let content else {
            await end()
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if activity == nil {
            activity = Activity<ApprovalActivityAttributes>.activities.first
        }
        let activityContent = ActivityContent(state: content.state, staleDate: content.staleDate)

        if let activity {
            let isNewApproval = content.state.approvalId != shownApprovalId
            let alert = isNewApproval && alertGate.allow(now: now) ? Self.alert(for: content.state) : nil
            await activity.update(activityContent, alertConfiguration: alert)
        } else if canStart {
            do {
                activity = try Activity.request(
                    attributes: ApprovalActivityAttributes(),
                    content: activityContent,
                    pushType: nil
                )
            } catch {
                print("[LiveApproval] could not start the activity: \(error.localizedDescription)")
            }
        }
        shownApprovalId = content.state.approvalId
    }

    /// Ends every approval activity this app owns, including one left by an earlier launch.
    func end() async {
        let all = Activity<ApprovalActivityAttributes>.activities
        activity = nil
        shownApprovalId = nil
        for item in all {
            await item.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// The alert text names the count and the project only. It never names a tool.
    private static func alert(for state: ApprovalActivityAttributes.ContentState) -> AlertConfiguration {
        let body = state.pendingCount == 1
            ? "1 waiting in \(state.projectName)"
            : "\(state.pendingCount) waiting in \(state.projectName)"
        return AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: "Approval needed"),
            body: LocalizedStringResource(stringLiteral: body),
            sound: .default
        )
    }
}
