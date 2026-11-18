import SwiftUI
import ACPClient
#if os(macOS)
import AppKit
#endif

/// The agent's plan as a collapsible checklist (FR-33). Shown only while the plan has entries.
///
/// The header is always visible. The entries sit in a scroll view capped at the smaller of 200 pt and a
/// quarter of the screen height, so a long plan cannot push the transcript and composer off a phone.
/// A plan with more than `collapsedByDefaultAbove` entries starts collapsed.
struct SessionPlanView: View {
    let entries: [ACPPlanEntry]
    @State private var isExpanded: Bool
    @State private var entriesHeight: CGFloat = 0

    private static let collapsedByDefaultAbove = 6

    init(entries: [ACPPlanEntry]) {
        self.entries = entries
        _isExpanded = State(initialValue: entries.count <= Self.collapsedByDefaultAbove)
    }

    private var completedCount: Int {
        entries.filter { ForkPlanRowState($0.status) == .completed }.count
    }

    private var maxEntriesHeight: CGFloat {
        #if os(iOS)
        let screenHeight = UIScreen.main.bounds.height
        #else
        let screenHeight = NSScreen.main?.frame.height ?? 800
        #endif
        return min(200, screenHeight * 0.25)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
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
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { entriesHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, newHeight in
                                entriesHeight = newHeight
                            }
                    }
                )
            }
            // Shrinks to the content up to the cap; before the first measurement it takes the natural size.
            .frame(height: entriesHeight > 0 ? min(entriesHeight, maxEntriesHeight) : nil)
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