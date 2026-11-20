import Foundation
import MarkdownParser
import MarkdownView
import os

final class ChatMarkdownPackageCache {
    private struct CacheEntry {
        let contentHash: Int
        let themeVersion: Int
        let package: MarkdownTextView.PreprocessedContent
    }

    /// Times the markdown parse on the trace (Instruments, the "Chat" category), so a scroll trace shows its cost.
    private static let signposter = OSSignposter(subsystem: "com.acpcode.app", category: "Chat")

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    /// The rendered package for a chat entry. The key is the entry's own content hash and a theme version the caller
    /// bumps when the theme changes. Earlier code hashed the whole message and described the whole theme on every
    /// call, which ran for every row on every configure (fix 2, the scroll path).
    func package(
        for entry: ChatEntry,
        theme: MarkdownTheme,
        themeVersion: Int
    ) -> MarkdownTextView.PreprocessedContent {
        lock.lock()
        if let cached = cache[entry.id],
           cached.contentHash == entry.contentHash,
           cached.themeVersion == themeVersion
        {
            lock.unlock()
            return cached.package
        }
        lock.unlock()

        let state = Self.signposter.beginInterval("markdown parse")
        let parserResult = MarkdownParser().parse(entry.text)
        let package = MarkdownTextView.PreprocessedContent(parserResult: parserResult, theme: theme)
        Self.signposter.endInterval("markdown parse", state)

        lock.lock()
        cache[entry.id] = CacheEntry(contentHash: entry.contentHash, themeVersion: themeVersion, package: package)
        lock.unlock()

        return package
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
