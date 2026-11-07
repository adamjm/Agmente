import Foundation

/// The answer of `_agmente/projects/roots` (D-091).
struct GatewayRootsResult: Decodable, Equatable, Sendable {
    let roots: [String]
}

/// The rules for a new project's folder name (D-091). They mirror the gateway's `checkFolderName`
/// in the same order, so the sheet can say what is wrong before anything is sent. The gateway
/// still checks every name, and its answer is what the person sees when they disagree.
public enum GatewayFolderName {
    public static let maxLength = 64

    /// The first rule the name breaks, as text for the person; nil when the name is valid.
    /// The name is checked exactly as typed: nothing is trimmed.
    public static func problem(with name: String) -> String? {
        let bytes = Array(name.utf8)
        if bytes.isEmpty {
            return "Enter a folder name."
        }
        if bytes.count > maxLength {
            return "Use at most \(maxLength) characters."
        }
        if bytes[0] == UInt8(ascii: ".") {
            return "The name must not start with a dot."
        }
        if bytes[0] == UInt8(ascii: " ") || bytes[bytes.count - 1] == UInt8(ascii: " ") {
            return "The name must not start or end with a space."
        }
        if bytes.contains(where: { !isAllowed($0) }) {
            return "Use only letters, digits, spaces, dots, hyphens and underscores."
        }
        return nil
    }

    /// True when `problem(with:)` finds nothing wrong.
    public static func isValid(_ name: String) -> Bool {
        problem(with: name) == nil
    }

    /// ASCII letters, digits, space, dot, hyphen and underscore. A slash or a backslash is not in the
    /// set, so a valid name is always one path component.
    private static func isAllowed(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: " "), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "_"):
            return true
        default:
            return false
        }
    }
}
