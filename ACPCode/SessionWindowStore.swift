import SwiftUI

#if os(macOS)
@MainActor
struct SessionWindowPayload {
    let model: AppViewModel
    let sessionId: String
    let title: String
    let acpServerViewModel: ServerViewModel?
    let codexServerViewModel: CodexServerViewModel?
    let sessionViewModel: ACPSessionViewModel
}

@MainActor
final class SessionWindowStore {
    static let shared = SessionWindowStore()
    static let windowId = "session-detail-window"

    private var payloads: [String: SessionWindowPayload] = [:]

    func store(_ payload: SessionWindowPayload, for key: String) -> String {
        payloads[key] = payload
        return key
    }

    func payload(for key: String) -> SessionWindowPayload? {
        payloads[key]
    }

    func remove(_ key: String) {
        payloads.removeValue(forKey: key)
    }
}

struct SessionDetailWindowHost: View {
    let sessionKey: String

    var body: some View {
        Group {
            if let payload = SessionWindowStore.shared.payload(for: sessionKey) {
                if let serverViewModel = payload.acpServerViewModel {
                    SessionDetailView(
                        model: payload.model,
                        serverViewModel: serverViewModel,
                        sessionViewModel: payload.sessionViewModel
                    )
                } else if let codexViewModel = payload.codexServerViewModel {
                    CodexSessionDetailView(
                        model: payload.model,
                        serverViewModel: codexViewModel,
                        sessionViewModel: payload.sessionViewModel
                    )
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle")
                }
            } else {
                ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .background(
            WindowTitleUpdater { window in
                guard let payload = SessionWindowStore.shared.payload(for: sessionKey) else { return }
                window.title = payload.title
            }
        )
        .onDisappear {
            SessionWindowStore.shared.remove(sessionKey)
        }
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    let onWindowResolved: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowResolved(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowResolved(window)
            }
        }
    }
}
#endif
