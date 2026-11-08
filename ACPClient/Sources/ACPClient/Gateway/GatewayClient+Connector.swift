import Foundation
import ACP

/// Typed calls to the connector's phone methods (contract C5, D-097). Errors are the same
/// `GatewayError` the other gateway methods throw: a JSON-RPC error keeps its code and the gateway's text.
public extension GatewayClient {
    /// `_acpcode/connector/pending`: the client pairings waiting for an answer.
    func connectorPending() async throws -> [GatewayConnectorPairing] {
        let result = try await call("_acpcode/connector/pending", .object([:]))
        return try decode([GatewayConnectorPairing].self, from: result["pairings"], what: "pairings")
    }

    /// `_acpcode/connector/approve`: makes a grant for the pairing with `scope` and returns its id.
    /// Approval needs a person's tap; the gateway checks the code shown on the phone against the page.
    @discardableResult
    func approveConnectorPairing(pairingId: String, scope: GatewayConnectorScope) async throws -> String {
        let result = try await call("_acpcode/connector/approve", .object(["pairingId": .string(pairingId), "scope": scope.value]))
        guard let grantId = result["grantId"]?.stringValue else { throw GatewayError.invalidResponse("grantId") }
        return grantId
    }

    /// `_acpcode/connector/deny`: the pairing is refused and its page is told so.
    func denyConnectorPairing(pairingId: String) async throws {
        _ = try await call("_acpcode/connector/deny", .object(["pairingId": .string(pairingId)]))
    }

    /// `_acpcode/connector/grants`: every grant, with its scope and when it was last used.
    func connectorGrants() async throws -> [GatewayConnectorGrant] {
        let result = try await call("_acpcode/connector/grants", .object([:]))
        return try decode([GatewayConnectorGrant].self, from: result["grants"], what: "grants")
    }

    /// `_acpcode/connector/revoke`: the grant stops working at once.
    func revokeConnectorGrant(grantId: String) async throws {
        _ = try await call("_acpcode/connector/revoke", .object(["grantId": .string(grantId)]))
    }
}
