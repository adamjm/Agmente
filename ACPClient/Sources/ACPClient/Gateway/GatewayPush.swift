import Foundation
import ACP

// Push token registration (DECISIONS D-052). The gateway keys the token by the authenticated
// identity and device, so a device can only set or remove its own.

public enum PushEnvironment: String, Sendable {
    case sandbox, production
}

public extension GatewayClient {
    /// `_acpcode/push/register`: stores this device's APNs token (lowercase or uppercase hex).
    func registerPush(deviceToken: String, environment: PushEnvironment) async throws {
        _ = try await call("_acpcode/push/register",
                           .object(["deviceToken": .string(deviceToken), "environment": .string(environment.rawValue)]))
    }

    /// `_acpcode/push/unregister`: removes this device's token. Not an error when there is none.
    func unregisterPush() async throws {
        _ = try await call("_acpcode/push/unregister", .object([:]))
    }
}
