#if os(iOS)
import SwiftUI

/// Settings row for notifications (PLAN 3.20). It asks for permission only when tapped, and it shows what
/// is true: the device token stays on this device, because the gateway has no method to take it yet and
/// the app has no push entitlement (BLOCKED in RESULTS, D-041).
struct PushSettingsRow: View {
    @ObservedObject private var push = PushRegistration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notifications")
                Spacer()
                Text(statusText).foregroundStyle(.secondary)
            }
            if push.authorization == .notDetermined {
                Button("Allow notifications") { Task { await push.enable() } }
                    .accessibilityIdentifier("allowNotificationsButton")
            }
            if let failure = push.failure {
                Text(failure).font(.footnote).foregroundStyle(.red)
            } else if push.notAvailableInBuild {
                Text("Not available in this build yet. It needs the Push Notifications entitlement and the gateway's APNs key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Push messages are not delivered yet: this build has no push entitlement and the gateway does not send them. The token is given to a gateway that accepts it. Opening a link such as acpcode://session/<server>/<session> works.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch push.authorization {
        case .notDetermined: return "Not asked"
        case .denied: return "Off in Settings"
        case .authorized, .provisional, .ephemeral: return push.deviceToken == nil ? "Allowed" : "Allowed, token held"
        }
    }
}
#endif
