#if canImport(UIKit)
import UIKit
import ACPClient

final class FileChangesRowView: BaseRowView {
    private var onUndo: (() -> Void)?
    private var onReview: (([FileChangeSummaryItem]) -> Void)?
    private var onTurnDiff: (() -> Void)?
    private var items: [FileChangeSummaryItem] = []
    private var itemRows: [FileChangePreviewRowView] = []

    private let card = UIView()
    private let summaryLabel = UILabel()
    private let turnDiffButton = ActionButton(type: .system)
    private let undoButton = ActionButton(type: .system)
    private let reviewButton = ActionButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.backgroundColor = UIColor.systemGray5

        summaryLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        summaryLabel.textColor = .label
        summaryLabel.numberOfLines = 1

        var undoConfig = UIButton.Configuration.bordered()
        undoConfig.title = "Undo"
        undoConfig.baseForegroundColor = .systemBlue
        undoConfig.cornerStyle = .capsule
        undoConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        undoConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        undoButton.configuration = undoConfig

        var turnDiffConfig = UIButton.Configuration.bordered()
        turnDiffConfig.title = "Turn diff"
        turnDiffConfig.baseForegroundColor = .systemBlue
        turnDiffConfig.cornerStyle = .capsule
        turnDiffConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        turnDiffConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        turnDiffButton.configuration = turnDiffConfig
        turnDiffButton.accessibilityIdentifier = "turnDiffButton"
        turnDiffButton.isHidden = true

        var reviewConfig = UIButton.Configuration.borderedProminent()
        reviewConfig.title = "Review"
        reviewConfig.baseForegroundColor = .white
        reviewConfig.baseBackgroundColor = .systemBlue
        reviewConfig.cornerStyle = .capsule
        reviewConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        reviewConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        reviewButton.configuration = reviewConfig

        rowContainer.addSubview(card)
        card.addSubview(summaryLabel)
        card.addSubview(turnDiffButton)
        card.addSubview(undoButton)
        card.addSubview(reviewButton)

