import CoreData
import Foundation

/// Protection for the Core Data store on disk (FR-15, PLAN 2.8).
enum StoreProtection {
    /// SQLite files that belong to one store.
    static func files(for storeURL: URL) -> [URL] {
        [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
    }

    static func apply(to description: NSPersistentStoreDescription) {
        // Unreadable while the device is locked.
        description.setOption(FileProtectionType.complete as NSObject, forKey: NSPersistentStoreFileProtectionKey)
        // Overwrite deleted content, so erased secrets do not stay in free pages (PLAN 2.2).
        var pragmas = (description.options[NSSQLitePragmasOption] as? [String: String]) ?? [:]
        pragmas["secure_delete"] = "ON"
        description.setOption(pragmas as NSDictionary, forKey: NSSQLitePragmasOption)
    }

    /// Keep the store out of iCloud and device backups. Applied at every launch, because SQLite can
    /// recreate the -wal and -shm files.
    static func excludeFromBackup(storeURL: URL) {
        for file in files(for: storeURL) where FileManager.default.fileExists(atPath: file.path) {
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
