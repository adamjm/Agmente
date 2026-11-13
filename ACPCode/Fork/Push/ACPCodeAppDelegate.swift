#if os(iOS)
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted with `userInfo["url"]` (a deep link) when the person taps a notification.
    static let acpcodeOpenDeepLink = Notification.Name("ACPCodeOpenDeepLink")
}

/// Forwards Apple's registration callbacks to `PushRegistration`, and turns a tap on a notification
/// into a deep link for the session it names.
final class ACPCodeAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // D-111: the approval category has no actions. Answering stays in the app (D-009). Set once, here.
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: ApprovalLocalNotifier.categoryIdentifier, actions: [], intentIdentifiers: [], options: []),
        ])
        Task { @MainActor in await PushRegistration.shared.refreshStatus() }
        Task { @MainActor in ApprovalLiveActivityCoordinator.installAnswerRouter() } // Once and Deny intents (la-decision)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushRegistration.shared.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        // The payload carries the session id only (D-038). The view picks the server: the selected one.
        guard let sessionId = userInfo["sessionId"] as? String, DeepLink.isValidSessionId(sessionId) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .acpcodeOpenDeepLink, object: nil, userInfo: ["sessionId": sessionId])
        }
    }
}
#endif
