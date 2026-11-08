import ACPClient
import Foundation
import Security

/// Security settings the add-server form passes along with a server (FR-11, FR-13, FR-14).
struct ServerSecurityInput: @unchecked Sendable {
    /// Allows ws:// and limits the server to local hosts (D-019).
    var localOnly: Bool = false
    /// Base64 SHA-256 SPKI pins, one per line (FR-13). Empty means no pinning.
    var spkiPins: String = ""
    /// Client certificate for mutual TLS (FR-14). Nil means none.
    var clientIdentity: SecIdentity?
    /// True when the form changed the client certificate (imported or removed one).
    var clientIdentityChanged: Bool = false

    /// TLS options for a connection, or an error message for invalid pins.
    func tlsOptions() -> Result<TransportTLSOptions, AppViewModel.AddServerValidationError> {
        guard let pins = TransportTLSOptions.parsePins(spkiPins) else {
            return .failure(.other("Certificate pins must be base64 SHA-256 values, one per line."))
        }
        return .success(TransportTLSOptions(spkiPins: pins, clientIdentity: clientIdentity))
    }
}

extension ACPServerConfiguration {
    /// TLS options for connecting to this saved server: its pins and its stored client identity.
    func tlsOptions(identities: ClientIdentityStore = .shared) -> TransportTLSOptions {
        TransportTLSOptions(
            spkiPins: TransportTLSOptions.parsePins(spkiPins) ?? [],
            clientIdentity: identities.load(serverId: id)
        )
    }
}

extension ACPServerConfiguration {
    func withPins(_ pins: String) -> ACPServerConfiguration {
        var copy = self
        copy.spkiPins = pins
        return copy
    }
}
