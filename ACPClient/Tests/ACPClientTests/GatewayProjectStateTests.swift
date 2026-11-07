import XCTest
import ACP
@testable import ACPClient

final class GatewayProjectStateTests: XCTestCase {
    private func params(_ extra: [String: ACP.Value]) -> ACP.Value {
        var object: [String: ACP.Value] = ["projectId": .string("p-site"), "agent": .string("running"), "since": .string("2026-11-08T09:14:02.250Z")]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    func testMethodNameIsTheContractName() {
        XCTAssertEqual(GatewayProjectState.method, "_agmente/project/state")
    }

    func testEachOfTheFourStatesDecodes() throws {
        let cases: [(String, GatewayAgentState)] = [("stopped", .stopped), ("starting", .starting), ("running", .running), ("stopping", .stopping)]
        for (wire, expected) in cases {
            let state = try XCTUnwrap(GatewayProjectState.parse(params(["agent": .string(wire)])), wire)
            XCTAssertEqual(state.projectId, "p-site")
            XCTAssertEqual(state.agent, expected, wire)
        }
    }

    func testSinceIsReadWithAndWithoutFractionalSeconds() throws {
        let fractional = try XCTUnwrap(GatewayProjectState.parse(params([:])).flatMap(\.since))
        let whole = try XCTUnwrap(GatewayProjectState.parse(params(["since": .string("2026-11-08T09:14:02Z")])).flatMap(\.since))
        XCTAssertEqual(fractional.timeIntervalSince(whole), 0.25, accuracy: 0.001, "the .250 milliseconds are kept")
    }

    func testAMalformedSinceKeepsTheStateAndDropsOnlyTheTime() throws {
        let state = try XCTUnwrap(GatewayProjectState.parse(params(["since": .string("yesterday")])))
        XCTAssertEqual(state.agent, .running)
        XCTAssertNil(state.since)
    }

    func testAnUnknownStateDecodesToUnknown() throws {
        let state = try XCTUnwrap(GatewayProjectState.parse(params(["agent": .string("paused")])))
        XCTAssertEqual(state.agent, .unknown)
    }

    func testAMissingOrNonTextStateDecodesToUnknown() throws {
        XCTAssertEqual(try XCTUnwrap(GatewayProjectState.parse(params(["agent": .null]))).agent, .unknown)
        XCTAssertEqual(try XCTUnwrap(GatewayProjectState.parse(params(["agent": .number(3)]))).agent, .unknown)
        var object = params([:]).objectValue ?? [:]
        object.removeValue(forKey: "agent")
        XCTAssertEqual(try XCTUnwrap(GatewayProjectState.parse(.object(object))).agent, .unknown)
    }

    func testNoProjectIdOrEmptyProjectIdIsNotAState() {
        XCTAssertNil(GatewayProjectState.parse(nil))
        XCTAssertNil(GatewayProjectState.parse(.string("running")))
        XCTAssertNil(GatewayProjectState.parse(params(["projectId": .string("")])))
        XCTAssertNil(GatewayProjectState.parse(params(["projectId": .number(7)])))
    }
}
