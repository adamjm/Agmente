import SwiftUI

/// Layout limits for reading content on wide screens (iPad, landscape). Phones are narrower than
/// `readableWidth`, so they see no change.
enum ForkLayout {
    /// Widest column for transcripts, composers and lists. About 75 characters of body text.
    static let readableWidth: CGFloat = 760
}

extension View {
    /// Centres the view in a column at most `ForkLayout.readableWidth` wide.
    func readableColumn() -> some View {
        frame(maxWidth: ForkLayout.readableWidth)
            .frame(maxWidth: .infinity)
    }
}