        undoButton.action = { [weak self] in
            self?.onUndo?()
        }
        turnDiffButton.action = { [weak self] in
            self?.onTurnDiff?()
        }
        reviewButton.action = { [weak self] in
            guard let self else { return }
            self.onReview?(self.items)
        }
    }

    func configure(items: [FileChangeSummaryItem], onUndo: @escaping () -> Void, onReview: @escaping ([FileChangeSummaryItem]) -> Void, onTurnDiff: (() -> Void)? = nil) {
        self.items = deduplicate(items)
        self.onUndo = onUndo
        self.onReview = onReview
        self.onTurnDiff = onTurnDiff
        turnDiffButton.isHidden = onTurnDiff == nil

        let count = self.items.count
        summaryLabel.text = count == 1 ? "1 file changed" : "\(count) files changed"
        rebuildItemRows()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = rowContainer.bounds

        let horizontalPadding: CGFloat = 12
        let topPadding: CGFloat = 12
        let buttonHeight: CGFloat = 32
        let width = card.bounds.width

        let reviewSize = reviewButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: buttonHeight))
        let reviewWidth = max(84, ceil(reviewSize.width))
        reviewButton.frame = CGRect(
            x: width - horizontalPadding - reviewWidth,
            y: topPadding,
            width: reviewWidth,
            height: buttonHeight
        )

        let undoSize = undoButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: buttonHeight))
        let undoWidth = max(72, ceil(undoSize.width))
        undoButton.frame = CGRect(
            x: reviewButton.frame.minX - 10 - undoWidth,
            y: topPadding,
            width: undoWidth,
            height: buttonHeight
        )

        var leftmost = undoButton.frame.minX
        if !turnDiffButton.isHidden {
            let turnSize = turnDiffButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: buttonHeight))
            let turnWidth = ceil(turnSize.width)
            turnDiffButton.frame = CGRect(x: leftmost - 10 - turnWidth, y: topPadding, width: turnWidth, height: buttonHeight)
            leftmost = turnDiffButton.frame.minX
        }

        let summaryAvailableWidth = max(0, leftmost - horizontalPadding - 10)
        let summarySize = summaryLabel.sizeThatFits(CGSize(width: summaryAvailableWidth, height: buttonHeight))
        summaryLabel.frame = CGRect(
            x: horizontalPadding,
            y: topPadding + floor((buttonHeight - ceil(summarySize.height)) / 2),
            width: summaryAvailableWidth,
            height: ceil(summarySize.height)
        )

        var currentY = max(summaryLabel.frame.maxY, reviewButton.frame.maxY) + 10
        let rowWidth = max(0, width - (horizontalPadding * 2))
        for (index, row) in itemRows.enumerated() {
            let rowHeight = ceil(row.sizeThatFits(CGSize(width: rowWidth, height: .greatestFiniteMagnitude)).height)
            row.frame = CGRect(x: horizontalPadding, y: currentY, width: rowWidth, height: rowHeight)
            currentY += rowHeight
            if index < itemRows.count - 1 {
                currentY += 8
            }
        }
    }

    static func estimatedHeight(for items: [FileChangeSummaryItem], width: CGFloat) -> CGFloat {
        let deduped = deduplicate(items)
        let horizontalPadding: CGFloat = 12
        let iconSize = ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight)
        let textLeadingSpacing: CGFloat = 8
        let textWidth = max(0, width - (horizontalPadding * 2) - iconSize - textLeadingSpacing)
        let pathFont = UIFont.preferredFont(forTextStyle: .footnote)
        let statusFont = UIFont.preferredFont(forTextStyle: .caption2)

        var rowsHeight: CGFloat = 0
        for item in deduped {
            let pathHeight = (item.path as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: pathFont],
                context: nil
            ).height
            var textBlockHeight = ceil(pathHeight)
            if let statusText = statusText(for: item), !statusText.isEmpty {
                let statusHeight = (statusText as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: statusFont],
                    context: nil
                ).height
                textBlockHeight += 2 + ceil(statusHeight)
            }
            let rowHeight = max(iconSize, textBlockHeight)
            rowsHeight += rowHeight
        }

        if deduped.count > 1 {
            rowsHeight += CGFloat(deduped.count - 1) * 8
        }

        let headerHeight: CGFloat = 12 + 32
        let contentSpacing: CGFloat = deduped.isEmpty ? 0 : 10
        let bottomPadding: CGFloat = 12
        return max(headerHeight + contentSpacing + rowsHeight + bottomPadding, 68)
    }

    private static func deduplicate(_ items: [FileChangeSummaryItem]) -> [FileChangeSummaryItem] {
        var chosen: [String: FileChangeSummaryItem] = [:]
        var order: [String] = []

        for item in items {
            let key = normalizedPathKey(item.path)
            if let existing = chosen[key] {
                chosen[key] = preferredItem(existing, item)
            } else {
                order.append(key)
                chosen[key] = item
            }
        }

        return order.compactMap { chosen[$0] }
    }

    private func deduplicate(_ items: [FileChangeSummaryItem]) -> [FileChangeSummaryItem] {
        Self.deduplicate(items)
    }

    private static func normalizedPathKey(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let separators = CharacterSet(charactersIn: "/\\")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        return (parts.last ?? trimmed).lowercased()
    }

    private static func preferredItem(_ existing: FileChangeSummaryItem, _ candidate: FileChangeSummaryItem) -> FileChangeSummaryItem {
        let existingPath = existing.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePath = candidate.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingHasSeparator = existingPath.contains("/") || existingPath.contains("\\")
        let candidateHasSeparator = candidatePath.contains("/") || candidatePath.contains("\\")

        if existingHasSeparator != candidateHasSeparator {
            return existingHasSeparator ? existing : candidate
        }

        let existingVerb = existing.verb?.lowercased() ?? ""
        let candidateVerb = candidate.verb?.lowercased() ?? ""
        let existingStatus = existing.status?.lowercased() ?? ""
        let candidateStatus = candidate.status?.lowercased() ?? ""
        let existingIsDiff = existingVerb == "diff" || existingStatus == "diff"
        let candidateIsDiff = candidateVerb == "diff" || candidateStatus == "diff"

        if existingIsDiff != candidateIsDiff {
            return existingIsDiff ? candidate : existing
        }

        if existingPath.count != candidatePath.count {
            return existingPath.count >= candidatePath.count ? existing : candidate
        }

        return existing
    }

    private static func statusText(for item: FileChangeSummaryItem) -> String? {
        if let verb = item.verb?.trimmingCharacters(in: .whitespacesAndNewlines), !verb.isEmpty {
            return verb.capitalized
        }
        if let status = item.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return nil
    }

    private func rebuildItemRows() {
        if itemRows.count < items.count {
            for _ in itemRows.count..<items.count {
                let row = FileChangePreviewRowView()
                card.addSubview(row)
                itemRows.append(row)
            }
        }
        if itemRows.count > items.count {
            for row in itemRows[items.count...] {
                row.removeFromSuperview()
            }
            itemRows.removeSubrange(items.count...)
        }
        for (index, item) in items.enumerated() {
            itemRows[index].configure(path: item.path, status: Self.statusText(for: item))
        }
    }
}

