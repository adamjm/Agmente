#if canImport(UIKit)
import UIKit
import ListViewKit
import MarkdownView
import ACP
import ACPClient

enum RowType {
    case userText
    case userImages
    case assistantMarkdown
    case assistantThought
    case assistantPlan
    case toolCall
    case fileChanges
    case media
    case system
    case error
    case streaming
}

enum MarkdownStyle {
    case assistant
    case thought
    case plan

    var backgroundColor: UIColor {
        switch self {
        case .assistant:
            return UIColor.systemGray6
        case .thought:
            return UIColor.systemGray6
        case .plan:
            return UIColor.systemBlue.withAlphaComponent(0.08)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .assistant, .thought, .plan:
            return 10
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .assistant:
            return 8
        case .thought, .plan:
            return 10
        }
    }
}

final class HighPerformanceChatListView: UIView {
    static let rowInsets = UIEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)
    private static let thoughtExpandedHashSalt = 0x5F3759DF
    private let updateQueue = DispatchQueue(label: "agmente.chat.render.queue", qos: .userInteractive)

    private lazy var listView: ListViewKit.ListView = .init()
    private lazy var dataSource: ListViewDiffableDataSource<ChatEntry> = .init(listView: listView)

    private let mapper = ChatEntryMapper()
    private let markdownCache = ChatMarkdownPackageCache()
    private let heightCache = ChatHeightCache()

    private lazy var sizingLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        return label
    }()

    private lazy var sizingMarkdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    private var rawEntries: [ChatEntry] = []
    private var entries: [ChatEntry] = []
    private var renderedEntries: [ChatEntry] = []
    private var pendingEntries: [ChatEntry]?
    private var pendingEntriesAnimated: Bool = false
    private var pendingScrollToBottomAnimated: Bool = false
    private var expandedThoughtEntryIds: Set<String> = []
    private var isAutoScrollingToBottom = true
    private var autoScrollTolerance: CGFloat = 4
    private var lastReportedAtBottom: Bool?

    var actionHandlers: ChatEntryActionHandlers = .none
    var config: ChatRendererConfig = .default {
        didSet {
            autoScrollTolerance = config.autoScrollTolerance
        }
    }

    var onAtBottomChanged: ((Bool) -> Void)?

    private(set) var theme: MarkdownTheme = .default {
        didSet {
            listView.reloadData()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        autoScrollTolerance = config.autoScrollTolerance

        listView.delegate = self
        listView.adapter = self
        listView.backgroundColor = .clear
        listView.alwaysBounceVertical = true
        listView.alwaysBounceHorizontal = false
        listView.showsVerticalScrollIndicator = true
        listView.showsHorizontalScrollIndicator = false
        listView.contentInsetAdjustmentBehavior = .never

        addSubview(listView)
        listView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: trailingAnchor),
            listView.topAnchor.constraint(equalTo: topAnchor),
            listView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
    }

    func updateContentInsets(_ insets: UIEdgeInsets) {
        listView.contentInset = insets
        listView.scrollIndicatorInsets = insets
    }

    func render(
        messages: [ChatMessage],
        animated: Bool = true,
        scrollToBottomAnimated: Bool? = nil
    ) {
        let scrollToBottomAnimated = scrollToBottomAnimated ?? animated
        let theme = self.theme
        let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
        updateQueue.async { [weak self] in
            guard let self else { return }
            let newEntries = mapper.entries(from: messages)

            for entry in newEntries where entry.kind == .assistantMarkdown || entry.kind == .assistantThought || entry.kind == .assistantPlan {
                guard !entry.text.isEmpty else { continue }
                let entryTheme = entry.kind == .assistantThought ? thoughtTheme : theme
                _ = markdownCache.package(for: entry.id, content: entry.text, theme: entryTheme)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rawEntries = newEntries
                self.pruneExpandedThoughtState(using: newEntries)
                let visibleEntries = self.visibleEntries(from: newEntries)
                let diff = ChatRenderDiff.make(old: self.renderedEntries, new: visibleEntries)
                if diff.isEmpty {
                    self.flushPendingEntriesIfPossible()
                    return
                }
                self.applyEntries(
                    visibleEntries,
                    animated: animated,
                    scrollToBottomAnimated: scrollToBottomAnimated
                )
            }
        }
    }

    func scrollToBottom(animated: Bool = true) {
        let target = listView.maximumContentOffset
        if abs(listView.contentOffset.y - target.y) <= 0.5 {
            isAutoScrollingToBottom = true
            reportAtBottomIfChanged(true)
            return
        }
        if animated {
            listView.scroll(to: target)
        } else {
            listView.setContentOffset(target, animated: false)
        }
        isAutoScrollingToBottom = true
        reportAtBottomIfChanged(true)
    }

    private func updateAutoScrollingFromCurrentOffset() {
        let isNearBottom = isContentOffsetNearBottom()
        if isNearBottom {
            isAutoScrollingToBottom = true
        }
        reportAtBottomIfChanged(isNearBottom)
        flushPendingEntriesIfPossible()
    }

    private func isContentOffsetNearBottom() -> Bool {
        abs(listView.contentOffset.y - listView.maximumContentOffset.y) <= autoScrollTolerance
    }

    private func reportAtBottomIfChanged(_ isAtBottom: Bool) {
        guard lastReportedAtBottom != isAtBottom else { return }
        lastReportedAtBottom = isAtBottom
        onAtBottomChanged?(isAtBottom)
    }

    private func isThoughtExpanded(for entry: ChatEntry) -> Bool {
        entry.isStreaming || expandedThoughtEntryIds.contains(entry.id)
    }

    private func pruneExpandedThoughtState(using entries: [ChatEntry]) {
        let validIds = Set(entries.lazy.filter { $0.kind == .assistantThought }.map(\.id))
        expandedThoughtEntryIds.formIntersection(validIds)
    }

    private func visibleEntries(from rawEntries: [ChatEntry]) -> [ChatEntry] {
        rawEntries.map { entry in
            guard entry.kind == .assistantThought else { return entry }
            let expanded = isThoughtExpanded(for: entry)
            if expanded {
                return entry.withContentHashSalt(Self.thoughtExpandedHashSalt)
            }
            return entry
        }
    }

    private func toggleThoughtExpansion(entryId: String) {
        guard let entry = rawEntries.first(where: { $0.id == entryId && $0.kind == .assistantThought }) else {
            return
        }
        guard !entry.isStreaming else { return }

        if expandedThoughtEntryIds.contains(entryId) {
            expandedThoughtEntryIds.remove(entryId)
        } else {
            expandedThoughtEntryIds.insert(entryId)
        }

        let visibleEntries = visibleEntries(from: rawEntries)
        let diff = ChatRenderDiff.make(old: renderedEntries, new: visibleEntries)
        guard !diff.isEmpty else { return }
        heightCache.removeAll()
        applyEntries(
            visibleEntries,
            animated: true,
            scrollToBottomAnimated: true
        )
    }

    private func applyEntries(
        _ visibleEntries: [ChatEntry],
        animated: Bool,
        scrollToBottomAnimated: Bool
    ) {
        if shouldDeferEntriesApplication() {
            pendingEntries = visibleEntries
            pendingEntriesAnimated = pendingEntriesAnimated || animated
            pendingScrollToBottomAnimated = pendingScrollToBottomAnimated || scrollToBottomAnimated
            return
        }

        pendingEntries = nil
        pendingEntriesAnimated = false
        pendingScrollToBottomAnimated = false
        renderedEntries = visibleEntries
        entries = visibleEntries
        dataSource.applySnapshot(using: visibleEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: scrollToBottomAnimated)
        }
    }

    private func shouldDeferEntriesApplication() -> Bool {
        if isAutoScrollingToBottom {
            return false
        }
        return listView.isTracking || listView.isDragging || listView.isDecelerating
    }

    private func flushPendingEntriesIfPossible() {
        guard !shouldDeferEntriesApplication() else { return }
        guard let pendingEntries else { return }
        let animated = pendingEntriesAnimated
        let scrollToBottomAnimated = pendingScrollToBottomAnimated
        self.pendingEntries = nil
        pendingEntriesAnimated = false
        pendingScrollToBottomAnimated = false

        let diff = ChatRenderDiff.make(old: renderedEntries, new: pendingEntries)
        guard !diff.isEmpty else { return }

        renderedEntries = pendingEntries
        entries = pendingEntries
        dataSource.applySnapshot(using: pendingEntries, animatingDifferences: animated)
        if isAutoScrollingToBottom {
            scrollToBottom(animated: scrollToBottomAnimated)
        }
    }

    private func boundingHeight(for text: String, font: UIFont, width: CGFloat, lineLimit: Int = 0) -> CGFloat {
        sizingLabel.font = font
        sizingLabel.numberOfLines = lineLimit
        sizingLabel.text = text
        return ceil(sizingLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static func makeThoughtMarkdownTheme(from baseTheme: MarkdownTheme) -> MarkdownTheme {
        var thoughtTheme = baseTheme
        let thoughtBodyFont = baseTheme.fonts.footnote.withWeight(.medium)
        thoughtTheme.align(to: thoughtBodyFont.pointSize)
        thoughtTheme.fonts.body = thoughtBodyFont
        thoughtTheme.fonts.bold = thoughtBodyFont
        thoughtTheme.fonts.italic = thoughtBodyFont
        thoughtTheme.fonts.footnote = thoughtBodyFont
        thoughtTheme.fonts.codeInline = UIFont.monospacedSystemFont(ofSize: thoughtBodyFont.pointSize, weight: .medium)
        thoughtTheme.fonts.code = UIFont.monospacedSystemFont(
            ofSize: ceil(thoughtBodyFont.pointSize * MarkdownTheme.codeScale),
            weight: .medium
        )
        return thoughtTheme
    }
}

extension HighPerformanceChatListView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isAutoScrollingToBottom = false
        reportAtBottomIfChanged(false)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateAutoScrollingFromCurrentOffset()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateAutoScrollingFromCurrentOffset()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportAtBottomIfChanged(isContentOffsetNearBottom())
    }
}

