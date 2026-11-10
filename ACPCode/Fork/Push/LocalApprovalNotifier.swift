import Foundation
import UserNotifications
import ACP
import ACPClient
#if os(iOS)
import UIKit
#endif

/// Decides whether an approval that arrived over the live connection also gets a local notification (D-111).
///
/// Post only when the app is in the background, the gateway does not send this device a remote push for
/// the server (the push would be a second alert), and notifications are already allowed. This never asks
/// for permission. Pure, so every combination is tested.
func shouldPostLocalApprovalNotification(appIsActive: Bool, remotePushRegistered: Bool, notificationsAuthorized: Bool) -> Bool {
    !appIsActive && !remotePushRegistered && notificationsAuthorized
}

/// The part of UNUserNotificationCenter the notifier uses. A fake stands in for it in tests. There is no
/// method that asks for permission: this code path never does.
protocol ApprovalNotificationCenter {
    func isAuthorized() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func remove(identifiers: [String])
}

struct SystemApprovalNotificationCenter: ApprovalNotificationCenter {
    func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func remove(identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Called when an approval is answered or closed, so its local notification is removed.
@MainActor
protocol ApprovalNotificationRemoving: AnyObject {
    func approvalClosed(approvalId: String)
}

/// Posts and removes the local notification for a gateway approval (D-111).
@MainActor
final class ApprovalLocalNotifier: ApprovalNotificationRemoving {
    static let shared = ApprovalLocalNotifier()

    /// The category the app registers with no actions: answering stays in the app (D-009).
    static let categoryIdentifier = "APPROVAL"

    private let center: ApprovalNotificationCenter
    /// Approvals already posted in this launch, so a second refresh does not post them again.
    private var posted: Set<String> = []

    init(center: ApprovalNotificationCenter = SystemApprovalNotificationCenter()) {
        self.center = center
    }

    /// The request identifier for an approval. The same approval always uses the same identifier.
    static func identifier(forApproval approvalId: String) -> String { "approval.\(approvalId)" }

    /// Whether the app is in the foreground. The in-app UI and the Live Activity already show an approval then.
    static var appIsActive: Bool {
#if os(iOS)
        UIApplication.shared.applicationState == .active
#else
        true
#endif
    }

    /// Posts a notification for an approval that just arrived, if `shouldPostLocalApprovalNotification` says so.
    func approvalArrived(_ approval: GatewayApproval, serverId: UUID, projectName: String, appIsActive: Bool) async {
        guard !posted.contains(approval.approvalId) else { return }
        let authorized = await center.isAuthorized()
        guard shouldPostLocalApprovalNotification(
            appIsActive: appIsActive,
            remotePushRegistered: RemotePushRegistry.isRegistered(serverId: serverId),
            notificationsAuthorized: authorized
        ) else { return }

        let sessionId = approval.sessionId
        let content = UNMutableNotificationContent()
        content.title = projectName
        content.body = ApprovalNotificationText.body(kind: approval.kind, title: approval.toolCall["title"]?.stringValue ?? "")
        content.sound = .default
        content.threadIdentifier = sessionId
        content.categoryIdentifier = Self.categoryIdentifier
        // The tap path reads "sessionId" (ACPCodeAppDelegate); "url" is the session deep link (DeepLink).
        content.userInfo = [
            "sessionId": sessionId,
            "url": DeepLink.session(serverId: serverId, sessionId: sessionId).url.absoluteString,
        ]
        let request = UNNotificationRequest(
            identifier: Self.identifier(forApproval: approval.approvalId),
            content: content,
            trigger: nil
        )
        posted.insert(approval.approvalId)
        try? await center.add(request)
    }

    /// Removes the pending and delivered notification for an approval that was answered or closed. Only an
    /// approval this launch posted has one to remove, so the notification center is not called for the rest.
    func approvalClosed(approvalId: String) {
        guard posted.remove(approvalId) != nil else { return }
        center.remove(identifiers: [Self.identifier(forApproval: approvalId)])
    }
}

/// Which gateway servers hold this device's APNs token, as far as this launch knows (D-111). Set from the
/// result of each push registration with a gateway. In memory only: the token itself is not stored here.
@MainActor
enum RemotePushRegistry {
    private static var servers: Set<UUID> = []

    static func isRegistered(serverId: UUID) -> Bool { servers.contains(serverId) }

    /// Records a registration result. A sent token counts. A server that cannot take pushes, has no token, or
    /// is not allowed to send them no longer counts. A transient failure leaves the earlier state as it was.
    static func record(_ outcome: PushGatewaySync.Outcome, serverId: UUID) {
        switch outcome {
        case .sent: servers.insert(serverId)
        case .skippedNoPush, .skippedNoToken, .skippedNotAllowed: servers.remove(serverId)
        case .failed: break
        }
    }
}
