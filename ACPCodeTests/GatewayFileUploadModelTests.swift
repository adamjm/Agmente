import XCTest
import ACP
import ACPClient
@testable import ACPCode

/// A gateway that records calls, returns canned results, and can be slowed down or made to fail.
private final class UploadGatewayFake: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?
    var delayNanoseconds: UInt64 = 0

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error { throw error }
        return results[method] ?? .null
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
        return GatewayFileUploadModel(projectId: "p1", clientProvider: { client }, removeStaleOnInit: false)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // A folder is refused before anything is copied.
    func testAFolderIsRefusedWithNothingCopied() throws {
        let fake = UploadGatewayFake()
        let m = model(fake)
        m.choose(sourceDir)
        XCTAssertEqual(m.phase, .empty)
        XCTAssertEqual(m.message, "Choose a file, not a folder.")
        XCTAssertNil(m.pickedName)
    }

    // A name the gateway would refuse is refused here, before the file is read.
    func testAFileTypeTheGatewayRefusesIsRefusedLocally() throws {
        let m = model(UploadGatewayFake())
        m.choose(try makeFile("main.swift", bytes: Data("let x = 1".utf8)))
        XCTAssertEqual(m.phase, .empty)
        XCTAssertNotNil(m.message)
        XCTAssertNil(m.pickedName)
    }

    // A file over the cap is refused from its size, before it is copied or read into memory.
    func testAFileOverTheCapIsRefusedBeforeItIsCopied() throws {
        let m = model(UploadGatewayFake())
        let big = try makeFile("big.png", bytes: Data(count: GatewayUploadRules.maxBytes + 1))
        m.choose(big)
        XCTAssertEqual(m.phase, .empty)
        XCTAssertEqual(m.message, "The file is larger than 8 MB.")
        XCTAssertNil(m.pickedName)
    }

    func testAGoodFileIsStagedAndReadyToSend() throws {
        let m = model(UploadGatewayFake())
        m.choose(try makeFile("photo.png", bytes: Data([0x89, 0x50, 0x4e, 0x47])))
        XCTAssertEqual(m.phase, .picked(name: "photo.png", size: 4))
        XCTAssertEqual(m.pickedName, "photo.png")
        XCTAssertNil(m.message)
    }

    // Sending uploads the bytes and drops the private copy once the gateway has stored the file.
    func testSendStoresTheFileAndShowsItsPath() async throws {
        let fake = UploadGatewayFake()
        fake.results["_acpcode/files/upload"] = .object(["path": .string("photo.png"), "bytes": .int(4)])
        let m = model(fake)
        m.choose(try makeFile("photo.png", bytes: Data([0x89, 0x50, 0x4e, 0x47])))
        m.send()
        await waitUntil { if case .saved = m.phase { return true } else { return false } }
        XCTAssertEqual(m.phase, .saved(path: "photo.png", bytes: 4))
        XCTAssertNil(m.pickedName, "the private copy is dropped after a save")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].params?["contentBase64"]?.stringValue, "iVBORw==")
    }

    // A refusal from the gateway keeps the file selected, shows its text, and sends nothing again on its own.
    func testAGatewayRefusalKeepsTheFileAndDoesNotRetry() async throws {
        let fake = UploadGatewayFake()
        fake.error = GatewayError.rpc(code: -32602, message: "a file with this name already exists in the project; nothing was changed")
        let m = model(fake)
        m.choose(try makeFile("notes.txt", bytes: Data("x".utf8)))
        m.send()
        await waitUntil { m.message != nil }
        XCTAssertEqual(m.phase, .picked(name: "notes.txt", size: 1))
        XCTAssertEqual(m.message, "a file with this name already exists in the project; nothing was changed")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.calls.count, 1, "no automatic retry after a refusal")
    }

    // A lost answer is not a refusal: the outcome is unknown, and a check decides whether the file is there.
    func testALostAnswerIsUnknownAndACheckFindsTheSameFile() async throws {
        let bytes = Data("hello".utf8)
        let fake = UploadGatewayFake()
        fake.error = GatewayError.disconnected
        let m = model(fake)
        m.choose(try makeFile("notes.txt", bytes: bytes))
        m.send()
        await waitUntil { if case .unknownOutcome = m.phase { return true } else { return false } }
        XCTAssertEqual(m.phase, .unknownOutcome(name: "notes.txt"))
        XCTAssertEqual(m.message, "Could not confirm the upload. The file may be on the Mac.")

        fake.error = nil
        fake.results["_acpcode/files/stat"] = .object([
            "exists": .bool(true), "size": .int(bytes.count),
            "sha256": .string(GatewayFileUploadModel.sha256Hex(bytes)),
        ])
        await m.checkOutcome()
        XCTAssertEqual(m.phase, .saved(path: "notes.txt", bytes: bytes.count))
    }

    func testACheckThatFindsNoFileAllowsAnUpload() async throws {
        let fake = UploadGatewayFake()
        fake.error = GatewayError.disconnected
        let m = model(fake)
        m.choose(try makeFile("notes.txt", bytes: Data("hello".utf8)))
        m.send()
        await waitUntil { if case .unknownOutcome = m.phase { return true } else { return false } }

        fake.error = nil
        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(false)])
        await m.checkOutcome()
        XCTAssertEqual(m.phase, .picked(name: "notes.txt", size: 5))
        XCTAssertEqual(m.message, "The file is not on the Mac. You can upload it again.")
    }

    func testACheckThatFindsADifferentFileRefusesTheSameName() async throws {
        let fake = UploadGatewayFake()
        fake.error = GatewayError.disconnected
        let m = model(fake)
        m.choose(try makeFile("notes.txt", bytes: Data("hello".utf8)))
        m.send()
        await waitUntil { if case .unknownOutcome = m.phase { return true } else { return false } }

        fake.error = nil
        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(true), "size": .int(3), "sha256": .string("other")])
        await m.checkOutcome()
        XCTAssertEqual(m.phase, .picked(name: "notes.txt", size: 5))
        XCTAssertTrue(m.message?.hasPrefix("A different file with this name") == true)
    }

    // Cancel stops waiting, and says the Mac may still save the file.
    func testCancelWhileSendingSaysTheMacMayStillSave() async throws {
        let fake = UploadGatewayFake()
        fake.delayNanoseconds = 2_000_000_000
        fake.results["_acpcode/files/upload"] = .object(["path": .string("notes.txt"), "bytes": .int(5)])
        let m = model(fake)
        m.choose(try makeFile("notes.txt", bytes: Data("hello".utf8)))
        m.send()
        XCTAssertEqual(m.phase, .sending(name: "notes.txt"))
        m.cancel()
        XCTAssertEqual(m.phase, .unknownOutcome(name: "notes.txt"))
        XCTAssertEqual(m.message, "The upload was cancelled. The Mac may still save it.")
    }

    // Without a connection nothing is sent.
    func testSendWithoutAConnectionSendsNothing() throws {
        let m = model(nil)
        m.choose(try makeFile("notes.txt", bytes: Data("hello".utf8)))
        m.send()
        XCTAssertEqual(m.phase, .picked(name: "notes.txt", size: 5))
        XCTAssertEqual(m.message, "Not connected. Connect to the gateway and try again.")
    }

    func testDiscardDropsThePrivateCopy() throws {
        let m = model(UploadGatewayFake())
        m.choose(try makeFile("photo.png", bytes: Data([1, 2, 3])))
        XCTAssertEqual(m.pickedName, "photo.png")
        m.discard()
        XCTAssertNil(m.pickedName)
    }

    func testTheHashMatchesTheKnownVector() {
        XCTAssertEqual(
            GatewayFileUploadModel.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
