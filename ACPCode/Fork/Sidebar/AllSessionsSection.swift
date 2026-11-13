import SwiftUI

// D-113: the drawer's all-sessions section. Rows from every connection, grouped by time, each with its agent badge
// and the connection's name. The row styling follows `SidebarSessionRow`. The caller decides what a tap does.

struct AllSessionsSection: View {
    let rows: [AllSessionRow]
    /// The id of the row for the session that is running now, if any. It is drawn highlighted.
    var activeRowId: String?
    let onOpen: (AllSessionRow) -> Void

    private var groups: [(group: SessionTimeGroup, rows: [AllSessionRow])] {
        var buckets: [SessionTimeGroup: [AllSessionRow]] = [:]
        for row in rows {
            buckets[SessionTimeGroup.group(for: row.date), default: []].append(row)
        }
        return SessionTimeGroup.displayOrder.compactMap { group in
            guard let rows = buckets[group] else { return nil }
            return (group, rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.group) { group, rows in
                SidebarSectionHeader(title: group.title)
                ForEach(rows) { row in
                    Button {
                        onOpen(row)
                    } label: {
                        AllSessionRowLabel(row: row, isActive: row.id == activeRowId)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
                }
            }
        }
        .accessibilityIdentifier("allSessionsSection")
    }
}

private struct AllSessionRowLabel: View {
    let row: AllSessionRow
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            AgentBadge(builder: row.builder, agentName: row.agentName, size: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    // The connection's colour, so the session can be matched to its connection (D-113).
                    Circle()
                        .fill(ServerColour.color(index: row.colourIndex))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(row.connectionName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            // Green while the session's connection is open, grey when it is not.
            Circle()
                .fill(row.isConnected ? ServerColour.connectedDot : ServerColour.offlineDot)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, SidebarStyle.rowHorizontalPadding)
        .padding(.vertical, SidebarStyle.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: SidebarStyle.rowCornerRadius, style: .continuous)
                    .fill(SidebarStyle.rowHighlight)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarPresentation.accessibilityLabel(
            title: row.title,
            status: isActive ? .running : .idle,
            unread: 0,
            extras: [row.connectionName, row.builder.displayName, row.isConnected ? "Connected" : "Not connected"]
        ))
    }
}
