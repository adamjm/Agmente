import Combine
import Foundation
import ACPClient
import ACPCodeLiveApproval

/// Connects the approval inbox to the Live Activity and to the Once and Deny intents (la-decision, section 5).
/// One per process. It starts, updates and ends the activity whenever the selected gateway's open approvals
/// change, and when the app enters the foreground or the background.
@MainActor
final class ApprovalLiveActivityCoordinator {
    static let shared = ApprovalLiveActivityCoordinator()

    let controller = ApprovalActivityController()
    let answers = ApprovalAnswerService()

    private struct Context {
        let serverId: () -> UUID?
        let isConnected: () -> Bool
        let projectName: (String) -> String
    }

    private var context: Context?
    private var approvals: [GatewayApproval] = []
    private var isForeground = false
    private var inboxCancellable: AnyCancellable?
    /// Syncs run one after another, so two changes cannot race each other on the activity.
    private var queue: Task<Void, Never>?

    /// Called once at launch, so the intents can reach the app. The intents run in the app process
    /// (la-decision, section 7: verify on device).
    static func installAnswerRouter() {
        ApprovalAnswerRouter.handler = { approvalId, optionId, role in
            await ApprovalLiveActivityCoordinator.shared.answer(approvalId: approvalId, optionId: optionId, role: role)
        }
    }

    /// Called by the app model. Replaces any earlier binding. Ends activities from an earlier launch, which
    /// have no approval this process knows about yet.
    func bind(
        inbox: ApprovalsInboxModel,
        serverId: @escaping () -> UUID?,
        isConnected: @escaping () -> Bool,
        projectName: @escaping (String) -> String,
        client: @escaping () -> GatewayClient?
    ) {
        answers.clientProvider = client
        answers.onClosed = { [weak inbox] approvalId in inbox?.closed(approvalId: approvalId) }
        context = Context(serverId: serverId, isConnected: isConnected, projectName: projectName)
        inboxCancellable = inbox.$approvals.sink { [weak self] list in
            self?.approvals = list
            self?.resync()
        }
        enqueue { [controller] in await controller.end() }
    }

    /// Called from the scene phase handler. Entering the foreground re-checks the activity.
    func setForeground(_ value: Bool) {
        isForeground = value
        resync()
    }

    private func answer(approvalId: String, optionId: String, role: ApprovalOptionRole) async -> Bool {
        let outcome = await answers.answer(approvalId: approvalId, optionId: optionId, role: role)
        if outcome == .alreadyClosed {
            resync()
        }
        return outcome == .answered
    }

    private func resync() {
        guard let context else { return }
        let canStart = isForeground || context.isConnected()
        let content: ApprovalActivityStateMapper.Content?
        if let serverId = context.serverId() {
            content = ApprovalActivityStateMapper.content(
                for: approvals,
                serverId: serverId,
                now: Date(),
                projectName: context.projectName
            )
        } else {
            content = nil
        }
        let controller = self.controller
        enqueue { await controller.sync(content, canStart: canStart) }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
