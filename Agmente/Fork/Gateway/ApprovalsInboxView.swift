import SwiftUI
import ACPClient

/// A banner at the top of the gateway home: how many approvals wait, and a way into the inbox.
struct ApprovalsBanner: View {
    @ObservedObject var inbox: ApprovalsInboxModel
    let open: () -> Void

    var body: some View {
        if inbox.count > 0 {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text(inbox.count == 1 ? "1 approval waiting" : "\(inbox.count) approvals waiting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.orange.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("approvalsBanner")
            .accessibilityLabel(inbox.count == 1 ? "1 approval waiting" : "\(inbox.count) approvals waiting")
        }
    }
}

/// Every open approval of the gateway, with the options the agent offered. Nothing is chosen for the
/// person: each option is a button, and "Cancel request" tells the agent the request was cancelled.
struct ApprovalsInboxView: View {
    @ObservedObject var inbox: ApprovalsInboxModel
    /// For the project and session names on each card.
    let projects: [GatewayProject]
    let sessions: [GatewaySession]
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let notice = inbox.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("approvalsNotice")
                    }
                    if let message = inbox.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("approvalsError")
                    }
                    if inbox.approvals.isEmpty {
                        Text("No approvals waiting")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .accessibilityIdentifier("approvalsEmpty")
                    }
                    ForEach(inbox.approvals) { approval in
                        ApprovalCard(
                            approval: approval,
                            projectName: projects.first { $0.id == approval.projectId }?.name,
                            sessionTitle: sessions.first { $0.sessionId == approval.sessionId }?.title,
                            busy: inbox.answering.contains(approval.approvalId),
                            onAnswer: { option in Task { await inbox.answer(approval, option: option) } },
                            onCancel: { Task { await inbox.cancel(approval) } }
                        )
                    }
                }
                .padding(16)
            }
            .refreshable { await inbox.refresh() }
            .navigationTitle("Approvals")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .task { await inbox.refresh() }
        }
    }
}

private struct ApprovalCard: View {
    let approval: GatewayApproval
    let projectName: String?
    let sessionTitle: String?
    let busy: Bool
    let onAnswer: (GatewayApprovalOption) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: approval.kind == "execute" ? "terminal" : "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text(approval.title).font(.headline).lineLimit(2)
                Spacer()
                if let since = approval.sinceDate {
                    Text(since, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let detail = approval.detail {
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.12)))
                    .textSelection(.enabled)
            }
            Text([projectName, sessionTitle ?? "New Chat"].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 8) {
                ForEach(approval.options) { option in
                    Button { onAnswer(option) } label: {
                        Text(option.name).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(option.isAllow ? .green : .red)
                    .disabled(busy)
                    .accessibilityIdentifier("approvalOption.\(approval.approvalId).\(option.optionId)")
                }
            }
            Button("Cancel request", role: .cancel, action: onCancel)
                .font(.footnote)
                .disabled(busy)
                .accessibilityIdentifier("approvalCancel.\(approval.approvalId)")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        .opacity(busy ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.\(approval.approvalId)")
    }
}
