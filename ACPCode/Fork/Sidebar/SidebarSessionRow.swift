import SwiftUI

/// One session in the sidebar: a chat icon, the title on one line, and a trailing indicator. A running
/// row gets a light grey rounded highlight. The row is one accessibility element whose label carries
/// the status words, so the dot does not need to be seen to know the state.
struct SidebarSessionRow: View {
    let title: String
    let status: ForkStatusKind
    var unread: Int = 0
    var isHighlighted: Bool = false
    /// Extra text for VoiceOver only (a last message, a folder). It is not drawn.
    var accessibilityExtras: [String] = []
    /// The session's connection colour (D-113). Nil draws the plain icon.
    var serverColour: Color?
    /// Whether the session's connection is open. Nil draws no connection dot.
    var isConnected: Bool?

    private var indicator: SidebarRowIndicator {
        SidebarPresentation.indicator(status: status, unread: unread)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.body)
                .foregroundStyle(serverColour ?? .secondary)
                .frame(width: SidebarStyle.rowIconWidth)
                .accessibilityHidden(true)

            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            indicatorView

            if let isConnected {
                Circle()
                    .fill(isConnected ? ServerColour.connectedDot : ServerColour.offlineDot)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
        .padding(.vertical, SidebarStyle.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous)
                    .fill(SidebarStyle.rowHighlight)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel(
            title: title,
            status: status,
            unread: unread,
            extras: accessibilityExtras
        ))
    }

    @ViewBuilder
    private var indicatorView: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(SidebarStyle.activeDot)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        case .approval:
            Image(systemName: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }
}
