import Foundation
import ACPClient

extension ACPSessionListPayload {
    /// The payload for a `session/list` request to the server the app is connected to.
    ///
    /// A gateway server gets no cwd. The gateway refuses a cwd outside its project roots with
    /// `cwd_rejected` (guard.go `cwdAllowed`), and the server's fallback folder is "/", which is
    /// never inside a root. A plain ACP server keeps its cwd. See SPEC FR-21 and RESULTS 2026-11-07.
    static func forServer(workingDirectory: String, isGateway: Bool) -> ACPSessionListPayload {
        ACPSessionListPayload(workingDirectory: isGateway ? nil : workingDirectory)
    }

    /// Like `forServer`, but returns nil while the gateway flag is unknown (`isGateway` nil), so no
    /// request is built from a guess. The flag is known once the initialize result is applied.
    static func forServerIfKnown(workingDirectory: String, isGateway: Bool?) -> ACPSessionListPayload? {
        guard let isGateway else { return nil }
        return forServer(workingDirectory: workingDirectory, isGateway: isGateway)
    }
}
