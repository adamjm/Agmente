import AppIntents
import Foundation

/// Hands an answer from an intent to the app. The app sets it at launch. It is nil in any other process
/// (the widget), so the intents do nothing there. Returns true when the gateway accepted the answer.
public enum ApprovalAnswerRouter {
    public typealias Handler = @Sendable (_ approvalId: String, _ optionId: String, _ role: ApprovalOptionRole) async -> Bool

    public static var handler: Handler?
}

/// Why an answer from the Live Activity or a Shortcut was not sent. The intents throw it, so the person sees
/// the reason instead of a success that did nothing.
public enum ApprovalAnswerError: Error, CustomLocalizedStringResourceConvertible {
    /// The app is not running its answer path (the intent ran in another process, or the app has not launched).
    case appNotReady
    /// The gateway refused, or could not be reached, or the request is already closed.
    case notSent

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "Open ACP Code to answer this request."
        case .notSent: return "ACP Code could not send that answer. The request may already be closed."
        }
    }
}

/// Once, from the Dynamic Island or the Lock Screen. Requires an unlocked phone (authentication required).
public struct ApproveOnceIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Allow once"
    public static var description = IntentDescription("Allows this tool call once, for an approval shown in ACP Code.")
    public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Approval")
    public var approvalId: String

    @Parameter(title: "Option")
    public var optionId: String

    public init() {}

    public init(approvalId: String, optionId: String) {
        self.approvalId = approvalId
        self.optionId = optionId
    }

    public func perform() async throws -> some IntentResult {
        guard let handler = ApprovalAnswerRouter.handler else { throw ApprovalAnswerError.appNotReady }
        guard await handler(approvalId, optionId, .once) else { throw ApprovalAnswerError.notSent }
        return .result()
    }
}

/// Deny, from the Dynamic Island or the Lock Screen. Requires an unlocked phone (authentication required).
public struct DenyApprovalIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Deny"
    public static var description = IntentDescription("Denies this tool call, for an approval shown in ACP Code.")
    public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Approval")
    public var approvalId: String

    @Parameter(title: "Option")
    public var optionId: String

    public init() {}

    public init(approvalId: String, optionId: String) {
        self.approvalId = approvalId
        self.optionId = optionId
    }

    public func perform() async throws -> some IntentResult {
        guard let handler = ApprovalAnswerRouter.handler else { throw ApprovalAnswerError.appNotReady }
        guard await handler(approvalId, optionId, .deny) else { throw ApprovalAnswerError.notSent }
        return .result()
    }
}
