import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Notification permission and the device token (PLAN 3.20, FR-23).
///
/// What this does: asks the person for permission when they choose to, registers with Apple, and
/// keeps the token in memory. What it does not do yet: send the token anywhere. The gateway has no
/// method to receive it (push delivery is 3.11, which needs an APNs key and a device), and this app
/// target has no Push Notifications entitlement, so registration fails with Apple's "no valid
/// aps-environment" error. That is shown as "not available in this build", not as a failure.
enum PushAuthorization: Equatable {
    case notDetermined, denied, authorized, provisional, ephemeral
}

protocol NotificationAuthorizing {
    func authorizationStatus() async -> PushAuthorization
    func requestAuthorization() async throws -> Bool
}

protocol RemoteNotificationRegistrar {
    @MainActor func registerForRemoteNotifications()
}

struct SystemNotificationCenter: NotificationAuthorizing {
    func authorizationStatus() async -> PushAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }
}

struct SystemRemoteNotificationRegistrar: RemoteNotificationRegistrar {
    @MainActor func registerForRemoteNotifications() {
#if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
#endif
    }
}

@MainActor
final class PushRegistration: ObservableObject {
    static let shared = PushRegistration()

    @Published private(set) var authorization: PushAuthorization = .notDetermined
    /// The APNs device token as lowercase hex, in memory only.
    @Published private(set) var deviceToken: String?
    /// The last problem, in words for a person.
    @Published private(set) var failure: String?
    /// True when Apple refused registration because this build has no push entitlement. That is an
    /// expected state until the entitlement and the gateway's APNs key exist, so it is not a failure.
    @Published private(set) var notAvailableInBuild = false

    private let center: NotificationAuthorizing
    private let registrar: RemoteNotificationRegistrar

    init(center: NotificationAuthorizing = SystemNotificationCenter(),
         registrar: RemoteNotificationRegistrar = SystemRemoteNotificationRegistrar()) {
        self.center = center
        self.registrar = registrar
    }

    var isAllowed: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    func refreshStatus() async {
        authorization = await center.authorizationStatus()
        if isAllowed { registrar.registerForRemoteNotifications() } // a token can change; ask again each launch
    }

    /// Asks for permission (once the system lets us ask) and registers when it is given. Called only
    /// when the person taps the button: the app never asks by itself.
    func enable() async {
        failure = nil
        do {
            let granted = try await center.requestAuthorization()
            authorization = await center.authorizationStatus()
            if granted { registrar.registerForRemoteNotifications() }
        } catch {
            failure = "Could not ask for permission: \(error.localizedDescription)"
        }
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        failure = nil
        notAvailableInBuild = false
    }

    func didFailToRegister(_ error: Error) {
        deviceToken = nil
        let description = error.localizedDescription
        if description.contains("aps-environment") {
            // Apple's answer for a build without the Push Notifications entitlement: not a fault to show in red.
            failure = nil
            notAvailableInBuild = true
        } else {
            notAvailableInBuild = false
            failure = "Registration failed: \(description)"
        }
    }
}
