import Foundation
import XCTest
@testable import ACPCode

/// PLAN 6B.3: the skills model. A save sends one request only after the Face ID gate returns true,
/// and an invalid name or an oversize content sends nothing and does not prompt.
@MainActor
final class ForkSkillsTests: XCTestCase {

    /// Records every call. Thread-safe because the protocol is async and Sendable.
    final class FakeSkillsClient: SkillsClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        var stored: [SkillSummary] = []

        var requests: [String] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        private func record(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(line)
        }

        func list() async throws -> [SkillSummary] {
            record("list")
            return stored
        }

        func put(name: String, content: String) async throws {
            record("put:\(name)")
            stored.removeAll { $0.name == name }
            stored.append(SkillSummary(name: name, bytes: content.utf8.count))
        }

        func delete(name: String) async throws {
            record("delete:\(name)")
            stored.removeAll { $0.name == name }
        }
    }

    final class FakeGate: SkillSaveGate, @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = []
        var answer: Bool

        init(answer: Bool) { self.answer = answer }

        var asked: [String] {
            lock.lock(); defer { lock.unlock() }
            return _asked
        }

        func confirmSave(skillName: String) async -> Bool {
            lock.lock()
            _asked.append(skillName)
            let result = answer
            lock.unlock()
            return result
        }
    }

    private func makeModel(gateAnswer: Bool) -> (SkillsModel, FakeSkillsClient, FakeGate) {
        let client = FakeSkillsClient()
        let gate = FakeGate(answer: gateAnswer)
        return (SkillsModel(client: client, gate: gate), client, gate)
    }

    private let body = "# Notes\nUse the project's lint command.\n"

    // MARK: The gate

    func testGateReturningFalseSendsNoRequest() async {
        let (model, client, gate) = makeModel(gateAnswer: false)
        let outcome = await model.save(name: "lint-notes", content: body)
        XCTAssertEqual(outcome, .notConfirmed)
        XCTAssertEqual(gate.asked, ["lint-notes"])
        XCTAssertEqual(client.requests, [])
        XCTAssertEqual(model.skills, [])
    }

    func testGateReturningTrueSendsExactlyOneRequest() async {
        let (model, client, gate) = makeModel(gateAnswer: true)
        let outcome = await model.save(name: "lint-notes", content: body)
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(gate.asked, ["lint-notes"])
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("put:") }, ["put:lint-notes"])
        XCTAssertEqual(model.skills.map(\.name), ["lint-notes"])
    }

    func testEverySaveAsksTheGateAgain() async {
        let (model, client, gate) = makeModel(gateAnswer: true)
        _ = await model.save(name: "one", content: body)
        gate.answer = false
        _ = await model.save(name: "two", content: body)
        XCTAssertEqual(gate.asked, ["one", "two"])
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("put:") }, ["put:one"])
    }

    func testDeleteIsNotGated() async {
        let (model, client, gate) = makeModel(gateAnswer: false)
        client.stored = [SkillSummary(name: "old", bytes: 3)]
        await model.delete(name: "old")
        XCTAssertEqual(gate.asked, [])
        XCTAssertEqual(client.requests.last, "list")
        XCTAssertTrue(client.requests.contains("delete:old"))
    }

    // MARK: Invalid input never reaches the gate or the gateway

    func testInvalidNamesSendNoRequestAndDoNotPrompt() async {
        let bad = [
            "Bad Name",
            "../x",
            String(repeating: "a", count: 65),
            "-leading",
            "trailing-",
            "double--hyphen",
            "UpperCase",
            "under_score",
            "",
        ]
        for name in bad {
            let (model, client, gate) = makeModel(gateAnswer: true)
            let outcome = await model.save(name: name, content: body)
            XCTAssertEqual(outcome, .invalidName, "name \(name)")
            XCTAssertEqual(gate.asked, [], "no prompt for \(name)")
            XCTAssertEqual(client.requests, [], "no request for \(name)")
        }
    }

    func testValidNameLimitIsSixtyFourCharacters() {
        XCTAssertTrue(SkillRules.isValidName(String(repeating: "a", count: 64)))
        XCTAssertFalse(SkillRules.isValidName(String(repeating: "a", count: 65)))
        XCTAssertTrue(SkillRules.isValidName("a1-b2-c3"))
        XCTAssertTrue(SkillRules.isValidName("0"))
    }

    func testOversizeContentSendsNoRequestAndDoesNotPrompt() async {
        let (model, client, gate) = makeModel(gateAnswer: true)
        let outcome = await model.save(name: "big", content: String(repeating: "x", count: 64 * 1024 + 1))
        XCTAssertEqual(outcome, .contentTooLarge)
        XCTAssertEqual(gate.asked, [])
        XCTAssertEqual(client.requests, [])
    }

    func testContentAtTheCapIsAccepted() async {
        let (model, client, _) = makeModel(gateAnswer: true)
        let outcome = await model.save(name: "exact", content: String(repeating: "x", count: 64 * 1024))
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(client.requests.filter { $0.hasPrefix("put:") }, ["put:exact"])
    }

    func testSizeIsCountedInBytesNotCharacters() {
        // Three bytes per character: 22,000 characters is 66,000 bytes, over the cap.
        XCTAssertFalse(SkillRules.isValidContent(String(repeating: "\u{20AC}", count: 22_000)))
        XCTAssertTrue(SkillRules.isValidContent(String(repeating: "\u{20AC}", count: 21_000)))
    }

    // MARK: List and refresh

    func testRefreshListsSortedByName() async {
        let (model, client, _) = makeModel(gateAnswer: true)
        client.stored = [SkillSummary(name: "zeta", bytes: 1), SkillSummary(name: "alpha", bytes: 2)]
        await model.refresh()
        XCTAssertEqual(model.skills.map(\.name), ["alpha", "zeta"])
        XCTAssertNil(model.message)
    }
}
