import XCTest
import UserNotifications
import ACP
import ACPClient
@testable import ACPCode

/// Records what the notifier would do with UNUserNotificationCenter. It has no permission request.
final class FakeApprovalNotificationCenter: ApprovalNotificationCenter {
    var authorized = true
    var added: [UNNotificationRequest] = []
    var removed: [String] = []

    func isAuthorized() async -> Bool { authorized }
    func add(_ request: UNNotificationRequest) async throws { added.append(request) }
    func remove(identifiers: [String]) { removed += identifiers }
}

@MainActor
final class RecordingApprovalRemover: ApprovalNotificationRemoving {
    var closed: [String] = []
    func approvalClosed(approvalId: String) { closed.append(approvalId) }
}

@MainActor
final class LocalApprovalNotifierTests: XCTestCase {
    private let server = UUID(uuidString: "2F0C6E4A-1B7D-4C8E-9A55-0123456789AB")!

    private func approval(id: String = "acpcode-perm-1", title: String? = "npm test", kind: String? = "execute") -> GatewayApproval {
        var fields: [String: ACP.Value] = [:]
        if let title { fields["title"] = .string(title) }
        if let kind { fields["kind"] = .string(kind) }
        return GatewayApproval(approvalId: id, sessionId: "sess-1", projectId: "proj-1", toolCall: .object(fields), options: [], since: "2026-11-10T10:00:00.000Z")
    }

    // MARK: - The decision

    func testTheDecisionPostsOnlyInTheBackgroundWithoutRemotePushAndWithPermission() {
        for active in [true, false] {
            for remote in [true, false] {
                for authorized in [true, false] {
                    let expected = !active && !remote && authorized
                    XCTAssertEqual(
                        shouldPostLocalApprovalNotification(appIsActive: active, remotePushRegistered: remote, notificationsAuthorized: authorized),
                        expected,
                        "active=\(active) remote=\(remote) authorized=\(authorized)"
                    )
                }
            }
        }
    }

    // MARK: - The notification

    func testABackgroundApprovalPostsOneNotificationWithTheSummaryAndTheSessionLink() async {
        let center = FakeApprovalNotificationCenter()
        let notifier = ApprovalLocalNotifier(center: center)
        await notifier.approvalArrived(approval(), serverId: server, projectName: "Website", appIsActive: false)

        XCTAssertEqual(center.added.count, 1)
        let request = center.added[0]
        XCTAssertEqual(request.identifier, "approval.acpcode-perm-1")
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.title, "Website")
        XCTAssertEqual(request.content.body, "Approval needed: Run: npm test")
        XCTAssertEqual(request.content.categoryIdentifier, "APPROVAL")
        XCTAssertEqual(request.content.threadIdentifier, "sess-1")
        XCTAssertEqual(request.content.userInfo["sessionId"] as? String, "sess-1")
        XCTAssertEqual(request.content.userInfo["url"] as? String, DeepLink.session(serverId: server, sessionId: "sess-1").url.absoluteString)
    }

    func testTheSameApprovalIsNeverPostedTwice() async {
        let center = FakeApprovalNotificationCenter()
        let notifier = ApprovalLocalNotifier(center: center)
        await notifier.approvalArrived(approval(), serverId: server, projectName: "Website", appIsActive: false)
        await notifier.approvalArrived(approval(), serverId: server, projectName: "Website", appIsActive: false)
        XCTAssertEqual(center.added.count, 1)
    }

    func testAnActiveAppPostsNothing() async {
        let center = FakeApprovalNotificationCenter()
        await ApprovalLocalNotifier(center: center).approvalArrived(approval(), serverId: server, projectName: "W", appIsActive: true)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testARemotePushForTheServerPostsNothing() async {
        RemotePushRegistry.record(.sent, serverId: server)
        defer { RemotePushRegistry.record(.skippedNoPush, serverId: server) }
        let center = FakeApprovalNotificationCenter()
        await ApprovalLocalNotifier(center: center).approvalArrived(approval(), serverId: server, projectName: "W", appIsActive: false)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testWithoutPermissionNothingIsPosted() async {
        let center = FakeApprovalNotificationCenter()
        center.authorized = false
        await ApprovalLocalNotifier(center: center).approvalArrived(approval(), serverId: server, projectName: "W", appIsActive: false)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testAnApprovalWithNoTitleKeepsTheOldBody() async {
        let center = FakeApprovalNotificationCenter()
        await ApprovalLocalNotifier(center: center).approvalArrived(approval(title: nil, kind: nil), serverId: server, projectName: "W", appIsActive: false)
        XCTAssertEqual(center.added.first?.content.body, "Approval needed")
    }

    // MARK: - Removal

    func testAnAnsweredOrClosedApprovalRemovesItsNotification() async {
        let center = FakeApprovalNotificationCenter()
        let notifier = ApprovalLocalNotifier(center: center)
        await notifier.approvalArrived(approval(), serverId: server, projectName: "W", appIsActive: false)
        notifier.approvalClosed(approvalId: "acpcode-perm-1")
        XCTAssertEqual(center.removed, ["approval.acpcode-perm-1"])
    }

    func testAnApprovalNeverPostedHasNothingToRemove() {
        let center = FakeApprovalNotificationCenter()
        ApprovalLocalNotifier(center: center).approvalClosed(approvalId: "acpcode-perm-1")
        XCTAssertTrue(center.removed.isEmpty)
    }

    func testTheInboxTellsTheNotifierWhenAnApprovalCloses() {
        let remover = RecordingApprovalRemover()
        let inbox = ApprovalsInboxModel(notifications: remover)
        inbox.closed(approvalId: "acpcode-perm-7")
        XCTAssertEqual(remover.closed, ["acpcode-perm-7"])
    }

    // MARK: - The remote registry

    func testTheRegistryFollowsTheRegistrationResult() {
        let other = UUID()
        RecordingRegistryReset.reset([server, other])
        XCTAssertFalse(RemotePushRegistry.isRegistered(serverId: server))
        RemotePushRegistry.record(.sent, serverId: server)
        XCTAssertTrue(RemotePushRegistry.isRegistered(serverId: server))
        RemotePushRegistry.record(.failed("network"), serverId: server)
        XCTAssertTrue(RemotePushRegistry.isRegistered(serverId: server), "a transient failure keeps the earlier state")
        RemotePushRegistry.record(.skippedNoToken, serverId: server)
        XCTAssertFalse(RemotePushRegistry.isRegistered(serverId: server))
        RemotePushRegistry.record(.sent, serverId: other)
        RemotePushRegistry.record(.skippedNotAllowed, serverId: other)
        XCTAssertFalse(RemotePushRegistry.isRegistered(serverId: other))
    }
}

/// Clears the registry between tests (it is process-wide).
@MainActor
enum RecordingRegistryReset {
    static func reset(_ ids: [UUID]) {
        for id in ids { RemotePushRegistry.record(.skippedNoPush, serverId: id) }
    }
}
