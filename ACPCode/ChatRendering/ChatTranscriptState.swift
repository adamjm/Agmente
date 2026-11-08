import Foundation
import SwiftUI
import Observation
import ACP
import ACPClient

@MainActor
@Observable
final class ChatTranscriptState {
    var isAtBottom: Bool = true

    @ObservationIgnored
    weak var listView: HighPerformanceChatListView?

    @ObservationIgnored
    var scrollToBottomHandler: ((Bool) -> Void)?

    func scrollToBottom(animated: Bool = true) {
        if let listView {
            listView.scrollToBottom(animated: animated)
            return
        }
        scrollToBottomHandler?(animated)
    }
}

struct ChatEntryActionHandlers {
    var onACPPermissionResponse: ((ACP.ID, String) -> Void)?
    var onJSONRPCPermissionResponse: ((JSONRPCID, String) -> Void)?
    var onApproveRequest: ((JSONRPCID, Bool?) -> Void)?
    var onDeclineRequest: ((JSONRPCID) -> Void)?
    var onUndoFileChanges: (() -> Void)?
    var onReviewFileChanges: (([FileChangeSummaryItem]) -> Void)?
    /// Whether the file-change row of a message offers "Turn diff" (a gateway with git), and what it does.
    var canTurnDiff: ((UUID) -> Bool)?
    var onTurnDiff: ((UUID) -> Void)?
    /// Opens the sandboxed HTML preview for a fenced html block or an HTML resource (PLAN 5.4).
    var onPreviewHTML: ((String) -> Void)?

    static let none = ChatEntryActionHandlers()
}

struct ChatRendererConfig {
    var autoScrollTolerance: CGFloat = 4
    var maxMarkdownCharacters: Int = 20000
    var enablePerformanceLogging: Bool = false

    static let `default` = ChatRendererConfig()
}
