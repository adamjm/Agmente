import XCTest
import ACP
@testable import ACPClient

private final class UploadFakeGateway: GatewayCalling, @unchecked Sendable {
    var calls: [(method: String, params: ACP.Value?)] = []
    var results: [String: ACP.Value] = [:]
    var error: Error?

    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append((method, params))
        if let error { throw error }
        return results[method] ?? .null
    }
}

final class GatewayFilesTests: XCTestCase {
    // The phone refuses a name the gateway would refuse for its shape, before it sends it.
    func testNameRulesRefuseWhatTheGatewayRefuses() {
        XCTAssertNil(GatewayUploadRules.nameProblem("photo.png"))
        XCTAssertNil(GatewayUploadRules.nameProblem("a b_c-1.TXT"))
        XCTAssertNil(GatewayUploadRules.nameProblem(String(repeating: "a", count: 60) + ".png"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem(String(repeating: "a", count: 61) + ".png"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem(".env"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem("a/b.png"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem("Résumé.pdf"), "ASCII only (D-091)")
        XCTAssertNotNil(GatewayUploadRules.nameProblem("main.swift"), "not an allowed type")
        XCTAssertNotNil(GatewayUploadRules.nameProblem("noext"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem("AGENTS.md"), "reserved, any case")
        XCTAssertNotNil(GatewayUploadRules.nameProblem("claude.md"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem("opencode.json"))
        XCTAssertNotNil(GatewayUploadRules.nameProblem("trailing. "))
    }

    // 8 MiB is the cap: the encoded length of exactly that many bytes is the cap, so a larger file is refused.
    func testTheEncodedCapIsTheEncodingOfTheRawCap() {
        XCTAssertEqual(GatewayUploadRules.maxEncodedLength, 11_184_812)
        XCTAssertEqual(Data(count: GatewayUploadRules.maxBytes).base64EncodedString().utf8.count, GatewayUploadRules.maxEncodedLength)
    }

    func testAFileOverTheCapIsRefusedBeforeAnythingIsSent() async {
        let fake = UploadFakeGateway()
        let client = GatewayClient(fake)
        let big = Data(count: GatewayUploadRules.maxBytes + 1)
        do {
            _ = try await client.uploadFile(projectId: "p1", path: "big.png", data: big)
            XCTFail("an oversize file was sent")
        } catch GatewayError.rpc(let code, let message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "The file is larger than 8 MB.")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertTrue(fake.calls.isEmpty, "nothing was sent for an oversize file")
    }

    func testUploadSendsTheBase64ContentAndDecodesThePathAndSize() async throws {
        let fake = UploadFakeGateway()
        fake.results["_acpcode/files/upload"] = .object(["path": .string("photo.png"), "bytes": .int(4)])
        let client = GatewayClient(fake)
        let result = try await client.uploadFile(projectId: "p1", path: "photo.png", data: Data([0x89, 0x50, 0x4e, 0x47]))
        XCTAssertEqual(result, GatewayUploadResult(path: "photo.png", bytes: 4))
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].method, "_acpcode/files/upload")
        let params = fake.calls[0].params
        XCTAssertEqual(params?["projectId"]?.stringValue, "p1")
        XCTAssertEqual(params?["path"]?.stringValue, "photo.png")
        XCTAssertEqual(params?["contentBase64"]?.stringValue, "iVBORw==")
    }

    func testAGatewayRefusalKeepsItsOwnText() async {
        let fake = UploadFakeGateway()
        fake.error = ACPServiceError.rpc(id: .number(1), error: .serverError(code: -32602, message: "a file with this name already exists in the project; nothing was changed"))
        let client = GatewayClient(fake)
        do {
            _ = try await client.uploadFile(projectId: "p1", path: "notes.txt", data: Data("x".utf8))
            XCTFail("expected a refusal")
        } catch let error as GatewayError {
            XCTAssertEqual(error.message, "a file with this name already exists in the project; nothing was changed")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStatDecodesAPresentFileAndAnAbsentOne() async throws {
        let fake = UploadFakeGateway()
        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(true), "size": .int(4), "sha256": .string("abc")])
        let client = GatewayClient(fake)
        let present = try await client.statFile(projectId: "p1", path: "photo.png")
        XCTAssertEqual(present, GatewayFileStat(exists: true, size: 4, sha256: "abc"))

        fake.results["_acpcode/files/stat"] = .object(["exists": .bool(false)])
        let absent = try await client.statFile(projectId: "p1", path: "photo.png")
        XCTAssertEqual(absent, GatewayFileStat(exists: false, size: nil, sha256: nil))
    }

    func testStatWithoutAnExistsFieldIsAnInvalidResponse() async {
        let fake = UploadFakeGateway()
        fake.results["_acpcode/files/stat"] = .object([:])
        let client = GatewayClient(fake)
        do {
            _ = try await client.statFile(projectId: "p1", path: "x.txt")
            XCTFail("expected invalid response")
        } catch GatewayError.invalidResponse(let what) {
            XCTAssertEqual(what, "stat")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
