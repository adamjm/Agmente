import Foundation
import ACPClient
import ACPCodeLiveApproval

/// What happened to an answer sent from the Live Activity.
enum ApprovalAnswerOutcome: Equatable {
    case answered
    /// The gateway no longer lists the approval (answered elsewhere, timed out, or cancelled).
    case alreadyClosed
    /// Nothing was sent, or the gateway refused. The approval stays open for the app.
    case notSent(String)
}

/// Answers an approval from the Live Activity through the gateway's existing `_acpcode/approvals/answer` call
/// (the same call the inbox uses, D-040). It checks first that the approval is still open and that the chosen
/// option still has the role the intent asked for, so an `allow_always` option is never sent from the island.
@MainActor
final class ApprovalAnswerService {
    /// The gateway client of the selected server, or nil when none is connected.
    var clientProvider: (() -> GatewayClient?)?
    /// Called once an approval is closed, so the inbox drops it.
    var onClosed: ((String) -> Void)?

    func answer(approvalId: String, optionId: String, role: ApprovalOptionRole) async -> ApprovalAnswerOutcome {
        guard let client = clientProvider?() else {
            return .notSent("Not connected to the gateway")
        }

        let open: [GatewayApproval]
        do {
            open = try await client.pendingApprovals()
        } catch {
            return .notSent(Self.message(error))
        }
        guard let approval = open.first(where: { $0.approvalId == approvalId }) else {
            onClosed?(approvalId)
            return .alreadyClosed
        }
        guard let option = approval.options.first(where: { $0.optionId == optionId }),
              ApprovalOptionMapping.role(forKind: option.kind) == role else {
            return .notSent("That choice is no longer offered")
        }

        do {
            try await client.answerApproval(approvalId: approvalId, optionId: optionId)
            onClosed?(approvalId)
            return .answered
        } catch let error as GatewayError where error.isAlreadyClosed {
            onClosed?(approvalId)
            return .alreadyClosed
        } catch {
            return .notSent(Self.message(error))
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? GatewayError)?.message ?? error.localizedDescription
    }
}
