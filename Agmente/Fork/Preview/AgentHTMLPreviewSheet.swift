#if canImport(UIKit)
import SwiftUI
import UIKit

// PLAN 5.4 / FR-39: the sheet the chat opens for agent HTML. Read-only: no network, scripts off by default.

/// What the sheet shows. Identified per presentation, so a second tap opens a fresh preview.
struct AgentHTMLPreviewPayload: Identifiable {
    let id = UUID()
    let html: String
}

struct AgentHTMLPreviewSheet: View {
    let html: String
    @Environment(\.dismiss) private var dismiss
    @State private var scriptsEnabled = false
    @State private var blockedLink: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Run scripts", isOn: $scriptsEnabled)
                        .accessibilityIdentifier("htmlPreviewScriptsToggle")
                    Text("Sandboxed preview: no network")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("htmlPreviewSandboxLabel")
                    if let blockedLink {
                        // A tapped link is shown as text, never opened.
                        Text("Link not opened: \(blockedLink)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("htmlPreviewBlockedLink")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                AgentHTMLWebView(
                    html: html,
                    scriptsEnabled: scriptsEnabled,
                    onBlockedLink: { url in
                        blockedLink = AgentHTMLPreviewSheet.printable(url.absoluteString)
                    }
                )
                .accessibilityIdentifier("htmlPreviewWebView")
            }
            .navigationTitle("HTML preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("htmlPreviewDone")
                }
            }
        }
    }

    /// The URL text is agent-supplied: strip control characters and cut it.
    static func printable(_ text: String, limit: Int = 300) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let string = String(String.UnicodeScalarView(cleaned))
        return string.count > limit ? String(string.prefix(limit)) + "…" : string
    }
}

/// Hosts the sandboxed web view. A change of `scriptsEnabled` loads the document again under the new policy.
struct AgentHTMLWebView: UIViewRepresentable {
    let html: String
    let scriptsEnabled: Bool
    var onBlockedLink: ((URL) -> Void)?

    @MainActor
    final class Coordinator {
        let controller = AgentHTMLPreviewController(scriptsEnabled: false)
        var loadedHTML: String?
        var loadedScripts: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebViewContainer {
        let container = WKWebViewContainer()
        let controller = context.coordinator.controller
        controller.onBlockedLink = onBlockedLink
        container.install(controller.webView)
        return container
    }

    func updateUIView(_ uiView: WKWebViewContainer, context: Context) {
        let controller = context.coordinator.controller
        controller.onBlockedLink = onBlockedLink
        let needsLoad = context.coordinator.loadedHTML != html || context.coordinator.loadedScripts != scriptsEnabled
        guard needsLoad else { return }
        context.coordinator.loadedHTML = html
        context.coordinator.loadedScripts = scriptsEnabled
        Task { @MainActor in
            // A failed load shows a blank page. Nothing is retried: the sandbox fails closed.
            try? await controller.show(html: html, scriptsEnabled: scriptsEnabled)
        }
    }
}

/// Plain host view for the web view. The web view fills it.
final class WKWebViewContainer: UIView {
    func install(_ webView: UIView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

extension View {
    /// The chat's HTML preview sheet (the same sheet on the ACP and Codex screens).
    func agentHTMLPreviewSheet(_ payload: Binding<AgentHTMLPreviewPayload?>) -> some View {
        sheet(item: payload) { payload in
            AgentHTMLPreviewSheet(html: payload.html)
        }
    }
}
#endif