extension HighPerformanceChatListView: ListViewAdapter {
    func listView(_ listView: ListViewKit.ListView, rowKindFor item: ItemType, at index: Int) -> RowKind {
        guard let entry = item as? ChatEntry else {
            assertionFailure("Unexpected item type")
            return RowType.system
        }

        switch entry.kind {
        case .userText:
            return RowType.userText
        case .userImages:
            return RowType.userImages
        case .assistantMarkdown:
            return RowType.assistantMarkdown
        case .assistantThought:
            return RowType.assistantThought
        case .assistantPlan:
            return RowType.assistantPlan
        case .toolCall:
            return RowType.toolCall
        case .fileChanges:
            return RowType.fileChanges
        case .media:
            return RowType.media
        case .system:
            return RowType.system
        case .error:
            return RowType.error
        case .streamingIndicator:
            return RowType.streaming
        }
    }

    func listViewMakeRow(for kind: RowKind) -> ListViewKit.ListRowView {
        guard let kind = kind as? RowType else {
            return ListRowView()
        }

        switch kind {
        case .userText:
            return UserTextRowView()
        case .userImages:
            return UserImagesRowView()
        case .assistantMarkdown:
            return MarkdownRowView(style: .assistant)
        case .assistantThought:
            return ThoughtRowView()
        case .assistantPlan:
            return MarkdownRowView(style: .plan)
        case .toolCall:
            return ToolCallRowView()
        case .fileChanges:
            return FileChangesRowView()
        case .media:
            return ForkMediaRowView()
        case .system:
            return SystemRowView(isError: false)
        case .error:
            return SystemRowView(isError: true)
        case .streaming:
            return StreamingIndicatorRowView()
        }
    }

