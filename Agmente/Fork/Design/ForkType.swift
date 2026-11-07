import SwiftUI

// Type and spacing tokens (plan 4.1). Dynamic Type styles only.
enum ForkType {
    static let rowTitle: Font = .body.weight(.semibold)
    /// Row metadata (cwd, times). Replaces caption2, which fails contrast and is too small.
    static let rowMeta: Font = .subheadline
    static let pill: Font = .caption.weight(.bold)
    static let sectionHeader: Font = .footnote.weight(.semibold)
}

enum ForkSpacing {
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let rowHorizontal: CGFloat = s16
    static let rowVertical: CGFloat = s12
}
