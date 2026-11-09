import Foundation
import ACPClient

/// The one `AppViewModel` of this process. ACPCodeApp touches it at launch, the root view reuses it, and the App
/// Intents read it. A second instance would mean a second connection manager and a second socket.
@MainActor
enum ForkProcessModel {
    static let shared = AppViewModel()
}

/// The app's model is the host of the Shortcut's session start. It only connects and reads: it does not change the
/// selected server, the active session or the navigation.
extension AppViewModel: AgentSessionHost {
    var selectedServerID: UUID? { selectedServerId }

    func connectSelectedGateway() async throws -> GatewayClient {
        guard selectedServerId != nil else { throw AgentSessionError.noServer }
        // A connect the app already started may be running. Wait for it, then use its result.
        while isConnecting {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if connectionState != .connected {
            guard await connectAndWait() else { throw AgentSessionError.unreachable }
        }
        // Initialising again is harmless: the connection manager returns early once it is initialised.
        _ = await initializeAndWait()
        guard selectedServerIsGatewayHome, let client = selectedGatewayClient() else {
            throw AgentSessionError.notGateway
        }
        return client
    }
}
