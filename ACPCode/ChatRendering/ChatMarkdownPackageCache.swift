import Foundation
import MarkdownParser
import MarkdownView

final class ChatMarkdownPackageCache {
    private struct CacheEntry {
        let contentHash: Int
        let themeIdentity: Int
        let package: MarkdownTextView.PreprocessedContent
    }

    private var cache: [String: CacheEntry] = [:]
    private let lock = NSLock()

    func package(for entryID: String, content: String, theme: MarkdownTheme) -> MarkdownTextView.PreprocessedContent {
        let contentHash = content.hashValue
        let themeIdentity = String(describing: theme).hashValue

        lock.lock()
        if let cached = cache[entryID],
           cached.contentHash == contentHash,
           cached.themeIdentity == themeIdentity
        {
            lock.unlock()
            return cached.package
        }
        lock.unlock()

        return updateCache(entryID: entryID, content: content, contentHash: contentHash, theme: theme, themeIdentity: themeIdentity)
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func updateCache(
        entryID: String,
        content: String,
        contentHash: Int,
        theme: MarkdownTheme,
        themeIdentity: Int
    ) -> MarkdownTextView.PreprocessedContent {
        let parserResult = MarkdownParser().parse(content)
        let package = MarkdownTextView.PreprocessedContent(parserResult: parserResult, theme: theme)

        lock.lock()
        cache[entryID] = CacheEntry(contentHash: contentHash, themeIdentity: themeIdentity, package: package)
        lock.unlock()

        return package
    }
}
