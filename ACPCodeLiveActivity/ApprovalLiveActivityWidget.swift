import ACPCodeLiveApproval
import ActivityKit
import SwiftUI
import WidgetKit

/// The approval Live Activity: the Dynamic Island (compact, minimal, expanded) and the Lock Screen (la-decision).
/// It shows a count, the project and the state. It shows no tool title and no command.
struct ApprovalLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ApprovalActivityAttributes.self) { context in
            ApprovalLockScreenView(state: context.state)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Approval needed")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.pendingCount)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .accessibilityLabel(countLabel(context.state.pendingCount))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("Approval needed")
                            .font(.headline)
                        Text(context.state.projectName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ApprovalActionButtons(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Approval needed")
            } compactTrailing: {
                Text("\(context.state.pendingCount)")
                    .monospacedDigit()
                    .accessibilityLabel(countLabel(context.state.pendingCount))
            } minimal: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Approval needed")
            }
            .keylineTint(.orange)
        }
    }
}

/// The Lock Screen card: state, count, project, and the three actions.
struct ApprovalLockScreenView: View {
    let state: ApprovalActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Approval needed", systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text(state.projectName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(countLabel(state.pendingCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ApprovalActionButtons(state: state)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Once, Deny and Open. Each target is at least 44 pt high, and each has a VoiceOver label.
/// Once and Deny appear only when the agent offered that kind of option (by kind, never by label).
struct ApprovalActionButtons: View {
    let state: ApprovalActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if let optionId = state.allowOnceOptionId {
                Button(intent: ApproveOnceIntent(approvalId: state.approvalId, optionId: optionId)) {
                    ApprovalActionLabel(title: "Once", systemImage: "checkmark.circle.fill", tint: .green)
                }
                .accessibilityLabel("Allow once")
            }
            if let optionId = state.denyOptionId {
                Button(intent: DenyApprovalIntent(approvalId: state.approvalId, optionId: optionId)) {
                    ApprovalActionLabel(title: "Deny", systemImage: "xmark.circle.fill", tint: .red)
                }
                .accessibilityLabel("Deny")
            }
            if let link = state.openLink, let url = URL(string: link) {
                Link(destination: url) {
                    ApprovalActionLabel(title: "Open", systemImage: "arrow.up.forward.app", tint: .secondary)
                }
                .accessibilityLabel("Open session in ACP Code")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// An icon with a one-word caption, in a target of at least 44 pt.
struct ApprovalActionLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(minWidth: 56, minHeight: 44)
        .contentShape(Rectangle())
    }
}

private func countLabel(_ count: Int) -> String {
    count == 1 ? "1 approval waiting" : "\(count) approvals waiting"
}
