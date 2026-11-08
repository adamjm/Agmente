import Foundation
import ACP

// The approval queue (SPEC 6.2, DECISIONS D-031). The app never answers on its own: every answer
// here is a person's choice, sent through `_acpcode/approvals/answer`.

public struct GatewayApprovalOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let optionId: String
    public let name: String
    public let kind: String

    public var id: String { optionId }

    public init(optionId: String, name: String, kind: String) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }

    /// True for the options that let the agent go ahead (`allow_once`, `allow_always`).
    public var isAllow: Bool { kind.hasPrefix("allow") }
}

public struct GatewayApproval: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let approvalId: String
    public let sessionId: String
    public let projectId: String
    /// The agent's tool call as the gateway stored it.
    public let toolCall: ACP.Value
    public let options: [GatewayApprovalOption]
    /// ISO 8601 UTC with milliseconds.
    public let since: String

    public var id: String { approvalId }

    public init(approvalId: String, sessionId: String, projectId: String, toolCall: ACP.Value, options: [GatewayApprovalOption], since: String) {
        self.approvalId = approvalId
        self.sessionId = sessionId
        self.projectId = projectId
        self.toolCall = toolCall
        self.options = options
        self.since = since
    }

    public var title: String { toolCall["title"]?.stringValue ?? "Tool call" }
    public var kind: String? { toolCall["kind"]?.stringValue }
    public var sinceDate: Date? { GatewayDates.parse(since) }

    /// The command or input the agent wants to run, when the tool call carries one, for the card.
    public var detail: String? {
        guard let input = toolCall["rawInput"] else { return nil }
        if let text = input.stringValue { return text }
        if let command = input["command"]?.stringValue { return command }
        return nil
    }
}

public extension GatewayError {
    /// `-32001`: someone else, a timeout, a cancel or an agent exit closed the approval first (D-031).
    var isAlreadyClosed: Bool {
        if case .rpc(let code, _) = self { return code == -32001 }
        return false
    }
}

public extension GatewayClient {
    /// `_acpcode/approvals/pending`: every open approval, oldest first.
    func pendingApprovals() async throws -> [GatewayApproval] {
        let result = try await call("_acpcode/approvals/pending", .object([:]))
        return try decode([GatewayApproval].self, from: result["approvals"], what: "approvals")
    }

    /// `_acpcode/approvals/answer` with a chosen option. Throws `GatewayError.rpc(-32001, reason)` when
    /// the approval was closed already.
    func answerApproval(approvalId: String, optionId: String) async throws {
        _ = try await call("_acpcode/approvals/answer", .object(["approvalId": .string(approvalId), "optionId": .string(optionId)]))
    }

    /// `_acpcode/approvals/answer` with `cancelled: true`: the agent is told the request was cancelled.
    func cancelApproval(approvalId: String) async throws {
        _ = try await call("_acpcode/approvals/answer", .object(["approvalId": .string(approvalId), "cancelled": .bool(true)]))
    }
}
