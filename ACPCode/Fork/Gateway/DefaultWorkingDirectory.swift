import Foundation

/// The name of the gateway's default project, `working_dir`. The gateway makes and lists it at start
/// (gateway internal/server/working_dir.go). A gateway connection with a blank working directory starts
/// its sessions in this project.
let gatewayDefaultProjectName = "working_dir"

/// What a plain ACP connection with a blank working directory says instead of starting a session.
let plainACPBlankWorkingDirectoryMessage = "Set a working directory for this connection before starting a session."

/// The cwd a new session on a plain ACP connection starts in: the folder asked for, else the connection's
/// own working directory, both trimmed. Nil when both are blank. The session is then not started, and "/"
/// is never used in its place. A stored or typed "/" is a folder like any other.
func plainACPNewSessionCwd(requested: String?, connectionWorkingDirectory: String) -> String? {
    for candidate in [requested ?? "", connectionWorkingDirectory] {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return nil
}

/// True when a new session on this server must not be sent: a plain ACP connection with no folder to start in.
/// A gateway is decided by gatewayNewSessionBlocked.
func plainACPNewSessionBlocked(isGateway: Bool, requested: String?, connectionWorkingDirectory: String) -> Bool {
    !isGateway && plainACPNewSessionCwd(requested: requested, connectionWorkingDirectory: connectionWorkingDirectory) == nil
}