    func listView(_ listView: ListViewKit.ListView, heightFor item: ItemType, at index: Int) -> CGFloat {
        guard let entry = item as? ChatEntry else {
            return 44
        }

        let width = max(0, listView.bounds.width - Self.rowInsets.left - Self.rowInsets.right)
        if width <= 0 {
            return 0
        }

        if let cached = heightCache.height(for: entry, width: width) {
            return cached
        }

        let height: CGFloat
        switch entry.kind {
        case .userText:
            let maxBubbleWidth = max(0, width - 50)
            let textWidth = max(0, maxBubbleWidth - 20)
            let textHeight = boundingHeight(for: entry.text, font: .preferredFont(forTextStyle: .callout), width: textWidth)
            height = textHeight + 14

        case .userImages:
            height = 80

        case .assistantMarkdown:
            sizingMarkdownView.theme = theme
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.assistant.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.assistant.verticalPadding * 2)

        case .assistantPlan:
            sizingMarkdownView.theme = theme
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            sizingMarkdownView.setMarkdownManually(package)
            let markdownWidth = max(0, width - (MarkdownStyle.plan.horizontalPadding * 2))
            let size = sizingMarkdownView.boundingSize(for: markdownWidth)
            height = ceil(size.height) + (MarkdownStyle.plan.verticalPadding * 2)

        case .assistantThought:
            let isExpanded = isThoughtExpanded(for: entry)
            if isExpanded {
                let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
                sizingMarkdownView.theme = thoughtTheme
                let package = markdownCache.package(for: entry.id, content: entry.text, theme: thoughtTheme)
                sizingMarkdownView.setMarkdownManually(package)
                let markdownWidth = max(0, width - (ThoughtRowView.horizontalPadding * 2))
                let markdownSize = sizingMarkdownView.boundingSize(for: markdownWidth)
                height = ThoughtRowView.collapsedHeight + ThoughtRowView.contentSpacing + ceil(markdownSize.height) + ThoughtRowView.bottomPadding
            } else {
                height = ThoughtRowView.collapsedHeight
            }

        case .toolCall:
            let payload = ToolCallRowView.Payload(entry: entry)
            height = ToolCallRowView.estimatedHeight(for: payload, width: width)

        case .fileChanges:
            height = FileChangesRowView.estimatedHeight(for: entry.fileChanges, width: width)

        case .media:
            height = entry.media.map { ForkMediaRowView.height(for: $0, width: width) } ?? 0

        case .system, .error:
            let textHeight = boundingHeight(for: entry.text, font: .preferredFont(forTextStyle: .footnote), width: width - 16)
            height = textHeight + 16

        case .streamingIndicator:
            height = 34
        }

