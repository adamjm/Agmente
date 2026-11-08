import MarkdownView
import UIKit

/// The chat's markdown theme for code (design pass, 7.x). Code keeps the library's layout and
/// changes the type, the text colour and the surface, so code reads as code in light and dark.
/// The library draws a code block on `codeBackground` at its own alpha; inline code uses the same
/// colour's RGB at 5% opacity. The library fixes the block's corner radius (8 pt) and padding and
/// draws inline code as a text background, so a 12 pt radius or a rounded pill needs a library change.
enum ForkMarkdownTheme {
    /// Code runs at this share of the body size. The library's default is 0.85.
    static let codeSizeFactor: CGFloat = 0.9

    static func make() -> MarkdownTheme {
        var theme = MarkdownTheme.default
        let bodySize = UIFont.preferredFont(forTextStyle: .body).pointSize
        theme.fonts.code = UIFont.monospacedSystemFont(ofSize: ceil(bodySize * codeSizeFactor), weight: .regular)
        theme.fonts.codeInline = UIFont.monospacedSystemFont(ofSize: bodySize * codeSizeFactor, weight: .regular)
        // Blue code text, as in the reference. This also colours code-block text that is not syntax
        // highlighted, because the library uses `colors.code` for it.
        theme.colors.code = UIColor.systemBlue
        theme.colors.codeBackground = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.12)
                : UIColor(white: 0, alpha: 0.06)
        }
        return theme
    }
}
