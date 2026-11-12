#if os(iOS)
import SwiftUI

/// The words the notifications row shows. Each sentence is checked against the code: approval alerts post
/// from `ApprovalLocalNotifier` only while the app is in the background and notifications are allowed;
/// remote alerts need a device token, and this build has no Push Notifications entitlement, so iOS gives none.
enum PushSettingsCopy {
    static let deliveryNote = "Approval alerts can appear while the app is in the background, if notifications are allowed. Alerts when the app is closed are not available yet."
}

/// Settings row for notifications (PLAN 3.20). It asks for permission only when tapped, and it shows what
/// is true for this build.
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
            Text(PushSettingsCopy.deliveryNote)
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
