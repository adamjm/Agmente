import Foundation
import Darwin
import Testing
import UIKit
import WebKit
import ACPClient
@testable import Agmente

// PLAN 5.4 / 5.5 gate: FR-39, T-38. Agent HTML is untrusted. The hostile page below tries every
// network path a page has. A local test server on 127.0.0.1 must receive 0 requests, with scripts
// off and with scripts on. The page runs in a real WKWebView hosted in a window.

// MARK: - Document wrapping and fence scanning (pure)

struct AgentHTMLDocumentTests {
    private func lowered(_ text: String) -> String { text.lowercased() }

    @Test func policyIsInjectedExactlyOnceEvenWhenAgentHTMLHasItsOwnPolicy() {
        let html = #"<META HTTP-EQUIV="Content-Security-Policy" CONTENT="default-src *"><p>hi</p>"#
        let doc = AgentHTMLSecurity.wrap(html, scriptsEnabled: true)
        #expect(AgentHTMLSecurity.occurrences(of: "content-security-policy", in: lowered(doc)) == 1)
        #expect(!doc.contains("default-src *"))
        #expect(doc.contains("default-src 'none'"))
    }

    @Test func policyStartsInTheHeadBeforeAnyAgentContent() throws {
        let doc = AgentHTMLSecurity.wrap("<img src=x>", scriptsEnabled: false)
        let policy = try #require(doc.range(of: "Content-Security-Policy"))
        let agentContent = try #require(doc.range(of: "<img src=x>"))
        #expect(policy.lowerBound < agentContent.lowerBound)
        #expect(doc.range(of: "</head>")!.lowerBound > policy.lowerBound)
    }

    @Test func scriptSourceIsAllowedOnlyWhenScriptsAreOn() {
        let off = AgentHTMLSecurity.wrap("<p>x</p>", scriptsEnabled: false)
        let on = AgentHTMLSecurity.wrap("<p>x</p>", scriptsEnabled: true)
        #expect(!off.contains("script-src"))
        #expect(on.contains("script-src 'unsafe-inline'"))
        #expect(off.contains("img-src data: blob:"))
        #expect(off.contains("style-src 'unsafe-inline'"))
    }

    @Test func agentBaseTagsAreRemoved() {
        let html = #"<base href="http://127.0.0.1:1/evil/"><BASE HREF="http://example.com"/><p>x</p>"#
        let doc = AgentHTMLSecurity.wrap(html, scriptsEnabled: true)
        #expect(!lowered(doc).contains("<base"))
        #expect(!lowered(doc).contains("127.0.0.1:1"))
        #expect(!lowered(doc).contains("example.com"))
        #expect(AgentHTMLSecurity.occurrences(of: "<p>x</p>", in: doc) == 1)
    }

