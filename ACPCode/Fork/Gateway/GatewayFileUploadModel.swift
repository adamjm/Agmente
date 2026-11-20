import Foundation
import Combine
import CryptoKit
import ACPClient

/// The Upload Files sheet for one project (D-115, extended by D-117). The person picks one or more files. Each file
/// is read and copied into a private folder, checked with the gateway's rules, and sent only when Upload is tapped.
/// The files are sent one after another, because the gateway allows one upload per project at a time.
///
/// Rules for a send:
/// - A busy project (`-32000`) is retried after a short wait, up to a limit. It is not skipped.
/// - Any other refusal from the gateway marks that file and the queue goes on to the next one.
/// - An outcome the phone cannot confirm (a lost answer, a cancel) stops the queue. The file may be on the Mac,
///   so the person checks it before anything else is sent.
@MainActor
final class GatewayFileUploadModel: ObservableObject {
    /// One file in the queue.
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            /// Checked and copied; waits for Upload.
            case waiting
            /// The request is on its way.
            case sending
            /// The gateway is busy with another upload to this project; the phone will try again.
            case retrying(attempt: Int)
            /// The gateway stored the file as `path`.
            case saved(path: String, bytes: Int)
            /// The gateway refused this file; `text` says why. The file is not sent again unless the person retries it.
            case refused(text: String)
            /// The outcome is not known. The file may be on the Mac. A check decides what happens next.
            case unknown(text: String)
        }

        let id: UUID
        let name: String
        let size: Int
        let sha256: String
        fileprivate(set) var state: State
        /// The private copy's folder and file. Nil once the copy is removed (after a save).
        fileprivate(set) var staged: Staged?

        struct Staged: Equatable {
            let folder: URL
            let file: URL
        }
    }

    /// At most this many files in one queue, and at most `maxTotalBytes` of copies at once.
    static let maxFiles = 20
    static let maxTotalBytes = 100 * 1024 * 1024
    /// How many times a busy project is asked again before a file is marked refused.
    static let busyAttemptLimit = 5

    @Published private(set) var items: [Item] = []
    /// A problem with the whole queue, such as a pick that was refused or a missing connection.
    @Published private(set) var message: String?
    @Published private(set) var isSending = false
    @Published private(set) var isChecking = false

    let projectId: String
    private let clientProvider: () -> GatewayClient?
    /// Wait between attempts at a busy project. Tests set this to zero.
    var busyRetryDelay: UInt64 = 2_000_000_000
    private var sendTask: Task<Void, Never>?

    init(projectId: String, clientProvider: @escaping () -> GatewayClient?, removeStaleOnInit: Bool = true) {
        self.projectId = projectId
        self.clientProvider = clientProvider
        if removeStaleOnInit {
            GatewayUploadStaging.removeStale()
        }
    }

    /// The files that are still to be sent.
    var waitingItems: [Item] { items.filter { $0.state == .waiting } }

    var canSend: Bool { !isSending && !waitingItems.isEmpty }

    /// Takes files the person picked. Each is refused here, before anything is copied, when the gateway would refuse
    /// it (a folder, a name or type, a size), when it repeats a name already in the queue, or when the queue is full.
    func choose(_ urls: [URL]) {
        message = nil
        for url in urls {
            add(url)
        }
    }

    private func add(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            message = "Choose a file, not a folder."
            return
        }
        let name = url.lastPathComponent
        if let problem = GatewayUploadRules.nameProblem(name) {
            message = problem
            return
        }
        if items.contains(where: { $0.name == name && !isSavedOrRefused($0) }) {
            message = "\(name) is already in the list."
            return
        }
        if items.filter({ $0.state == .waiting }).count >= Self.maxFiles {
            message = "Up to \(Self.maxFiles) files can wait at once. Send them, or remove some."
            return
        }
        if let size = values?.fileSize, size > GatewayUploadRules.maxBytes {
            message = "The file is larger than 10 MB."
            return
        }
        let queuedBytes = items.compactMap { $0.staged != nil ? $0.size : nil }.reduce(0, +)
        do {
            let folder = try GatewayUploadStaging.makeFolder()
            let copy: URL
            do {
                copy = try GatewayUploadStaging.copy(url, into: folder, named: name)
            } catch {
                GatewayUploadStaging.remove(folder)
                throw error
            }
            let data = try Data(contentsOf: copy)
            guard data.count <= GatewayUploadRules.maxBytes else {
                GatewayUploadStaging.remove(folder)
                message = "The file is larger than 10 MB."
                return
            }
            guard queuedBytes + data.count <= Self.maxTotalBytes else {
                GatewayUploadStaging.remove(folder)
                message = "The files together would be over 100 MB. Send these first, or remove some."
                return
            }
            items.append(Item(
                id: UUID(),
                name: name,
                size: data.count,
                sha256: Self.sha256Hex(data),
                state: .waiting,
                staged: .init(folder: folder, file: copy)
            ))
        } catch {
            message = "The file could not be read. Try another file."
        }
    }

    /// Sends the waiting files in order. Runs until the queue is empty, or stops at an unknown outcome.
    func send() {
        guard canSend else { return }
        guard let client = clientProvider() else {
            message = "Not connected. Connect to the gateway and try again."
            return
        }
        message = nil
        isSending = true
        let projectId = projectId
        let delay = busyRetryDelay
        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSending = false
                self.sendTask = nil
            }
            while let next = self.waitingItems.first {
                let stop = await self.sendOne(id: next.id, client: client, projectId: projectId, busyDelay: delay)
                // A cancelled queue waits: the file that was sending is already marked unknown.
                if stop || Task.isCancelled { break }
            }
        }
    }

    /// Sends one file. Returns true when the queue must stop (an unknown outcome).
    private func sendOne(id: UUID, client: GatewayClient, projectId: String, busyDelay: UInt64) async -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), let staged = items[index].staged else { return false }
        let name = items[index].name
        var attempt = 1
        while true {
            setState(id, .sending)
            do {
                let data = try Data(contentsOf: staged.file)
                let result = try await client.uploadFile(projectId: projectId, path: name, data: data)
                finishSaved(id, path: result.path, bytes: result.bytes)
                return false
            } catch let error as GatewayError {
                if case .rpc(let code, _) = error, code == -32000 {
                    // Busy: the project has another upload in flight. Wait and try the same file again.
                    if attempt >= Self.busyAttemptLimit {
                        setState(id, .refused(text: "The project is busy with another upload. Send this file again when it is free."))
                        return false
                    }
                    setState(id, .retrying(attempt: attempt))
                    attempt += 1
                    try? await Task.sleep(nanoseconds: busyDelay)
                    continue
                }
                if case .rpc(_, let text) = error {
                    setState(id, .refused(text: text))
                    return false
                }
                setState(id, .unknown(text: Self.unknownText()))
                return true
            } catch {
                setState(id, .unknown(text: Self.unknownText()))
                return true
            }
        }
    }

    /// Stops waiting for a send that is in flight. The request may still finish on the Mac, so the outcome is
    /// unknown until it is checked. The rest of the queue waits.
    func cancel() {
        guard isSending, let sending = items.first(where: { $0.state == .sending || isRetrying($0) }) else { return }
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        setState(sending.id, .unknown(text: "The upload was cancelled. The Mac may still save it."))
    }

    /// Removes a file from the queue and drops its private copy. A file being sent cannot be removed.
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].state == .sending || isRetrying(items[index]) { return }
        discardStaged(at: index)
        items.remove(at: index)
    }

    /// Puts a refused file back in the waiting list, so Upload sends it again.
    func retry(_ id: UUID) {
        guard !isSending, let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard case .refused = items[index].state, items[index].staged != nil else { return }
        items[index].state = .waiting
        message = nil
    }

    /// Asks the gateway whether an unknown file is there. A file with the same SHA-256 is saved; no file means it
    /// may be sent again; a different file with the name is refused.
    func checkOutcome(_ id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }), case .unknown = items[index].state,
              let client = clientProvider() else { return }
        let item = items[index]
        isChecking = true
        defer { isChecking = false }
        do {
            let stat = try await client.statFile(projectId: projectId, path: item.name)
            if stat.exists, stat.sha256 == item.sha256 {
                finishSaved(id, path: item.name, bytes: item.size)
            } else if stat.exists {
                setState(id, .refused(text: "A different file with this name is already on the Mac. Remove this one, or rename it, and try again."))
            } else {
                setState(id, .waiting)
            }
        } catch {
            message = "Could not check the Mac. Try again."
        }
    }

    /// Removes every private copy. Called when the sheet closes.
    func discardAll() {
        sendTask?.cancel()
        sendTask = nil
        for index in items.indices {
            discardStaged(at: index)
        }
        items = []
        isSending = false
    }

    // MARK: - Private

    private func setState(_ id: UUID, _ state: Item.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private func finishSaved(_ id: UUID, path: String, bytes: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        discardStaged(at: index)
        items[index].state = .saved(path: path, bytes: bytes)
    }

    private func discardStaged(at index: Int) {
        if let staged = items[index].staged {
            GatewayUploadStaging.remove(staged.folder)
        }
        items[index].staged = nil
    }

    /// The text for an outcome the phone cannot confirm. A cancelled send says so, whichever error the cancel raised.
    private static func unknownText() -> String {
        Task.isCancelled
            ? "The upload was cancelled. The Mac may still save it."
            : "Could not confirm the upload. The file may be on the Mac."
    }

    private func isRetrying(_ item: Item) -> Bool {
        if case .retrying = item.state { return true }
        return false
    }

    private func isSavedOrRefused(_ item: Item) -> Bool {
        switch item.state {
        case .saved, .refused: return true
        default: return false
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
