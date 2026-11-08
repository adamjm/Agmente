import Foundation
import ACP

/// A media-like ACP content block found in a `session/update` payload (PLAN 5.1, FR-37).
///
/// This type only describes what the agent sent. It never decodes or fetches anything:
/// `data` and `blob` stay as the base64 text from the wire, and a `resourceLink` is only a
/// reference. Size and MIME checks belong to the view layer (`ACPCode/Fork/ForkImage*`).
public enum ACPMediaBlock: Equatable, Sendable {
    /// `{"type":"image","data":<base64>,"mimeType":...,"uri":...}`
    case image(mimeType: String, data: String, uri: String?)
    /// `{"type":"resource","resource":{"uri":...,"mimeType":...,"blob":<base64> | "text":...}}`
    case resource(uri: String?, mimeType: String?, blob: String?, text: String?)
    /// `{"type":"resource_link","uri":...,"name":...}`. Never fetched by the client.
    case resourceLink(uri: String, name: String?, title: String?, mimeType: String?, size: Int?)
}

extension ACPSessionUpdateParser {
    /// Parses one content block. Returns nil for text blocks, unknown types and malformed blocks.
    public static func mediaBlock(from block: [String: ACP.Value]) -> ACPMediaBlock? {
        switch block["type"]?.stringValue {
        case "image":
            guard let data = block["data"]?.stringValue else { return nil }
            return .image(
                mimeType: block["mimeType"]?.stringValue ?? "",
                data: data,
                uri: block["uri"]?.stringValue
            )
        case "resource":
            guard let resource = block["resource"]?.objectValue else { return nil }
            let blob = resource["blob"]?.stringValue
            let text = resource["text"]?.stringValue
            guard blob != nil || text != nil || resource["uri"]?.stringValue != nil else { return nil }
            return .resource(
                uri: resource["uri"]?.stringValue,
                mimeType: resource["mimeType"]?.stringValue,
                blob: blob,
                text: text
            )
        case "resource_link":
            guard let uri = block["uri"]?.stringValue, !uri.isEmpty else { return nil }
            return .resourceLink(
                uri: uri,
                name: block["name"]?.stringValue,
                title: block["title"]?.stringValue,
                mimeType: block["mimeType"]?.stringValue,
                size: block["size"]?.intValue
            )
        default:
            return nil
        }
    }

    /// Finds media blocks in an update's `content`: a single block, an array of blocks, or an
    /// array of tool-call content wrappers (`{"type":"content","content":{...}}`).
    public static func mediaBlocks(from update: [String: ACP.Value]) -> [ACPMediaBlock] {
        guard let content = update["content"] else { return [] }
        var result: [ACPMediaBlock] = []
        func visit(_ value: ACP.Value, depth: Int) {
            guard depth < 3, let object = value.objectValue else { return }
            if let block = mediaBlock(from: object) {
                result.append(block)
            } else if let inner = object["content"] {
                visit(inner, depth: depth + 1)
            }
        }
        if case let .array(items) = content {
            for item in items.prefix(64) { visit(item, depth: 0) }
        } else {
            visit(content, depth: 0)
        }
        return result
    }
}
