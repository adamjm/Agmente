#if canImport(UIKit)
import UIKit

final class UserTextRowView: BaseRowView {
    var text: String = "" {
        didSet {
            label.text = text
            setNeedsLayout()
        }
    }

    private let bubble = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = ForkChatSurface.bubbleUIColor
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        rowContainer.addSubview(bubble)

        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .label
        bubble.addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = max(0, rowContainer.bounds.width - 50)
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - 20, height: .greatestFiniteMagnitude))
        let bubbleWidth = min(maxWidth, ceil(textSize.width) + 20)
        let bubbleHeight = ceil(textSize.height) + 14
        bubble.frame = CGRect(
            x: rowContainer.bounds.width - bubbleWidth,
            y: 0,
            width: bubbleWidth,
            height: bubbleHeight
        )
        label.frame = bubble.bounds.insetBy(dx: 10, dy: 7)
    }
}

final class UserImagesRowView: BaseRowView {
    var images: [ChatImageData] = [] {
        didSet {
            rebuildImageViews()
        }
    }

    private var imageViews: [UIImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x = rowContainer.bounds.width
        for imageView in imageViews.reversed() {
            x -= 80
            imageView.frame = CGRect(x: x, y: 0, width: 80, height: 80)
            x -= 6
        }
    }

    private func rebuildImageViews() {
        for view in imageViews {
            view.removeFromSuperview()
        }
        imageViews.removeAll(keepingCapacity: true)

        for image in images {
            let imageView = UIImageView(image: image.thumbnail)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.layer.cornerCurve = .continuous
            imageView.layer.borderWidth = 1
            imageView.layer.borderColor = UIColor.tintColor.withAlphaComponent(0.3).cgColor
            rowContainer.addSubview(imageView)
            imageViews.append(imageView)
        }

        setNeedsLayout()
    }
}
#endif
