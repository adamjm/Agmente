import SwiftUI

// Presentation tokens and small views for the sessions sidebar (the home list). Presentation only: no
// protocol, storage or routing logic lives here. Surfaces use system colours so light, dark and Increase
// Contrast follow the OS. Sizes come from Dynamic Type styles.

enum SidebarStyle {
    /// Light grey fill behind the running row (the reference's selected-row highlight).
    static var rowHighlight: Color { Color(.systemGray5) }
    /// The dot for a running or unread session.
    static let activeDot = Color.blue
    static let rowIconWidth: CGFloat = 24
    static let rowCornerRadius: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 10
    /// Round controls (search, avatar) are this size, which is the iOS minimum touch target.
    static let circleControlSize: CGFloat = 44

    /// The dark capsule behind "New session" and "New project" (D-109 reuses it).
    static func pillTint(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.12, green: 0.13, blue: 0.18) : .black
    }
}

/// Scroll targets for the sidebar, so a row can be scrolled to by a project id.
enum SidebarScroll {
    static func project(_ projectId: String) -> String { "sidebar.project.\(projectId)" }
}

/// A small grey section label, in sentence case ("Recents", "Today"). Not all caps: the reference does not use them.
struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A primary row above the sessions: a leading icon, a label and an optional trailing count.
struct SidebarNavRow: View {
    let title: String
    let systemImage: String
    var count: Int?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: SidebarStyle.rowIconWidth)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
            .padding(.vertical, SidebarStyle.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
