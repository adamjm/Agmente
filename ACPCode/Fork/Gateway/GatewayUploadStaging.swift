import Foundation

/// The private copy a picked file lives in until it is sent or dropped (D-115). The picker's file is
/// read through its security scope, copied into a folder the app owns, and the copy is what is read and
/// sent. Every folder is removed when its upload ends, when the sheet closes, and at the next launch.
enum GatewayUploadStaging {
    /// Folder names start with this prefix, so a launch can find the ones an earlier run left behind.
    static let prefix = "acpcode-upload-"

    /// The root the staging folders live in.
    static var root: URL { FileManager.default.temporaryDirectory }

    /// A new, empty folder for one upload.
    static func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `source` into `folder` under `name`, reading it through the file coordinator, because a file from
    /// a cloud provider may be a placeholder that the coordinator downloads first. Returns the copy's URL.
    static func copy(_ source: URL, into folder: URL, named name: String) throws -> URL {
        let destination = folder.appendingPathComponent(name)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                try FileManager.default.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }

    /// Removes a staging folder. A folder that is already gone is not an error.
    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the staging folders that earlier runs left behind. Called once, when the upload model starts.
    static func removeStale() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            remove(entry)
        }
    }
}
