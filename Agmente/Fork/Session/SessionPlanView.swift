import SwiftUI
import ACPClient

/// The agent's plan as a collapsible checklist (FR-33). Shown only while the plan has entries.
struct SessionPlanView: View {
    let entries: [ACPPlanEntry]
    @State private var isExpanded = true

    private var completedCount: Int {
        entries.filter { ForkPlanRowState($0.status) == .completed }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(for: ForkPlanRowState(entry.status)))
                            .foregroundStyle(color(for: ForkPlanRowState(entry.status)))
                            .accessibilityHidden(true)
                        Text(entry.content)
                            .font(.callout)
                            .strikethrough(ForkPlanRowState(entry.status) == .completed)
                            .foregroundStyle(ForkPlanRowState(entry.status) == .completed ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(label(for: ForkPlanRowState(entry.status))): \(entry.content)")
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Plan \(completedCount) of \(entries.count) done", systemImage: "checklist")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .accessibilityIdentifier("sessionPlan")
    }

    private func symbol(for state: ForkPlanRowState) -> String {
        switch state {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func color(for state: ForkPlanRowState) -> Color {
        switch state {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        }
    }

    private func label(for state: ForkPlanRowState) -> String {
        switch state {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        }
    }
}

/// Token and cost figures under the composer (FR-33).
struct SessionUsageFooter: View {
    let usage: ACPSessionUsage?

    var body: some View {
        if let line = ForkUsageFormat.line(usage) {
            Text(line)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("sessionUsage")
        }
    }
}
