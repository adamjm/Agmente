import Foundation

/// One line of a unified diff, classified for colouring.
struct GitDiffLine: Equatable, Identifiable {
    enum Kind: Equatable { case meta, hunk, added, removed, context, note }
    let id: Int
    let kind: Kind
    let text: String
}

/// One file of a unified diff. `hidden` is true for a secret file whose content the gateway withheld
/// (FR-30): it has a name and no lines.
struct GitDiffFile: Equatable, Identifiable {
    let id: Int
    let path: String
    let hidden: Bool
    let lines: [GitDiffLine]

    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }
}

/// Splits the gateway's diff text into files and lines. Pure; the text is data and is never executed
/// or interpreted beyond its line prefixes.
enum GitDiffText {
    private static let fileStart = "diff --git "
    private static let secretPrefix = "secret file changed: "
    private static let secretSuffix = " (content hidden)"

    static func split(_ text: String) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var path: String?
        var lines: [GitDiffLine] = []
        var inHunk = false
        var lineId = 0

        func flush() {
            if let path { files.append(GitDiffFile(id: files.count, path: path, hidden: false, lines: lines)) }
            path = nil
            lines = []
            inHunk = false
        }
        func add(_ kind: GitDiffLine.Kind, _ text: String) {
            lines.append(GitDiffLine(id: lineId, kind: kind, text: text))
            lineId += 1
        }

        // `components(separatedBy:)` keeps an empty last element for a trailing newline; drop it.
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }

        for row in rows {
            // A diff line never starts with "diff --git " inside a hunk (context lines start with a space).
            if row.hasPrefix(fileStart) {
                flush()
                path = pathFromHeader(row)
                add(.meta, row)
            } else if let hidden = hiddenName(row) {
                // Never inside a hunk: hunk lines start with a space, "+", "-" or "\".
                flush()
                files.append(GitDiffFile(id: files.count, path: hidden, hidden: true, lines: []))
            } else if row.hasPrefix("@@") && path != nil {
                inHunk = true
                add(.hunk, row)
            } else if path == nil {
                // Text before any file header (should not happen): keep it visible.
                path = "(diff)"
                add(.note, row)
            } else if inHunk {
                switch row.first {
                case "+": add(.added, row)
                case "-": add(.removed, row)
                case "\\": add(.note, row)
                default: add(.context, row)
                }
            } else {
                // Header lines between "diff --git" and the first hunk: ---/+++/index/mode/Binary.
                if row.hasPrefix("+++ "), let name = nameFromPlusLine(row) { path = name }
                add(row.hasPrefix("Binary files") ? .note : .meta, row)
            }
        }
        flush()
        return files
    }

    /// The path of a "diff --git a/x b/x" header: the b side, which is the new name.
    static func pathFromHeader(_ header: String) -> String {
        var rest = String(header.dropFirst(fileStart.count))
        // Quoted names (spaces, non-ASCII) look like: "a/x y" "b/x y".
        if rest.hasSuffix("\"") , let open = rest.dropLast().lastIndex(of: "\"") {
            let quoted = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            return stripSide(unquote(quoted))
        }
        // Unquoted: "a/<p> b/<p>". Split at " b/" nearest the middle for equal names.
        if let range = bestSplit(rest) {
            rest = String(rest[range.upperBound...])
            return rest
        }
        return rest
    }

    private static func bestSplit(_ rest: String) -> Range<String.Index>? {
        // Prefer the split where both sides are equal (non-rename); fall back to the last " b/".
        var search = rest.startIndex..<rest.endIndex
        var candidates: [Range<String.Index>] = []
        while let r = rest.range(of: " b/", range: search) {
            candidates.append(r)
            search = r.upperBound..<rest.endIndex
        }
        for r in candidates {
            let left = rest[rest.startIndex..<r.lowerBound].dropFirst(2) // "a/"
            let right = rest[r.upperBound...]
            if left == right { return r }
        }
        return candidates.last
    }

    private static func nameFromPlusLine(_ row: String) -> String? {
        let value = String(row.dropFirst(4))
        if value == "/dev/null" { return nil }
        let name = value.hasPrefix("\"") ? unquote(String(value.dropFirst().dropLast())) : value
        return stripSide(name)
    }

    private static func stripSide(_ name: String) -> String {
        (name.hasPrefix("a/") || name.hasPrefix("b/")) ? String(name.dropFirst(2)) : name
    }

    private static func unquote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func hiddenName(_ row: String) -> String? {
        guard row.hasPrefix(secretPrefix), row.hasSuffix(secretSuffix),
              row.count >= secretPrefix.count + secretSuffix.count else { return nil }
        return String(row.dropFirst(secretPrefix.count).dropLast(secretSuffix.count))
    }
}

/// Which gateway turn a chat message belongs to. The gateway numbers turns from 1 per session by
/// counting `turn_started` events (D-036); the app shows one user message per turn, so the turn of an
/// assistant message is the number of user messages up to and including the last one before it.
/// This holds when the chat was built by replaying the session from the start (D-039). A message that
/// follows no user message has no turn.
enum GitTurnIndex {
    static func turn(forMessageAt index: Int, roles: [ChatMessage.Role]) -> Int? {
        guard roles.indices.contains(index) else { return nil }
        let users = roles[...index].filter { $0 == .user }.count
        return users > 0 ? users : nil
    }

    static func turn(forMessageId id: UUID, in messages: [ChatMessage]) -> Int? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        return turn(forMessageAt: index, roles: messages.map(\.role))
    }
}
