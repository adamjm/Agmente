import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        for _ in 0..<10 {
            let newItem = Item(context: viewContext)
            newItem.timestamp = Date()
        }
        do {
            try viewContext.save()
        } catch {
            // Replace this implementation with code to handle the error appropriately.
            // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()

    let container: NSPersistentContainer
    /// Set when the on-disk store could not be opened (for example, the device is locked and the
    /// file has complete protection). The app then runs on an in-memory store instead of crashing.
    let loadError: NSError?

    /// `storeURL` puts the SQLite store at a given file (tests).
    init(inMemory: Bool = false, storeURL: URL? = nil) {
        container = NSPersistentContainer(name: "ACPCode")
        if let description = container.persistentStoreDescriptions.first {
            if inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let storeURL {
                description.url = storeURL
            }
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            StoreProtection.apply(to: description)
        }
        var failure: NSError?
        container.loadPersistentStores { _, error in
            if let error = error as NSError? { failure = failure ?? error }
        }
        if let failure, !inMemory {
            // Fall back to memory so the app stays usable; nothing is written to disk in this state.
            let fallback = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
            container.persistentStoreDescriptions = [fallback]
            container.loadPersistentStores { _, _ in }
        } else if !inMemory {
            for store in container.persistentStoreCoordinator.persistentStores {
                if let url = store.url { StoreProtection.excludeFromBackup(storeURL: url) }
            }
        }
        loadError = failure
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
