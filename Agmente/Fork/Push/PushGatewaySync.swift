import Foundation
import ACPClient

/// Sends this device's APNs token to a gateway that offers `push` (D-052). One place decides when:
/// a token exists, the notification permission is still on, and the server's `initialize` listed the
/// extension. Nothing is sent to a server that is not the gateway. The token is never logged.
enum PushGatewaySync {
    /// Development-signed builds get sandbox tokens, TestFlight and App Store builds get production ones.
    /// This is a guess from the build configuration; the device test in docs/PUSH-TESTING.md checks it.
    static var environment: PushEnvironment {
#if DEBUG
        return .sandbox
#else
        return .production
#endif
    }

    enum Outcome: Equatable {
        case sent, skippedNoToken, skippedNotAllowed, skippedNoPush, failed(String)
    }

    @discardableResult
    static func sync(token: String?, allowed: Bool, info: GatewayInfo?, client: GatewayClient?,
                     environment: PushEnvironment = PushGatewaySync.environment) async -> Outcome {
        guard let info, info.supports("push"), let client else { return .skippedNoPush }
        guard allowed else { return .skippedNotAllowed }
        guard let token, !token.isEmpty else { return .skippedNoToken }
        do {
            try await client.registerPush(deviceToken: token, environment: environment)
            return .sent
        } catch {
            return .failed((error as? GatewayError)?.message ?? error.localizedDescription)
        }
    }
}
