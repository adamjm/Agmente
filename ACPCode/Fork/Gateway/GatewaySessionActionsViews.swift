import SwiftUI
import ACPClient

/// The alert, the agent-stop confirmation and the removal confirmation of the gateway session actions (D-106).
/// Attached once, at the root of the main view, so each prompt is shown once.
struct GatewaySessionDialogs: ViewModifier {
    @ObservedObject var actions: GatewaySessionActions

    func body(content: Content) -> some View {
        content
            .alert(
                actions.notice?.title ?? "",
                isPresented: Binding(get: { actions.notice != nil }, set: { if !$0 { actions.notice = nil } }),
                presenting: actions.notice
            ) { _ in
                Button("OK", role: .cancel) {}
                    .accessibilityIdentifier("gatewayNoticeOK")
            } message: { notice in
                Text(notice.message)
            }
            .confirmationDialog(
                GatewayStopCopy.stopAgentQuestion,
                isPresented: Binding(get: { actions.agentStop != nil }, set: { if !$0 { actions.agentStop = nil } }),
                titleVisibility: .visible,
                presenting: actions.agentStop
            ) { _ in
                Button(GatewayStopCopy.stopAgentButton, role: .destructive) {
                    Task { await actions.confirmAgentStop() }
                }
                .accessibilityIdentifier("gatewayAgentStopConfirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("gatewayAgentStopCancel")
            } message: { prompt in
                Text(GatewayStopCopy.agentStopMessage(prompt.candidates))
            }
            .confirmationDialog(
                GatewayRemovalCopy.title,
                isPresented: Binding(get: { actions.removal != nil }, set: { if !$0 { actions.removal = nil } }),
                titleVisibility: .visible,
                presenting: actions.removal
            ) { _ in
                Button(GatewayRemovalCopy.button, role: .destructive) { actions.confirmRemoval() }
                    .accessibilityIdentifier("gatewayRemovalConfirm")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("gatewayRemovalCancel")
            } message: { _ in
                Text(GatewayRemovalCopy.message)
            }
    }
}

extension View {
    /// Shows the gateway session actions' alert and confirmations for `actions`.
    func gatewaySessionDialogs(_ actions: GatewaySessionActions) -> some View {
        modifier(GatewaySessionDialogs(actions: actions))
    }
}
