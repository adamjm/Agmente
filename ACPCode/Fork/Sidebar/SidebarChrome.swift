import SwiftUI

/// The sidebar's header: the app title. Search is the system search bar below it, so there is one search control.
struct SidebarTitleBar: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
            .padding(.top, 4)
    }
}

/// The sidebar's bottom bar: a round avatar at the left, which opens Settings, and a dark capsule
/// "New session" button at the right. The capsule keeps the custom working directory menu it had.
struct SidebarBottomBar: View {
    /// Initials of the current server. Empty shows a generic person icon.
    let initials: String
    let isConnected: Bool
    let onSettings: () -> Void
    let onNewSession: () -> Void
    let onCustomDirectory: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var pillTint: Color {
        SidebarStyle.pillTint(for: colorScheme)
    }

    private var pillHeight: CGFloat {
#if os(macOS)
        36
#else
        50
#endif
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSettings) {
                ZStack {
                    Circle().fill(Color(.systemGray5))
                    if initials.isEmpty {
                        Image(systemName: "person.fill")
                            .font(.body.weight(.medium))
                    } else {
                        Text(initials)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: SidebarStyle.circleControlSize, height: SidebarStyle.circleControlSize)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebarAvatarButton")

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button(action: onNewSession) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                        Text("New session")
                            .font(.body.weight(.semibold))
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .frame(height: pillHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Session")
                .accessibilityIdentifier("newSessionButton")

                Menu {
                    Button(action: onCustomDirectory) {
                        Label("Custom Working Directory…", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 36, height: pillHeight)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("New session options")
                .accessibilityIdentifier("newSessionMenuButton")
            }
            .foregroundStyle(.white)
            .background(Capsule().fill(pillTint))
            .opacity(isConnected ? 1 : 0.6)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}
