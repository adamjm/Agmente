import SwiftUI

// A drawer that slides in from the left over the main content (D-109, iOS). The main content stays mounted
// behind a dimming scrim, and so does the drawer, so its scroll position and search survive a close. Open
// and close rules are in `DrawerLayout`. With Reduce Motion the drawer does not slide: it fades in place.

struct SlideOverDrawer<Main: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder let main: () -> Main
    @ViewBuilder let drawer: () -> Drawer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The finger's offset while a drag is in progress. Zero at rest.
    @State private var drag: CGFloat = 0

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.86)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = DrawerLayout.drawerWidth(screenWidth: proxy.size.width)
            let x = reduceMotion ? 0 : DrawerLayout.offset(isOpen: isOpen, drag: drag, width: width)
            let openness = reduceMotion
                ? (isOpen ? CGFloat(1) : CGFloat(0))
                : DrawerLayout.openness(offset: x, width: width)

            ZStack(alignment: .leading) {
                main()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(isOpen)

                Color.black
                    .opacity(0.35 * openness)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { setOpen(false) }
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(true)

                drawer()
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
                    .shadow(color: .black.opacity(0.18 * openness), radius: 12, x: 4, y: 0)
                    .offset(x: x)
                    .opacity(reduceMotion ? openness : 1)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
                    .accessibilityAction(.escape) { setOpen(false) }
                    .simultaneousGesture(closeDrag(width: width), including: isOpen && !reduceMotion ? .all : .subviews)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .simultaneousGesture(openDrag(width: width), including: !isOpen && !reduceMotion ? .all : .subviews)
            .animation(animation, value: isOpen)
        }
    }

    private func setOpen(_ open: Bool) {
        withAnimation(animation) { isOpen = open }
    }

    /// A rightward drag that starts at the left edge follows the finger, then settles open or closed.
    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard DrawerLayout.isInOpenZone(startX: value.startLocation.x), isHorizontal(value) else { return }
                drag = max(0, value.translation.width)
            }
            .onEnded { value in
                guard DrawerLayout.isInOpenZone(startX: value.startLocation.x) else { return }
                let opens = DrawerLayout.shouldOpen(
                    translation: value.translation.width,
                    velocity: predictedExtra(value),
                    width: width
                )
                settle(open: opens ? true : isOpen)
            }
    }

    /// A leftward drag on the open drawer follows the finger, then settles open or closed.
    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard isHorizontal(value) else { return }
                drag = min(0, value.translation.width)
            }
            .onEnded { value in
                let closes = DrawerLayout.shouldClose(
                    translation: value.translation.width,
                    velocity: predictedExtra(value),
                    width: width
                )
                settle(open: closes ? false : isOpen)
            }
    }

    private func settle(open: Bool) {
        withAnimation(animation) {
            drag = 0
            isOpen = open
        }
    }

    /// A drag counts only when it goes mostly sideways, so a vertical scroll never moves the drawer.
    private func isHorizontal(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) > abs(value.translation.height)
    }

    private func predictedExtra(_ value: DragGesture.Value) -> CGFloat {
        value.predictedEndTranslation.width - value.translation.width
    }
}
