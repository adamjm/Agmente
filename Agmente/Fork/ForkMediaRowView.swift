#if canImport(UIKit)
import UIKit

/// Chat row for an agent image, a refused image placeholder, or a non-loading resource link row.
final class ForkMediaRowView: BaseRowView {
    static let maxImageHeight: CGFloat = 260
    static let placeholderHeight: CGFloat = 44

    static func height(for item: ForkMediaItem, width: CGFloat) -> CGFloat {
        switch item.content {
        case .image:
            let size = item.fittedSize(maxWidth: width, maxHeight: maxImageHeight)
            return max(size.height, 1)
        case .placeholder, .link:
            return placeholderHeight
        }
    }

    private let imageView = UIImageView()
    private let card = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var item: ForkMediaItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image from agent"

        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.backgroundColor = .systemGray6
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        titleLabel.font = .preferredFont(forTextStyle: .footnote)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = .secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingMiddle

        rowContainer.addSubview(imageView)
        rowContainer.addSubview(card)
        card.addSubview(iconView)
        card.addSubview(titleLabel)
        card.addSubview(detailLabel)
    }

    func configure(item: ForkMediaItem) {
        self.item = item
        switch item.content {
        case .image(let image):
            imageView.image = UIImage(cgImage: image)
            imageView.isHidden = false
            card.isHidden = true
        case .placeholder(let title, let detail):
            show(icon: "photo.badge.exclamationmark", title: title, detail: detail)
        case .link(let title, let uri, let detail):
            // A plain label, not a tappable link and never loaded (PLAN 5.1).
            show(icon: "link", title: title, detail: detail.isEmpty ? uri : "\(uri) · \(detail)")
        }
        setNeedsLayout()
    }

    private func show(icon: String, title: String, detail: String) {
        imageView.image = nil
        imageView.isHidden = true
        card.isHidden = false
        iconView.image = UIImage(systemName: icon)
        titleLabel.text = title
        detailLabel.text = detail
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = rowContainer.bounds
        guard let item else { return }
        switch item.content {
        case .image:
            let size = item.fittedSize(maxWidth: bounds.width, maxHeight: Self.maxImageHeight)
            imageView.frame = CGRect(origin: .zero, size: size)
        case .placeholder, .link:
            card.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.placeholderHeight)
            iconView.frame = CGRect(x: 12, y: (Self.placeholderHeight - 18) / 2, width: 18, height: 18)
            let x: CGFloat = 38
            let w = max(0, bounds.width - x - 12)
            titleLabel.frame = CGRect(x: x, y: 5, width: w, height: 18)
            detailLabel.frame = CGRect(x: x, y: 23, width: w, height: 16)
        }
    }
}
#endif
