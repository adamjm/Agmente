import Foundation
import ACP

// Phone file upload into a project folder (D-109). The gateway writes one file into the project root. These
// rules mirror the gateway's (gateway/internal/server/upload.go) so the phone refuses early; the gateway
// still decides, and its text is what the person sees when it refuses.

/// The upload rules the phone checks before it sends anything.
public enum GatewayUploadRules {
    /// The decoded size cap: 8 MiB. Larger files are refused before they are read into memory.
    public static let maxBytes = 8 * 1024 * 1024
    /// The base64 length of `maxBytes`: 4 * ceil(n / 3). A longer encoding is refused before it is sent.
    public static let maxEncodedLength = 4 * ((maxBytes + 2) / 3)
    /// The longest name, in bytes (the folder-name rule, D-091).
    public static let maxNameBytes = 64
    /// The file types the gateway accepts (lowercase, without the dot).
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "txt", "md", "csv", "json"]
    /// Names the agent reads as instructions or configuration. The gateway refuses them in any case.
    public static let reservedNames: Set<String> = ["agents.md", "claude.md", "opencode.json"]

    /// The text for a file the phone refuses before it is read or sent. Nil when the name may be uploaded.
    /// The gateway may still refuse for a reason the phone cannot know (a secret name in the project's own
    /// deny-list, a name that already exists), and its text is shown then.
    public static func nameProblem(_ name: String) -> String? {
        let bytes = Array(name.utf8)
        let syntaxOK = !bytes.isEmpty && bytes.count <= maxNameBytes && bytes[0] != UInt8(ascii: ".")
            && bytes.first != UInt8(ascii: " ") && bytes.last != UInt8(ascii: " ")
            && bytes.allSatisfy(isFolderNameByte)
        guard syntaxOK else {
            return "The name must be a file name of 1 to 64 characters: letters, digits, space, dot, hyphen and underscore, not starting with a dot."
        }
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0,
              allowedExtensions.contains(String(decoding: bytes[(dot + 1)...], as: UTF8.self).lowercased()) else {
            return "This file type is not allowed. Allowed: png, jpg, jpeg, gif, webp, heic, pdf, txt, md, csv, json."
        }
        if reservedNames.contains(name.lowercased()) {
            return "This name is reserved: agent instruction files cannot be uploaded."
        }
        return nil
    }

    private static func isFolderNameByte(_ c: UInt8) -> Bool {
        (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
            || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
            || c == UInt8(ascii: " ") || c == UInt8(ascii: ".") || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
    }
}

/// The result of `_acpcode/files/upload`: the stored file name and its size.
public struct GatewayUploadResult: Equatable, Sendable {
    public let path: String
    public let bytes: Int

    public init(path: String, bytes: Int) {
        self.path = path
        self.bytes = bytes
    }
}

/// The result of `_acpcode/files/stat`. `size` and `sha256` come only for a regular file the upload would
/// accept, and only up to the upload cap (D-109).
public struct GatewayFileStat: Equatable, Sendable {
    public let exists: Bool
    public let size: Int?
    public let sha256: String?

    public init(exists: Bool, size: Int?, sha256: String?) {
        self.exists = exists
        self.size = size
        self.sha256 = sha256
    }
}

extension GatewayClient {
    /// `_acpcode/files/upload`: writes `data` as `path` in the project's root folder. The gateway refuses a name
    /// that exists and never replaces one. A file over the cap is refused here, before anything is sent.
    public func uploadFile(projectId: String, path: String, data: Data) async throws -> GatewayUploadResult {
        guard data.count <= GatewayUploadRules.maxBytes else {
            throw GatewayError.rpc(code: -32602, message: "The file is larger than 8 MB.")
        }
        let encoded = data.base64EncodedString()
        guard encoded.utf8.count <= GatewayUploadRules.maxEncodedLength else {
            throw GatewayError.rpc(code: -32602, message: "The file is larger than 8 MB.")
        }
        let result = try await call("_acpcode/files/upload", .object([
            "projectId": .string(projectId),
            "path": .string(path),
            "contentBase64": .string(encoded),
        ]))
        guard let stored = result["path"]?.stringValue, let bytes = result["bytes"]?.intValue else {
            throw GatewayError.invalidResponse("upload")
        }
        return GatewayUploadResult(path: stored, bytes: bytes)
    }

    /// `_acpcode/files/stat`: whether a name exists in the project's root folder, and for a file the upload
    /// would accept, its size and SHA-256 (up to the cap). Used to check an upload whose outcome is unknown.
    public func statFile(projectId: String, path: String) async throws -> GatewayFileStat {
        let result = try await call("_acpcode/files/stat", .object([
            "projectId": .string(projectId),
            "path": .string(path),
        ]))
        guard let exists = result["exists"]?.boolValue else {
            throw GatewayError.invalidResponse("stat")
        }
        return GatewayFileStat(exists: exists, size: result["size"]?.intValue, sha256: result["sha256"]?.stringValue)
    }
}
