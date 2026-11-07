import Foundation
import ACP
import ACPClient

/// The gateway's elicitation events for the session on screen (PLAN 6C.3, D-090). Called from
/// `handleGatewayEvent` for any event the app has no typed case for, after the event's seq was applied.
extension AppViewModel {
    func handleGatewayElicitationEvent(_ event: GatewayEvent, method: String, server: ServerViewModel) {
        switch method {
        case ElicitationRequest.method:
            do {
                let request = try ElicitationRequest.parse(event.message)
                guard let client = server.gatewayClient else { return }
                gatewayElicitations.present(request, answering: client)
            } catch {
                // Nothing is answered here: the gateway declines it when its wait ends (D-090).
                sessionViewModel?.addSystemMessage("The agent asked for a form this app cannot show. The gateway will decline it when the wait ends.")
            }
        case "_agmente/elicitation_answered":
            let params = event.message["params"]
            guard let id = params?["elicitationId"]?.stringValue else { return }
            gatewayElicitations.closed(elicitationId: id, answeredBy: params?["answeredBy"]?.stringValue)
        default:
            break
        }
    }
}
