import Foundation
import ACPClient

extension AppViewModel {
    /// Sends the held device token to one gateway server (D-052). Quiet on success; a refusal is logged
    /// without the token.
    func syncPushToken(serverId: UUID) async {
        let push = PushRegistration.shared
        let outcome = await PushGatewaySync.sync(
            token: push.deviceToken, allowed: push.isAllowed,
            info: gatewayInfos[serverId],
            client: (serverViewModels[serverId] as? ServerViewModel)?.gatewayClient)
        RemotePushRegistry.record(outcome, serverId: serverId) // D-111: a local alert is not added on top of a push
        if case .failed(let message) = outcome {
            NSLog("Push registration with the gateway failed: %@", message)
        }
    }

    func syncPushTokenToAllGateways() async {
        for serverId in gatewayInfos.keys { await syncPushToken(serverId: serverId) }
    }
}
