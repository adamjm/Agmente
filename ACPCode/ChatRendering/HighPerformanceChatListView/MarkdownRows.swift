#if canImport(UIKit)
import UIKit
import ListViewKit
import MarkdownView

final class MarkdownRowView: BaseRowView {
    private let style: MarkdownStyle
    private weak var boundScrollView: UIScrollView?
    private var renderedToken: String?

    private let backgroundCard = UIView()
    private let markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()

    init(style: MarkdownStyle) {
        self.style = style
        super.init(frame: .zero)

        backgroundCard.layer.cornerRadius = 12
        backgroundCard.layer.cornerCurve = .continuous
        backgroundCard.backgroundColor = style.backgroundColor
        rowContainer.addSubview(backgroundCard)
        backgroundCard.addSubview(markdownView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMarkdown(_ content: MarkdownTextView.PreprocessedContent, theme: MarkdownTheme, renderToken: String) {
        guard renderedToken != renderToken else { return }
        renderedToken = renderToken
        // The view must carry the same theme as the content, or it draws with the library default.
        if markdownView.theme != theme {
            markdownView.theme = theme
        }
        markdownView.setMarkdown(content)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundCard.frame = rowContainer.bounds
        markdownView.frame = backgroundCard.bounds.insetBy(dx: style.horizontalPadding, dy: style.verticalPadding)
        let scrollView = superListView
        if boundScrollView !== scrollView {
            boundScrollView = scrollView
            markdownView.bindContentOffset(from: scrollView)
        }
    }
}

final class ThoughtRowView: BaseRowView {
    static let collapsedHeight: CGFloat = 34
    static let contentSpacing: CGFloat = 3
    static let bottomPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 14

    private let chip = UIView()
    private let contentContainer = UIView()
    private let markdownView: MarkdownTextView = {
        let view = MarkdownTextView()
        view.throttleInterval = 1 / 60
        return view
    }()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let headerButton = UIButton(type: .custom)

    private weak var boundScrollView: UIScrollView?
    private var renderedToken: String?
    private var isExpanded: Bool = false
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        chip.layer.cornerRadius = 16
        chip.layer.cornerCurve = .continuous
        chip.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.08)

        iconView.image = UIImage(systemName: "brain")
        iconView.tintColor = .systemPurple
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.medium)
        titleLabel.textColor = .systemPurple
        titleLabel.text = "Thinking"

        chevronView.image = UIImage(systemName: "chevron.down")
        chevronView.tintColor = .systemPurple
        chevronView.contentMode = .scaleAspectFit

        headerButton.backgroundColor = .clear
        headerButton.addTarget(self, action: #selector(handleHeaderTap), for: .touchUpInside)
        headerButton.accessibilityLabel = "Thinking"
        headerButton.accessibilityHint = "Expand or collapse details"

        contentContainer.clipsToBounds = true
        contentContainer.addSubview(markdownView)

        rowContainer.addSubview(chip)
        chip.addSubview(iconView)
        chip.addSubview(titleLabel)
        chip.addSubview(chevronView)
        chip.addSubview(headerButton)
        chip.addSubview(contentContainer)
    }

    func configure(
        markdown: MarkdownTextView.PreprocessedContent,
        theme: MarkdownTheme,
        renderToken: String,
        isExpanded: Bool,
        isStreaming _: Bool,
        onToggle: @escaping () -> Void
    ) {
        if markdownView.theme != theme {
            markdownView.theme = theme
        }
        let wasExpanded = self.isExpanded
        self.onToggle = onToggle
        self.isExpanded = isExpanded
        if renderedToken != renderToken {
            renderedToken = renderToken
            markdownView.setMarkdown(markdown)
        }
        let targetTransform = isExpanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        if wasExpanded != isExpanded, superview != nil {
            // Animate chevron + chip width together when toggling.
            layoutIfNeeded()
            if isExpanded {
                contentContainer.isHidden = false
                contentContainer.alpha = 0
            }
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState]
            ) {
                self.chevronView.transform = targetTransform
                self.setNeedsLayout()
                self.layoutIfNeeded()
            } completion: { _ in
                if isExpanded {
                    self.contentContainer.isHidden = false
                    UIView.animate(
                        withDuration: 0.12,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        self.contentContainer.alpha = 1
                    }
                } else {
                    self.contentContainer.alpha = 1
                    self.contentContainer.isHidden = true
                }
            }
        } else {
            contentContainer.isHidden = !isExpanded
            contentContainer.alpha = 1
            chevronView.transform = targetTransform
            setNeedsLayout()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let iconSize: CGFloat = 14
        let chevronSize: CGFloat = 10
        let leadingPadding: CGFloat = 14
        let headerHeight = Self.collapsedHeight
        let collapsedChipWidth = Self.collapsedWidth(
            titleText: titleLabel.text ?? "",
            titleFont: titleLabel.font,
            iconSize: iconSize,
            chevronSize: chevronSize,
            leadingPadding: leadingPadding
        )
        let chipWidth = isExpanded
            ? rowContainer.bounds.width
            : min(rowContainer.bounds.width, collapsedChipWidth)
        chip.frame = CGRect(x: 0, y: 0, width: chipWidth, height: rowContainer.bounds.height)

        iconView.frame = CGRect(x: leadingPadding, y: (headerHeight - iconSize) / 2, width: iconSize, height: iconSize)
        let titleX = iconView.frame.maxX + 6
        let titleHeight = ceil(titleLabel.font.lineHeight)
        let maxTitleWidth = max(0, chip.bounds.width - titleX - leadingPadding - chevronSize - 4)
        let measuredTitleWidth = ceil(titleLabel.sizeThatFits(CGSize(width: maxTitleWidth, height: headerHeight)).width)
        let titleWidth = min(maxTitleWidth, measuredTitleWidth)
        titleLabel.frame = CGRect(
            x: titleX,
            y: (headerHeight - titleHeight) / 2,
            width: titleWidth,
            height: titleHeight
        )
        let chevronX = min(chip.bounds.width - leadingPadding - chevronSize, titleLabel.frame.maxX + 4)
        chevronView.frame = CGRect(
            x: chevronX,
            y: (headerHeight - chevronSize) / 2,
            width: chevronSize,
            height: chevronSize
        )
        headerButton.frame = CGRect(x: 0, y: 0, width: chip.bounds.width, height: headerHeight)

        if isExpanded {
            contentContainer.isHidden = false
            contentContainer.frame = CGRect(
                x: Self.horizontalPadding,
                y: headerHeight + Self.contentSpacing,
                width: max(0, chip.bounds.width - (Self.horizontalPadding * 2)),
                height: max(0, chip.bounds.height - headerHeight - Self.contentSpacing - Self.bottomPadding)
            )
            markdownView.frame = contentContainer.bounds
            let scrollView = superListView
            if boundScrollView !== scrollView {
                boundScrollView = scrollView
                markdownView.bindContentOffset(from: scrollView)
            }
        } else {
            contentContainer.isHidden = true
            contentContainer.frame = .zero
            markdownView.frame = .zero
        }
    }

    private static func collapsedWidth(
        titleText: String,
        titleFont: UIFont,
        iconSize: CGFloat,
        chevronSize: CGFloat,
        leadingPadding: CGFloat
    ) -> CGFloat {
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: titleFont]).width)
        return ceil(leadingPadding + iconSize + 6 + titleWidth + 4 + chevronSize + leadingPadding)
    }

    @objc private func handleHeaderTap() {
        onToggle?()
    }
}
#endif