    @Test func metaRefreshIsRemoved() {
        let doc = AgentHTMLSecurity.wrap(#"<meta http-equiv="refresh" content="0; url=http://127.0.0.1:1/">"#, scriptsEnabled: false)
        #expect(!lowered(doc).contains("refresh"))
    }

    @Test func headCloseTrickDoesNotAddAStructure() {
        let html = "</head><base href='http://127.0.0.1:1/'><body onload=x></body></html><head><title>t</title>"
        let doc = AgentHTMLSecurity.wrap(html, scriptsEnabled: false)
        let lower = lowered(doc)
        #expect(AgentHTMLSecurity.occurrences(of: "</head>", in: lower) == 1)
        #expect(AgentHTMLSecurity.occurrences(of: "<head>", in: lower) == 1)
        #expect(AgentHTMLSecurity.occurrences(of: "<body>", in: lower) == 1)
        #expect(AgentHTMLSecurity.occurrences(of: "</body>", in: lower) == 1)
        #expect(!lower.contains("<base"))
        #expect(!lower.contains("onload"))
    }

    @Test func tagsThatRebuildAfterRemovalAreRemovedToo() {
        let doc = AgentHTMLSecurity.wrap("<<base href=x>base href=y>", scriptsEnabled: false)
        #expect(!lowered(doc).contains("<base"))
    }

    @Test func linkTagsAreLeftToThePolicy() {
        // Stylesheet loads are blocked by the policy and the rule list; the sanitizer does not need to know them.
        let doc = AgentHTMLSecurity.wrap(#"<link rel="stylesheet" href="http://127.0.0.1:1/s.css">"#, scriptsEnabled: false)
        #expect(doc.contains("<link rel=\"stylesheet\""))
    }

    @Test func fencedHTMLBlocksAreFoundAndOthersAreIgnored() {
        let markdown = "intro\n```html\n<p>a</p>\n```\n\n```python\nprint(1)\n```\n```HTML\n<b>x</b>\n```\n"
        #expect(HTMLFenceScanner.htmlBlocks(in: markdown) == ["<p>a</p>\n", "<b>x</b>\n"])
        #expect(HTMLFenceScanner.htmlBlocks(in: "no code here").isEmpty)
    }
}

// MARK: - Media ingest of text/html resources (pure)

struct AgentHTMLIngestTests {
    @Test func htmlResourceTextBecomesPreviewContent() {
        let item = ForkMediaIngest.item(for: .resource(uri: "file:///a.html", mimeType: "text/html", blob: nil, text: "<p>x</p>"))
        guard case .html(let source) = item.content else { Issue.record("expected html content"); return }
        #expect(source == "<p>x</p>")
    }

    @Test func htmlResourceBlobIsDecodedAsUTF8() {
        let blob = Data("<p>y</p>".utf8).base64EncodedString()
        let item = ForkMediaIngest.item(for: .resource(uri: nil, mimeType: "text/html; charset=utf-8", blob: blob, text: nil))
        guard case .html(let source) = item.content else { Issue.record("expected html content"); return }
        #expect(source == "<p>y</p>")
    }

    @Test func malformedOrOversizedHTMLIsAPlaceholder() {
        let bad = ForkMediaIngest.item(for: .resource(uri: nil, mimeType: "text/html", blob: "%%%", text: nil))
        guard case .placeholder = bad.content else { Issue.record("expected placeholder for bad base64"); return }
        let big = String(repeating: "a", count: AgentHTMLSecurity.maxSourceBytes + 1)
        let tooLarge = ForkMediaIngest.item(for: .resource(uri: nil, mimeType: "text/html", blob: nil, text: big))
        guard case .placeholder = tooLarge.content else { Issue.record("expected placeholder for oversize html"); return }
    }

    @Test func resourceLinkStillIsNeverFetchedAsHTML() {
        let item = ForkMediaIngest.item(for: .resourceLink(uri: "https://127.0.0.1/x.html", name: "x", title: nil, mimeType: "text/html", size: nil))
        guard case .link = item.content else { Issue.record("resource_link must stay a link row"); return }
    }
}

// MARK: - A plain TCP probe on 127.0.0.1 (no dependency)

/// Counts TCP connections and received bytes on 127.0.0.1. Any request from the web view shows here.
final class LoopbackRequestProbe: @unchecked Sendable {
    enum ProbeError: Error { case socket, bind }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var accepted = 0
    private var bytesReceived = 0
    private var running = false

    static func start() throws -> LoopbackRequestProbe {
        let probe = LoopbackRequestProbe()
        try probe.open()
        return probe
    }

    private func open() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw ProbeError.bind
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        lock.lock()
        listenFD = fd
        port = UInt16(bigEndian: assigned.sin_port)
        running = true
        lock.unlock()
        let thread = Thread { self.acceptLoop(fd) }
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            lock.lock()
            let stillRunning = running
            lock.unlock()
            if !stillRunning {
                if client >= 0 { close(client) }
                break
            }
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            lock.lock()
            accepted += 1
            lock.unlock()
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            if count > 0 {
                lock.lock()
                bytesReceived += count
                lock.unlock()
            }
            close(client)
        }
        close(fd)
    }

