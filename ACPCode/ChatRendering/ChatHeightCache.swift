import Foundation
import CoreGraphics

final class ChatHeightCache {
    private struct Key: Hashable {
        let entryId: String
        let width: Int
        let contentHash: Int

        init(entryId: String, width: CGFloat, contentHash: Int) {
            self.entryId = entryId
            self.width = Int(width.rounded(.toNearestOrAwayFromZero))
            self.contentHash = contentHash
        }
    }

    private var cache: [Key: CGFloat] = [:]
    private let lock = NSLock()

    func height(for entry: ChatEntry, width: CGFloat) -> CGFloat? {
        let key = Key(entryId: entry.id, width: width, contentHash: entry.contentHash)
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func store(height: CGFloat, for entry: ChatEntry, width: CGFloat) {
        let key = Key(entryId: entry.id, width: width, contentHash: entry.contentHash)
        lock.lock()
        cache[key] = height
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
