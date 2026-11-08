import Foundation

struct ChatRenderDiff {
    let inserted: [String]
    let removed: [String]
    let updated: [String]

    var isEmpty: Bool {
        inserted.isEmpty && removed.isEmpty && updated.isEmpty
    }

    static func make(old: [ChatEntry], new: [ChatEntry]) -> ChatRenderDiff {
        var oldById: [String: ChatEntry] = [:]
        oldById.reserveCapacity(old.count)
        for entry in old {
            oldById[entry.id] = entry
        }

        var newById: [String: ChatEntry] = [:]
        newById.reserveCapacity(new.count)
        for entry in new {
            newById[entry.id] = entry
        }

        let oldIDs = Set(oldById.keys)
        let newIDs = Set(newById.keys)

        let inserted = newIDs.subtracting(oldIDs).sorted()
        let removed = oldIDs.subtracting(newIDs).sorted()

        let updated = oldIDs.intersection(newIDs).filter { id in
            oldById[id]?.contentHash != newById[id]?.contentHash
        }.sorted()

        return ChatRenderDiff(inserted: inserted, removed: removed, updated: updated)
    }
}