    func snapshot() -> (accepted: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (accepted, bytesReceived)
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let listening = port
        lock.unlock()
        guard wasRunning else { return }
        // Wake the blocked accept with one connection to ourselves; the loop then sees running == false.
        let wake = socket(AF_INET, SOCK_STREAM, 0)
        if wake >= 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = listening.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(wake)
        }
    }
}

// MARK: - T-38

@MainActor
struct AgentHTMLPreviewTests {
    /// Hostile page: fetch, XHR, external img and stylesheet, iframe, form post, window.open, top navigation,
    /// meta refresh, and a base tag that tries to redirect relative URLs.
    static func hostilePage(port: UInt16) -> String {
        let origin = "http://127.0.0.1:\(port)"
        return """
        <!doctype html><html><head>
        <base href="\(origin)/base/">
        <meta http-equiv="refresh" content="0; url=\(origin)/refresh">
        <meta http-equiv="Content-Security-Policy" content="default-src *">
        <link rel="stylesheet" href="\(origin)/style.css">
        </head><body>
        <img src="\(origin)/img.png">
        <img src="pic.png">
        <iframe src="\(origin)/frame"></iframe>
        <form id="f" action="\(origin)/form" method="post"><input name="x" value="1"></form>
        <script>
          fetch("\(origin)/fetch").catch(function () {});
          var xhr = new XMLHttpRequest();
          xhr.open("GET", "\(origin)/xhr");
          xhr.send();
          window.open("\(origin)/popup");
          setTimeout(function () { document.getElementById("f").submit(); }, 50);
          setTimeout(function () { location = "\(origin)/top"; }, 200);
        </script>
        </body></html>
        """
    }

    /// Loads in a real web view in a window. Fails after `seconds` (bounded wait).
    private func loadBounded(_ controller: AgentHTMLPreviewController, html: String, seconds: UInt64 = 15) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await controller.load(html) }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw AgentHTMLPreviewError.loadInterrupted
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func host(_ view: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        view.frame = root.view.bounds
        root.view.addSubview(view)
        return window
    }

    private func runHostilePage(scriptsEnabled: Bool) async throws -> (accepted: Int, bytes: Int) {
        let probe = try LoopbackRequestProbe.start()
        defer { probe.stop() }
        let controller = AgentHTMLPreviewController(scriptsEnabled: scriptsEnabled)
        let window = host(controller.webView)
        defer { window.isHidden = true }
        try await loadBounded(controller, html: Self.hostilePage(port: probe.port))
        // Scripts run during the load; the timers fire within 200 ms. Give any request time to arrive.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return probe.snapshot()
    }

    @Test func t38HostilePageSendsNoRequestsWithScriptsOff() async throws {
        let result = try await runHostilePage(scriptsEnabled: false)
        #expect(result.accepted == 0, "test server received \(result.accepted) connections, \(result.bytes) bytes")
    }

    @Test func t38HostilePageSendsNoRequestsWithScriptsOn() async throws {
        let result = try await runHostilePage(scriptsEnabled: true)
        #expect(result.accepted == 0, "test server received \(result.accepted) connections, \(result.bytes) bytes")
    }

    /// Harness check: the same page in an unrestricted web view does reach the probe. Without this the
    /// zero counts above could mean the probe cannot see requests at all.
    @Test func t38ControlUnrestrictedPageReachesTheProbe() async throws {
        let probe = try LoopbackRequestProbe.start()
        defer { probe.stop() }
        let web = WKWebView(frame: .zero)
        let window = host(web)
        defer { window.isHidden = true }
        web.loadHTMLString(Self.hostilePage(port: probe.port), baseURL: nil)
        // Cold WebKit start can take several seconds, so poll (bounded) instead of one fixed wait.
        for _ in 0..<60 where probe.snapshot().accepted == 0 {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        #expect(probe.snapshot().accepted > 0, "control page reached the probe 0 times; the probe is not conclusive")
    }
}
