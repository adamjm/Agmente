import SwiftUI


@main
struct ACPCodeApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(ACPCodeAppDelegate.self) private var appDelegate
#endif
    init() {
    }
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
#if os(macOS) || targetEnvironment(macCatalyst)
        .commands {
            PromptComposerCommands()
        }
#endif
#if os(macOS)
        WindowGroup("Session", id: SessionWindowStore.windowId, for: String.self) { value in
            if let sessionKey = value.wrappedValue {
                SessionDetailWindowHost(sessionKey: sessionKey)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle")
            }
        }
#endif
    }
}
