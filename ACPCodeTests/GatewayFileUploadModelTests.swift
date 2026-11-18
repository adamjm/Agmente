import XCTest
import ACP
import ACPClient
@testable import ACPCode

/// A gateway that records calls, returns canned results, and can fail a given file's upload a number of times
/// before it succeeds, or be slowed down.
private final class UploadGatewayFake: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    /// Errors thrown for an upload of this file name, one per call, in order. A name with none succeeds.
    var uploadErrors: [String: [Error]] = [:]
    /// Thrown for every method that has no entry in `uploadErrors`, when set.
    var error: Error?
    var delayNanoseconds: UInt64 = 0

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if method == "_acpcode/files/upload", let name = params?["path"]?.stringValue,
           var pending = uploadErrors[name], !pending.isEmpty {
            let next = pending.removeFirst()
            uploadErrors[name] = pending
            throw next
        }
        if let error { throw error }
        if method == "_acpcode/files/upload", let name = params?["path"]?.stringValue {
            // The gateway reports the decoded size of what it stored.
            let bytes = Data(base64Encoded: params?["contentBase64"]?.stringValue ?? "")?.count ?? 0
            return .object(["path": .string(name), "bytes": .int(bytes)])
        }
        return results[method] ?? .null
    }

    /// The file names of the upload calls, in the order they were made.
    var uploadedNames: [String] {
        calls.compactMap { $0.method == "_acpcode/files/upload" ? $0.params?["path"]?.stringValue : nil }
    }
}

@MainActor
final class GatewayFileUploadModelTests: XCTestCase {
    private var sourceDir: URL!