        let finalHeight = height + Self.rowInsets.bottom
        heightCache.store(height: finalHeight, for: entry, width: width)
        return finalHeight
    }

    func listView(_ listView: ListViewKit.ListView, configureRowView rowView: ListViewKit.ListRowView, for item: ItemType, at index: Int) {
        guard let entry = item as? ChatEntry else {
            return
        }

        switch rowView {
        case let row as UserTextRowView:
            row.text = entry.text

        case let row as UserImagesRowView:
            row.images = entry.images

        case let row as MarkdownRowView:
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: theme)
            row.setMarkdown(package, renderToken: "\(entry.id)#\(entry.contentHash)")

        case let row as ThoughtRowView:
            let thoughtTheme = Self.makeThoughtMarkdownTheme(from: theme)
            let package = markdownCache.package(for: entry.id, content: entry.text, theme: thoughtTheme)
            row.configure(
                markdown: package,
                theme: thoughtTheme,
                renderToken: "\(entry.id)#\(entry.contentHash)",
                isExpanded: isThoughtExpanded(for: entry),
                isStreaming: entry.isStreaming,
                onToggle: { [weak self] in
                    self?.toggleThoughtExpansion(entryId: entry.id)
                }
            )

        case let row as ToolCallRowView:
            let payload = ToolCallRowView.Payload(entry: entry)
            row.configure(
                payload: payload,
                onACPPermission: { [weak self] requestId, optionId in
                    self?.actionHandlers.onACPPermissionResponse?(requestId, optionId)
                },
                onJSONRPCPermission: { [weak self] requestId, optionId in
                    self?.actionHandlers.onJSONRPCPermissionResponse?(requestId, optionId)
                },
                onApprove: { [weak self] requestId, acceptForSession in
                    self?.actionHandlers.onApproveRequest?(requestId, acceptForSession)
                },
                onDecline: { [weak self] requestId in
                    self?.actionHandlers.onDeclineRequest?(requestId)
                }
            )

        case let row as FileChangesRowView:
            row.configure(
                items: entry.fileChanges,
                onUndo: { [weak self] in
                    self?.actionHandlers.onUndoFileChanges?()
                },
                onReview: { [weak self] items in
                    self?.actionHandlers.onReviewFileChanges?(items)
                },
                onTurnDiff: actionHandlers.canTurnDiff?(entry.messageId) == true
                    ? { [weak self] in self?.actionHandlers.onTurnDiff?(entry.messageId) }
                    : nil
            )

        case let row as ForkMediaRowView:
            if let media = entry.media {
                row.configure(item: media, onPreviewHTML: actionHandlers.onPreviewHTML)
            }

        case let row as SystemRowView:
            row.text = entry.text

        case let row as StreamingIndicatorRowView:
            row.text = entry.text

        default:
            break
        }
    }
}
#elseif canImport(AppKit)
import AppKit
import MarkdownView
import ACP
import ACPClient

final class HighPerformanceChatListView: NSView {
    static let rowInsets = NSEdgeInsets(top: 0, left: 14, bottom: 12, right: 14)

    var actionHandlers: ChatEntryActionHandlers = .none
    var config: ChatRendererConfig = .default
    var onAtBottomChanged: ((Bool) -> Void)?

    private(set) var theme: MarkdownTheme = .default

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
    }

    func updateContentInsets(_ insets: NSEdgeInsets) {
        // No-op on macOS fallback renderer.
    }

    func render(
        messages: [ChatMessage],
        animated: Bool = true,
        scrollToBottomAnimated: Bool? = nil
    ) {
        onAtBottomChanged?(true)
    }

    func scrollToBottom(animated: Bool = true) {
        onAtBottomChanged?(true)
    }
}
#endif
