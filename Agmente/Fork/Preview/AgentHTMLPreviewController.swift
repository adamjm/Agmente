#if canImport(UIKit)
import UIKit
import WebKit

// PLAN 5.4 / FR-39 / D-074: the sandboxed web view for agent HTML.
//
// Layers, outermost first. Each one alone stops a network load or a script bridge:
//   1. Non-persistent website data store. No cookies, cache or storage survive the view.
//   2. Content rule list: block every URL, except the preview scheme, about: and data:. Installed before the first load.
//   3. Content-Security-Policy in the document (AgentHTMLSecurity): default-src 'none'.
//   4. JavaScript off unless the person turns it on (WKWebpagePreferences, per navigation).
//   5. Navigation: only the initial load and in-page fragments. Every other navigation is cancelled.
//   6. UI delegate: no new windows, no alerts, no file, camera, microphone or permission prompts.
//   7. No WKScriptMessageHandler is registered, so the page has no bridge to the app.

/// Refuses every request on the preview scheme. The document itself comes from `loadHTMLString`,
/// so this handler serves nothing; it only makes any request on the scheme fail.
final class AgentHTMLSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

enum AgentHTMLContentRules {
    static let identifier = "agmente-preview-no-network-v1"

    /// Block everything, then re-allow the three schemes that must load: the document (preview scheme),
    /// about:blank (WebKit's own) and data: (inline images the policy allows). `ignore-previous-rules` must
    /// come after the block rule to take effect.
    static let json = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^agmente-preview:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    static func compile() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? AgentHTMLPreviewError.ruleListUnavailable)
                }
            }
        }
    }
}

enum AgentHTMLPreviewError: Error, Equatable {
    case ruleListUnavailable
    case loadInterrupted
}

@MainActor
final class AgentHTMLPreviewController: NSObject {
    let webView: WKWebView
    private(set) var scriptsEnabled: Bool
    /// Called with a link the person tapped. The link is shown as text; it is never opened.
    var onBlockedLink: ((URL) -> Void)?

    /// Set when a load is started; the first main-frame navigation to the base URL is allowed once.
    private var initialLoadPending = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var ruleListInstalled = false
    /// Tests set this to false to measure the rule list on its own. Production never changes it.
    var installsContentRuleList = true

    init(scriptsEnabled: Bool = false) {
        self.scriptsEnabled = scriptsEnabled
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(AgentHTMLSchemeHandler(), forURLScheme: AgentHTMLSecurity.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = scriptsEnabled
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
    }

    /// Loads agent HTML. Resolves when the document has finished loading, or throws. Bounded by the caller.
    func load(_ html: String) async throws {
        guard html.utf8.count <= AgentHTMLSecurity.maxSourceBytes else {
            throw AgentHTMLPreviewError.loadInterrupted
        }
        if !ruleListInstalled, installsContentRuleList {
            // Fail closed: if the list does not compile, nothing loads.
            let list = try await AgentHTMLContentRules.compile()
            webView.configuration.userContentController.add(list)
        }
        ruleListInstalled = true
        let document = AgentHTMLSecurity.wrap(html, scriptsEnabled: scriptsEnabled)
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = scriptsEnabled
        loadContinuation?.resume(throwing: AgentHTMLPreviewError.loadInterrupted)
        loadContinuation = nil
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            initialLoadPending = true
            webView.loadHTMLString(document, baseURL: AgentHTMLSecurity.baseURL)
        }
    }

    /// Shows a document under a scripts setting. Always loads: the policy is part of the document.
    func show(html: String, scriptsEnabled: Bool) async throws {
        self.scriptsEnabled = scriptsEnabled
        try await load(html)
    }

    /// Allowed: the initial load, and in-page fragment links. Everything else is refused.
    private func isAllowedNavigation(_ url: URL) -> Bool {
        if initialLoadPending, url.absoluteString == AgentHTMLSecurity.baseURLString {
            initialLoadPending = false
            return true
        }
        guard url.fragment != nil else { return false }
        let withoutFragment = url.absoluteString.components(separatedBy: "#").first ?? ""
        return withoutFragment == AgentHTMLSecurity.baseURLString
    }
}

extension AgentHTMLPreviewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = scriptsEnabled
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        guard let url = navigationAction.request.url, isMainFrame, isAllowedNavigation(url) else {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                onBlockedLink?(url)
            }
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

extension AgentHTMLPreviewController: WKUIDelegate {
    /// No new windows: `window.open` and `target=_blank` do nothing.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            onBlockedLink?(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    /// No file picker. The method exists from iOS 18.4 (the app targets 18.0), so it is available there only.
    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
    }

    /// Camera and microphone: always denied. There is no iOS delegate for location; the page gets none
    /// because the app's Info.plist has no location usage text (verify on device).
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}
#endif