    override func setUp() async throws {
        sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sourceDir)
    }

    private func makeFile(_ name: String, bytes: Data) throws -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func model(_ fake: UploadGatewayFake?) -> GatewayFileUploadModel {
        let client = fake.map { GatewayClient($0) }
        let m = GatewayFileUploadModel(projectId: "p1", clientProvider: { client }, removeStaleOnInit: false)
        m.busyRetryDelay = 0
        return m
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func states(_ m: GatewayFileUploadModel) -> [GatewayFileUploadModel.Item.State] {
        m.items.map(\.state)
    }

    // MARK: - Picking

    // A folder is refused before anything is copied.
    func testAFolderIsRefusedWithNothingCopied() throws {
        let m = model(UploadGatewayFake())
        m.choose([sourceDir])
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertEqual(m.message, "Choose a file, not a folder.")
    }

    // A name the gateway would refuse is refused here, before the file is read.
    func testAFileTypeTheGatewayRefusesIsRefusedLocally() throws {
        let m = model(UploadGatewayFake())
        m.choose([try makeFile("main.swift", bytes: Data("let x = 1".utf8))])
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertNotNil(m.message)
    }

    // A file over the 10 MiB cap is refused from its size, before it is copied.
    func testAFileOverTheCapIsRefusedBeforeItIsCopied() throws {
        let m = model(UploadGatewayFake())
        let big = try makeFile("big.png", bytes: Data(count: GatewayUploadRules.maxBytes + 1))
        m.choose([big])
        XCTAssertTrue(m.items.isEmpty)
        XCTAssertEqual(m.message, "The file is larger than 10 MB.")
    }

    // D-117: archives and the non-macro Office formats are accepted by the phone's checks, as the gateway accepts them.
    func testArchivesAndOfficeFilesAreQueued() throws {
        let m = model(UploadGatewayFake())
        m.choose([
            try makeFile("bundle.zip", bytes: Data([0x50, 0x4b])),
            try makeFile("brief.docx", bytes: Data([0x50, 0x4b])),
        ])
        XCTAssertEqual(m.items.map(\.name), ["bundle.zip", "brief.docx"])
        XCTAssertNil(m.message)
    }

    func testAGoodFileIsQueuedAsWaiting() throws {
        let m = model(UploadGatewayFake())
        m.choose([try makeFile("photo.png", bytes: Data([0x89, 0x50, 0x4e, 0x47]))])
        XCTAssertEqual(states(m), [.waiting])
        XCTAssertEqual(m.items.first?.size, 4)
        XCTAssertNil(m.message)
    }

    // Two files with the same name cannot both wait: the second is refused before it is copied.
    func testAFileWithANameAlreadyInTheQueueIsRefused() throws {
        let m = model(UploadGatewayFake())
        m.choose([try makeFile("notes.txt", bytes: Data("a".utf8))])
        m.choose([try makeFile("notes.txt", bytes: Data("b".utf8))])
        XCTAssertEqual(m.items.count, 1)
        XCTAssertEqual(m.message, "notes.txt is already in the list.")
    }

    // MARK: - Sending a queue

    // Files are sent one after another, in the order they were picked, and each private copy is dropped once saved.
    func testSendStoresEveryFileInOrder() async throws {
        let fake = UploadGatewayFake()
        let m = model(fake)
        m.choose([
            try makeFile("a.txt", bytes: Data("a".utf8)),
            try makeFile("b.txt", bytes: Data("bb".utf8)),
        ])
        m.send()
        await waitUntil { m.items.allSatisfy { if case .saved = $0.state { return true } else { return false } } }

        XCTAssertEqual(fake.uploadedNames, ["a.txt", "b.txt"])
        XCTAssertEqual(states(m), [.saved(path: "a.txt", bytes: 1), .saved(path: "b.txt", bytes: 2)])
        XCTAssertTrue(m.items.allSatisfy { $0.staged == nil }, "saved files drop their private copies")
        XCTAssertFalse(m.isSending)
        XCTAssertEqual(fake.calls[0].params?["contentBase64"]?.stringValue, "YQ==")
    }

    // A refusal from the gateway marks that file and the queue goes on to the next one.
    func testARefusalMarksItsFileAndTheQueueGoesOn() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["a.txt"] = [GatewayError.rpc(code: -32602, message: "a file with this name already exists in the project; nothing was changed")]
        let m = model(fake)
        m.choose([
            try makeFile("a.txt", bytes: Data("a".utf8)),
            try makeFile("b.txt", bytes: Data("b".utf8)),
        ])
        m.send()
        await waitUntil { m.items.last.map { if case .saved = $0.state { return true } else { return false } } ?? false }

        XCTAssertEqual(fake.uploadedNames, ["a.txt", "b.txt"], "b is still sent after a is refused")
        XCTAssertEqual(
            states(m).first,
            .refused(text: "a file with this name already exists in the project; nothing was changed")
        )
        XCTAssertEqual(states(m).last, .saved(path: "b.txt", bytes: 1))
    }

    // A busy project is asked again, not skipped. The file is saved on the next try.
    func testABusyProjectIsRetriedUntilTheFileIsSaved() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["a.txt"] = [
            GatewayError.rpc(code: -32000, message: "another upload to this project is in progress"),
            GatewayError.rpc(code: -32000, message: "another upload to this project is in progress"),
        ]
        let m = model(fake)
        m.choose([try makeFile("a.txt", bytes: Data("a".utf8))])
        m.send()
        await waitUntil { if case .saved = m.items.first?.state { return true } else { return false } }

        XCTAssertEqual(fake.uploadedNames, ["a.txt", "a.txt", "a.txt"])
        XCTAssertEqual(states(m), [.saved(path: "a.txt", bytes: 1)])
    }

    // A project that stays busy past the attempt limit refuses the file, and the next file is still sent.
    func testABusyProjectPastTheLimitRefusesTheFile() async throws {
        let fake = UploadGatewayFake()
        let busy = GatewayError.rpc(code: -32000, message: "another upload to this project is in progress")
        fake.uploadErrors["a.txt"] = Array(repeating: busy, count: GatewayFileUploadModel.busyAttemptLimit)
        let m = model(fake)
        m.choose([
            try makeFile("a.txt", bytes: Data("a".utf8)),
            try makeFile("b.txt", bytes: Data("b".utf8)),
        ])
        m.send()
        await waitUntil { m.items.last.map { if case .saved = $0.state { return true } else { return false } } ?? false }

        XCTAssertEqual(fake.uploadedNames.filter { $0 == "a.txt" }.count, GatewayFileUploadModel.busyAttemptLimit)
        if case .refused = m.items.first?.state {} else { XCTFail("a must be refused after the busy limit") }
        XCTAssertEqual(states(m).last, .saved(path: "b.txt", bytes: 1))
    }

    // A lost answer is not a refusal: the outcome is unknown, and the queue stops. The next file waits.
    func testALostAnswerStopsTheQueueAndTheNextFileWaits() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["a.txt"] = [GatewayError.disconnected]
        let m = model(fake)
        m.choose([
            try makeFile("a.txt", bytes: Data("a".utf8)),
            try makeFile("b.txt", bytes: Data("b".utf8)),
        ])
        m.send()
        await waitUntil { if case .unknown = m.items.first?.state { return true } else { return false } }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(fake.uploadedNames, ["a.txt"], "b is not sent past an unknown outcome")
        XCTAssertEqual(states(m), [.unknown(text: "Could not confirm the upload. The file may be on the Mac."), .waiting])
        XCTAssertFalse(m.isSending)
    }

    func testACheckThatFindsTheSameFileSavesIt() async throws {
        let bytes = Data("hello".utf8)
        let fake = UploadGatewayFake()
        fake.uploadErrors["notes.txt"] = [GatewayError.disconnected]
        let m = model(fake)
        m.choose([try makeFile("notes.txt", bytes: bytes)])
        m.send()
        await waitUntil { if case .unknown = m.items.first?.state { return true } else { return false } }
        let id = try XCTUnwrap(m.items.first?.id)

        fake.results["_acpcode/files/stat"] = .object([
            "exists": .bool(true), "size": .int(bytes.count),
            "sha256": .string(GatewayFileUploadModel.sha256Hex(bytes)),
        ])
        await m.checkOutcome(id)
        XCTAssertEqual(states(m), [.saved(path: "notes.txt", bytes: bytes.count)])
    }

    func testACheckThatFindsNoFileMakesItWaitingAgain() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["notes.txt"] = [GatewayError.disconnected]
        let m = model(fake)
        m.choose([try makeFile("notes.txt", bytes: Data("hello".utf8))])
        m.send()
        await waitUntil { if case .unknown = m.items.first?.state { return true } else { return false } }
        let id = try XCTUnwrap(m.items.first?.id)

        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(false)])
        await m.checkOutcome(id)
        XCTAssertEqual(states(m), [.waiting])
    }

    func testACheckThatFindsADifferentFileRefusesTheSameName() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["notes.txt"] = [GatewayError.disconnected]
        let m = model(fake)
        m.choose([try makeFile("notes.txt", bytes: Data("hello".utf8))])
        m.send()
        await waitUntil { if case .unknown = m.items.first?.state { return true } else { return false } }
        let id = try XCTUnwrap(m.items.first?.id)

        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(true), "size": .int(3), "sha256": .string("other")])
        await m.checkOutcome(id)
        if case .refused = m.items.first?.state {} else { XCTFail("a different file with the name must be refused") }
    }

    // Cancel stops waiting, says the Mac may still save the file, and leaves the rest of the queue waiting.
    func testCancelWhileSendingStopsTheQueue() async throws {
        let fake = UploadGatewayFake()
        fake.delayNanoseconds = 2_000_000_000
        let m = model(fake)
        m.choose([
            try makeFile("a.txt", bytes: Data("a".utf8)),
            try makeFile("b.txt", bytes: Data("b".utf8)),
        ])
        m.send()
        await waitUntil { if case .sending = m.items.first?.state { return true } else { return false } }
        m.cancel()
        XCTAssertEqual(
            states(m),
            [.unknown(text: "The upload was cancelled. The Mac may still save it."), .waiting]
        )
        XCTAssertFalse(m.isSending)
    }

    // Without a connection nothing is sent.
    func testSendWithoutAConnectionSendsNothing() throws {
        let m = model(nil)
        m.choose([try makeFile("notes.txt", bytes: Data("hello".utf8))])
        m.send()
        XCTAssertEqual(states(m), [.waiting])
        XCTAssertEqual(m.message, "Not connected. Connect to the gateway and try again.")
    }

    // MARK: - Editing the queue

    func testRemoveDropsAWaitingFileAndItsCopy() throws {
        let m = model(UploadGatewayFake())
        m.choose([try makeFile("a.txt", bytes: Data("a".utf8))])
        let id = try XCTUnwrap(m.items.first?.id)
        m.remove(id)
        XCTAssertTrue(m.items.isEmpty)
    }

    func testARefusedFileCanBeSentAgain() async throws {
        let fake = UploadGatewayFake()
        fake.uploadErrors["a.txt"] = [GatewayError.rpc(code: -32602, message: "nope")]
        let m = model(fake)
        m.choose([try makeFile("a.txt", bytes: Data("a".utf8))])
        m.send()
        await waitUntil { if case .refused = m.items.first?.state { return true } else { return false } }
        let id = try XCTUnwrap(m.items.first?.id)

        m.retry(id)
        XCTAssertEqual(states(m), [.waiting])
    }

    func testDiscardAllDropsEveryPrivateCopy() throws {
        let m = model(UploadGatewayFake())
        m.choose([try makeFile("a.png", bytes: Data([1, 2, 3])), try makeFile("b.png", bytes: Data([4]))])
        XCTAssertEqual(m.items.count, 2)
        m.discardAll()
        XCTAssertTrue(m.items.isEmpty)
    }

    func testTheHashMatchesTheKnownVector() {
        XCTAssertEqual(
            GatewayFileUploadModel.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