final class FileChangePreviewRowView: UIView {
    private let iconView = UIImageView()
    private let pathLabel = UILabel()
    private let statusLabel = UILabel()

    private var pathText: String = ""
    private var statusText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "doc.text",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote)
        )
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        pathLabel.font = .preferredFont(forTextStyle: .footnote)
        pathLabel.textColor = .label
        pathLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        addSubview(iconView)
        addSubview(pathLabel)
        addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(path: String, status: String?) {
        pathText = path
        statusText = status
        pathLabel.text = path
        statusLabel.text = status
        statusLabel.isHidden = status == nil || status?.isEmpty == true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSize = max(1, ceil(iconView.sizeThatFits(.zero).width))
        let textX = iconSize + 8
        let textWidth = max(0, bounds.width - textX)
        let pathSize = pathLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        let pathHeight = ceil(pathSize.height)
        var textBlockHeight = pathHeight
        var statusHeight: CGFloat = 0

        if !statusLabel.isHidden {
            let statusSize = statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            statusHeight = ceil(statusSize.height)
            textBlockHeight += 2 + statusHeight
        }

        let rowHeight = max(bounds.height, max(iconSize, textBlockHeight))
        let textBlockY = floor((rowHeight - textBlockHeight) / 2)
        let iconY = floor((rowHeight - iconSize) / 2)

        iconView.frame = CGRect(
            x: 0,
            y: max(0, iconY),
            width: iconSize,
            height: iconSize
        )
        pathLabel.frame = CGRect(
            x: textX,
            y: max(0, textBlockY),
            width: textWidth,
            height: pathHeight
        )

        if statusLabel.isHidden {
            statusLabel.frame = .zero
        } else {
            statusLabel.frame = CGRect(
                x: textX,
                y: pathLabel.frame.maxY + 2,
                width: textWidth,
                height: statusHeight
            )
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let iconSize = max(1, ceil(iconView.sizeThatFits(.zero).width))
        let textWidth = max(0, size.width - iconSize - 8)
        let pathHeight = ceil(pathLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        var textBlockHeight = pathHeight
        if let statusText, !statusText.isEmpty {
            let statusHeight = ceil((statusText as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: statusLabel.font as Any],
                context: nil
            ).height)
            textBlockHeight = pathHeight + 2 + statusHeight
        }
        return CGSize(width: size.width, height: max(textBlockHeight, iconSize))
    }
}
#endif
