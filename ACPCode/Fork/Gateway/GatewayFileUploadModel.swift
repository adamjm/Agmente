import Foundation
import Combine
import CryptoKit
import ACPClient

/// The state of the Upload File sheet for one project (D-109). The person picks one file. The file is read and
/// copied into a private folder, checked with the gateway's rules, and sent only when Upload is tapped. There
/// is no automatic retry: a refusal keeps the file selected, and an outcome the phone cannot confirm is checked
/// with `_acpcode/files/stat` before the person decides to upload again.
@MainActor
final class GatewayFileUploadModel: ObservableObject {
    enum Phase: Equatable {
        /// Nothing picked, or the last pick was refused before it was copied.
        case empty
        /// A file is copied and checked, and can be sent.
        case picked(name: String, size: Int)
        /// The request is on its way.
        case sending(name: String)
        /// The gateway stored the file as `path`.
        case saved(path: String, bytes: Int)
        /// The request failed or was cancelled, so the outcome is not known. The file may be on the Mac.
        case unknownOutcome(name: String)
    }

    @Published private(set) var phase: Phase = .empty
    /// The text to show with the phase: a refusal, a check result, or why an outcome is unknown.
    @Published private(set) var message: String?
    @Published private(set) var isChecking = false

    let projectId: String
    private let clientProvider: () -> GatewayClient?
    private var staged: Staged?
    private var sendTask: Task<Void, Never>?

    /// The private copy of the picked file and what the phone knows about it.
    private struct Staged {
        let folder: URL
        let file: URL
        let name: String
        let size: Int
        let sha256: String
    }

    init(projectId: String, clientProvider: @escaping () -> GatewayClient?, removeStaleOnInit: Bool = true) {
        self.projectId = projectId
        self.clientProvider = clientProvider
        if removeStaleOnInit {
            GatewayUploadStaging.removeStale()
        }
    }

    /// The name the staged file will be sent under, or nil.
    var pickedName: String? { staged?.name }

    /// Takes a file the person picked. Refuses a folder, a name or type the gateway would refuse, and a file over
    /// the cap, before anything is copied. A file that passes is copied into a private folder and hashed.
    func choose(_ url: URL) {
        discard()
        message = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            refuse("Choose a file, not a folder.")
            return
        }
        let name = url.lastPathComponent
        if let problem = GatewayUploadRules.nameProblem(name) {
            refuse(problem)
            return
        }
        if let size = values?.fileSize, size > GatewayUploadRules.maxBytes {
            refuse("The file is larger than 8 MB.")
            return
        }
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
                refuse("The file is larger than 8 MB.")
                return
            }
            staged = Staged(folder: folder, file: copy, name: name, size: data.count, sha256: Self.sha256Hex(data))
            phase = .picked(name: name, size: data.count)
        } catch {
            refuse("The file could not be read. Try another file.")
        }
    }

    /// Sends the picked file. Nothing is retried automatically: a refusal keeps the file, and a lost answer moves
    /// to `unknownOutcome` for the person to check.
    func send() {
        guard let staged, case .picked = phase else { return }
        guard let client = clientProvider() else {
            message = "Not connected. Connect to the gateway and try again."
            return
        }
        phase = .sending(name: staged.name)
        message = nil
        let projectId = projectId
        sendTask = Task { [weak self] in
            do {
                let data = try Data(contentsOf: staged.file)
                let result = try await client.uploadFile(projectId: projectId, path: staged.name, data: data)
                self?.finishSaved(path: result.path, bytes: result.bytes)
            } catch let error as GatewayError {
                switch error {
                case .rpc(_, let text):
                    self?.gatewayRefused(text)
                default:
                    self?.outcomeUnknown(name: staged.name, because: "Could not confirm the upload. The file may be on the Mac.")
                }
            } catch {
                self?.outcomeUnknown(name: staged.name, because: "Could not confirm the upload. The file may be on the Mac.")
            }
        }
    }

    /// Stops waiting for a send that is in flight. The request may still finish on the Mac, so the outcome is
    /// unknown until it is checked.
    func cancel() {
        guard case .sending(let name) = phase else { return }
        sendTask?.cancel()
        sendTask = nil
        outcomeUnknown(name: name, because: "The upload was cancelled. The Mac may still save it.")
    }

    /// Asks the gateway whether the file is there, when the outcome of a send is unknown. A file with the same
    /// SHA-256 is saved; no file means the person may upload again; a different file with the name is refused.
    func checkOutcome() async {
        guard let staged, case .unknownOutcome = phase, let client = clientProvider() else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let stat = try await client.statFile(projectId: projectId, path: staged.name)
            if stat.exists, stat.sha256 == staged.sha256 {
                finishSaved(path: staged.name, bytes: staged.size)
            } else if stat.exists {
                phase = .picked(name: staged.name, size: staged.size)
                message = "A different file with this name is already on the Mac. Choose another file or rename this one."
            } else {
                phase = .picked(name: staged.name, size: staged.size)
                message = "The file is not on the Mac. You can upload it again."
            }
        } catch {
            message = "Could not check the Mac. Try again."
        }
    }

    /// Removes the private copy. Called when the sheet closes, when another file is picked, and after a save.
    func discard() {
        if let staged {
            GatewayUploadStaging.remove(staged.folder)
        }
        staged = nil
    }

    private func refuse(_ text: String) {
        phase = .empty
        message = text
    }

    private func gatewayRefused(_ text: String) {
        // The file stays selected for the person to change or send again; the gateway's text says why.
        guard let staged else { return }
        phase = .picked(name: staged.name, size: staged.size)
        message = text
    }

    private func outcomeUnknown(name: String, because text: String) {
        phase = .unknownOutcome(name: name)
        message = text
    }

    private func finishSaved(path: String, bytes: Int) {
        discard()
        sendTask = nil
        phase = .saved(path: path, bytes: bytes)
        message = nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
