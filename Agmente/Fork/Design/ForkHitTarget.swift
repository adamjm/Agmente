import SwiftUI

// Minimum 44 x 44 pt hit area (plan 4.1). The visual stays the same size: apply after the background.
struct ForkHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension View {
    func forkHitTarget() -> some View {
        modifier(ForkHitTarget())
    }
}
