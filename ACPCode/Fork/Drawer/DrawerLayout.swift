import CoreGraphics

// Pure rules for the slide-over session drawer (D-109). No SwiftUI state, so they are tested directly
// (ACPCodeTests/DrawerLayoutTests.swift). Velocity is the predicted extra travel of the drag, in points,
// because a DragGesture value carries no velocity of its own.

enum DrawerLayout {
    static let widthFraction: CGFloat = 0.86
    static let maxWidth: CGFloat = 380
    /// A drag must start this close to the left edge to open the drawer.
    static let edgeZone: CGFloat = 24
    /// Share of the drawer width a drag must cover to settle open or closed.
    static let settleFraction: CGFloat = 0.35
    /// Predicted extra travel, in points, that counts as a flick.
    static let flickDistance: CGFloat = 120

    /// `min(screenWidth * 0.86, 380)`, or zero for a screen that has no usable width.
    static func drawerWidth(screenWidth: CGFloat) -> CGFloat {
        guard screenWidth.isFinite, screenWidth > 0 else { return 0 }
        return min(screenWidth * widthFraction, maxWidth)
    }

    static func isInOpenZone(startX: CGFloat) -> Bool {
        startX >= 0 && startX <= edgeZone
    }

    /// A closed drawer opens for a rightward drag that covers enough distance, or a rightward flick.
    static func shouldOpen(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, translation > 0 else { return false }
        return translation >= width * settleFraction || velocity >= flickDistance
    }

    /// An open drawer closes for a leftward drag that covers enough distance, or a leftward flick.
    static func shouldClose(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, translation < 0 else { return false }
        return -translation >= width * settleFraction || velocity <= -flickDistance
    }

    /// The drawer's x offset: 0 when open, `-width` when closed, moved by the finger and kept in range.
    static func offset(isOpen: Bool, drag: CGFloat, width: CGFloat) -> CGFloat {
        let resting: CGFloat = isOpen ? 0 : -width
        return min(0, max(-width, resting + drag))
    }

    /// 0 when the drawer is off screen, 1 when it is fully open.
    static func openness(offset: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(1, max(0, (offset + width) / width))
    }
}
