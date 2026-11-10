import Foundation
import ACPClient

/// The gateway's open approvals for the selected server (FR-22, D-031): what each device must answer.
/// The app answers only when a person taps an option. An approval that someone else closed first is
/// removed with a note; any other failure keeps the row so the person can try again.
@MainActor
final class ApprovalsInboxModel: ObservableObject {
    @Published private(set) var approvals: [GatewayApproval] = []
    /// Approvals with an answer on its way, so a second tap does not send it twice.
    @Published private(set) var answering: Set<String> = []
    /// Said once after an approval turned out to be closed already ("answered elsewhere", "timed out").
    @Published private(set) var notice: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private var clientProvider: (() -> GatewayClient?)?
    private var generation = 0
    /// Told when an approval is closed, so its local notification is removed (D-111).
    private let notifications: ApprovalNotificationRemoving

    init(notifications: ApprovalNotificationRemoving? = nil) {
        self.notifications = notifications ?? ApprovalLocalNotifier.shared
    }

    var count: Int { approvals.count }

    func configure(clientProvider: (() -> GatewayClient?)?) {
        generation += 1
        self.clientProvider = clientProvider
        approvals = []
        answering = []
        notice = nil
        errorMessage = nil
        isLoading = false
    }

    func clearNotice() { notice = nil }

    func refresh() async {
        guard let client = clientProvider?() else { return }
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let list = try await client.pendingApprovals()
            guard mine == generation else { return }
            let open = Set(list.map(\.approvalId))
            for gone in approvals where !open.contains(gone.approvalId) { notifications.approvalClosed(approvalId: gone.approvalId) }
            approvals = list
            errorMessage = nil
        } catch {
            guard mine == generation else { return }
            errorMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }

    /// The gateway told us an approval is closed (an `approval_answered` event): drop it.
    func closed(approvalId: String) {
        approvals.removeAll { $0.approvalId == approvalId }
        answering.remove(approvalId)
        notifications.approvalClosed(approvalId: approvalId)
    }

    func answer(_ approval: GatewayApproval, option: GatewayApprovalOption) async {
        await send(approval) { try await $0.answerApproval(approvalId: approval.approvalId, optionId: option.optionId) }
    }

    func cancel(_ approval: GatewayApproval) async {
        await send(approval) { try await $0.cancelApproval(approvalId: approval.approvalId) }
    }

    private func send(_ approval: GatewayApproval, _ action: (GatewayClient) async throws -> Void) async {
        guard let client = clientProvider?(), !answering.contains(approval.approvalId) else { return }
        let mine = generation
        answering.insert(approval.approvalId)
        defer { if mine == generation { answering.remove(approval.approvalId) } }
        do {
            try await action(client)
            guard mine == generation else { return }
            closed(approvalId: approval.approvalId)
            errorMessage = nil
        } catch let error as GatewayError where error.isAlreadyClosed {
            guard mine == generation else { return }
            closed(approvalId: approval.approvalId)
            notice = "Already closed: \(error.message)"
        } catch {
            guard mine == generation else { return }
            errorMessage = (error as? GatewayError)?.message ?? error.localizedDescription
        }
    }
}
