#if canImport(UIKit)
import UIKit
import ListViewKit

class BaseRowView: ListRowView {
    let rowContainer = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(rowContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowContainer.frame = CGRect(
            x: HighPerformanceChatListView.rowInsets.left,
            y: 0,
            width: bounds.width - HighPerformanceChatListView.rowInsets.left - HighPerformanceChatListView.rowInsets.right,
            height: bounds.height - HighPerformanceChatListView.rowInsets.bottom
        )
    }
}

final class ActionButton: UIButton {
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        action?()
    }
}

extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
