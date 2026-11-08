import SwiftUI
import ACP

/// The "Running now" strip under the session transcript: the running tool calls and open approvals of the
/// current turn. It draws nothing when there is no running work. It never shows raw tool output.
///
/// An approval the agent is waiting on shows its options here, so the person can answer without scrolling
/// the transcript to find the card. A tap sends the same answer as the card (`onAnswer`); nothing is answered
/// without a tap (D-009).
struct RunningNowStrip: View {
    let messages: [ChatMessage]
    var onAnswer: (ACP.ID, String) -> Void = { _, _ in }

    var body: some View {
        let work = RunningWorkEvents.work(in: messages)
        let approvals = RunningWorkEvents.openApprovals(in: messages)
        if !work.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if work.runningToolCount > 0 {
                    Label("Running now: \(work.runningToolCount) \(work.runningToolCount == 1 ? "tool" : "tools")", systemImage: "gearshape.2")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .accessibilityIdentifier("runningNow.count")

                    ForEach(Array(work.listedTools.enumerated()), id: \.offset) { _, tool in
                        Text(tool.title)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if work.hiddenToolCount > 0 {
                        Text("and \(work.hiddenToolCount) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if work.openApprovals > 0 {
                    Label(
                        work.openApprovals == 1 ? "Awaiting approval" : "\(work.openApprovals) awaiting approval",
                        systemImage: "hand.raised"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("runningNow.approval")
                }

                ForEach(Array(approvals.enumerated()), id: \.offset) { _, approval in
                    approvalRow(approval)
                }

                Text("Subagent work is not shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("runningNow.strip")
        }
    }

    /// The tool's title and one button per option the agent offered for it.
    @ViewBuilder
    private func approvalRow(_ approval: OpenApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(approval.title)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                ForEach(approval.options, id: \.optionId) { option in
                    Button(option.name.truncatedLabel(maxChars: 24)) {
                        onAnswer(approval.requestId, option.optionId)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
                    .accessibilityIdentifier("runningNow.approve.\(option.optionId)")
                }
            }
        }
        .accessibilityIdentifier("runningNow.approvalRow")
    }
}
