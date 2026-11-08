import Foundation

// PLAN 5.4 / FR-39 / D-074, D-075: the document the preview shows is built here, from agent HTML that
// is untrusted input. Pure functions only, so the rules can be unit-tested without a web view.

enum AgentHTMLSecurity {
    /// Custom scheme of the preview. Nothing is served through it; every request fails (see AgentHTMLSchemeHandler).
    static let scheme = "acpcode-preview"
    /// Base URL of the document. Relative URLs in agent HTML resolve here, never to the network.
    static let baseURLString = "acpcode-preview://page/"
    static let baseURL = URL(string: baseURLString)!
    /// Source HTML above this size is refused before wrapping (matches the image limits' order of magnitude).
    static let maxSourceBytes = 1 * 1024 * 1024

    /// The policy with scripts off. Every fetch, frame, form and connection is denied by default.
    static let baseContentSecurityPolicy = "default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    /// Adds `script-src 'unsafe-inline'` only when scripts are on. `default-src 'none'` would block scripts otherwise.
    static func contentSecurityPolicy(scriptsEnabled: Bool) -> String {
        scriptsEnabled ? baseContentSecurityPolicy + "; script-src 'unsafe-inline'" : baseContentSecurityPolicy
    }

    /// Builds the document string. The policy is the first thing in the head, and every agent tag that could
    /// change the document's base, its policy or its structure is removed before the agent's HTML is placed.
    /// Removing is repeated until nothing matches, so removing one tag cannot leave another behind.
    static func wrap(_ html: String, scriptsEnabled: Bool) -> String {
        let body = stripStructuralTags(html)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(scriptsEnabled: scriptsEnabled))"></head>\
        <body>\(body)</body></html>
        """
    }

    /// Tags removed from agent HTML: document structure, base URLs, and every meta tag (refresh, policy, charset).
    /// `<link>` is not removed; the policy blocks its loads.
    private static let structuralTag = try! NSRegularExpression(
        pattern: #"<\s*/?\s*(?:!doctype|html|head|body|base|meta)(?=[\s/>])[^>]*>|<!doctype[^>]*>"#,
        options: [.caseInsensitive]
    )

    static func stripStructuralTags(_ html: String) -> String {
        var current = html
        // Each pass removes at least one match and the text only gets shorter, so the loop ends.
        while true {
            let range = NSRange(current.startIndex..., in: current)
            let next = structuralTag.stringByReplacingMatches(in: current, range: range, withTemplate: "")
            if next == current { return current }
            current = next
        }
    }

    /// Counts a string's occurrences (test and audit helper).
    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}

/// Finds fenced ```html blocks in assistant markdown (PLAN 5.4: the chat's "HTML preview" button).
enum HTMLFenceScanner {
    static let maxBlocks = 8

    private static let fence = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}```[ \t]*(?:html|htm)[^\n]*\n([\s\S]*?)^[ \t]{0,3}```[ \t]*$"#,
        options: [.caseInsensitive]
    )

    static func htmlBlocks(in markdown: String) -> [String] {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return fence.matches(in: markdown, range: range).prefix(maxBlocks).compactMap { match in
            guard match.numberOfRanges > 1, let bodyRange = Range(match.range(at: 1), in: markdown) else { return nil }
            let body = String(markdown[bodyRange])
            return body.utf8.count <= AgentHTMLSecurity.maxSourceBytes ? body : nil
        }
    }
}
