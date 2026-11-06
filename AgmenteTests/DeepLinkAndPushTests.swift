import XCTest
import ACP
import ACPClient
@testable import Agmente

final class DeepLinkTests: XCTestCase {
    private let server = UUID(uuidString: "2F0C6E4A-1B7D-4C8E-9A55-0123456789AB")!

    func testAValidLinkNamesAServerAndASession() {
        let url = URL(string: "agmente://session/\(server.uuidString)/sess-7f3af01c45066fe9")!
        XCTAssertEqual(DeepLink.parse(url), .session(serverId: server, sessionId: "sess-7f3af01c45066fe9"))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        let url = URL(string: "AGMENTE://Session/\(server.uuidString.lowercased())/abc")!
        XCTAssertEqual(DeepLink.parse(url), .session(serverId: server, sessionId: "abc"))
    }

    func testALinkSurvivesTheRoundTripEvenWithAwkwardSessionIds() {
        for id in ["sess-1", "with space", "a+b=c&d", "ünï-çødé", "%41", "emoji-🚀", "dots..and--dashes", String(repeating: "x", count: 200)] {
            let link = DeepLink.session(serverId: server, sessionId: id)
            XCTAssertEqual(DeepLink.parse(link.url), link, id)
        }
    }

    func testAnythingElseIsRefused() {
        let id = server.uuidString
        let refused = [
            "https://session/\(id)/abc",                  // wrong scheme
            "agmente://sessions/\(id)/abc",               // wrong host
            "agmente://session/\(id)",                    // no session
            "agmente://session/\(id)/",                   // empty session
            "agmente://session/\(id)/a/b",                // extra part
            "agmente://session/not-a-uuid/abc",           // bad server id
            "agmente://session//abc",                     // no server id
            "agmente://\(id)/abc",                        // no host
            "agmente:session/\(id)/abc",                  // no authority
            "agmente://evil.example/session/\(id)/abc",   // another host
            "agmente://session/\(id)/%2F",                // an encoded slash in the id
            "agmente://session/\(id)/%00",                // a control character
            "agmente://session/\(id)/\(String(repeating: "x", count: 201))", // too long
            "agmente://user@session/\(id)/abc",           // userinfo
            "agmente://session:8080/\(id)/abc",           // a port
        ]
        for text in refused {
            guard let url = URL(string: text) else { continue }
            XCTAssertNil(DeepLink.parse(url), text)
        }
    }

    func testAQueryOrFragmentChangesNothing() {
        let url = URL(string: "agmente://session/\(server.uuidString)/abc?action=approve&answer=allow#send")!
        XCTAssertEqual(DeepLink.parse(url), .session(serverId: server, sessionId: "abc"), "extra parts are ignored, never acted on")
    }

    func testAPushPayloadGivesTheSessionOnTheCallersServer() {
        let payload: [AnyHashable: Any] = ["aps": ["alert": ["title": "Site", "body": "Turn finished"]], "sessionId": "sess-9", "event": "turn_ended"]
        XCTAssertEqual(DeepLink.fromPush(userInfo: payload, serverId: server), .session(serverId: server, sessionId: "sess-9"))
        XCTAssertNil(DeepLink.fromPush(userInfo: ["event": "turn_ended"], serverId: server))
        XCTAssertNil(DeepLink.fromPush(userInfo: ["sessionId": 7], serverId: server))
        XCTAssertNil(DeepLink.fromPush(userInfo: ["sessionId": "a/b"], serverId: server))
        XCTAssertNil(DeepLink.fromPush(userInfo: ["sessionId": ""], serverId: server))
    }
}

@MainActor
final class DeepLinkRoutingTests: XCTestCase {
    private var model: AppViewModel!

    override func setUp() {
        super.setUp()
        model = AppViewModel(storage: .inMemory(), defaults: UserDefaults(suiteName: "DeepLinkRoutingTests.\(UUID().uuidString)")!,
                             shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        model.addServer(name: "First", scheme: "ws", host: "localhost:9001", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
        model.addServer(name: "Second", scheme: "ws", host: "localhost:9002", token: "", cfAccessClientId: "", cfAccessClientSecret: "", workingDirectory: "/tmp")
    }

    func testALinkSelectsItsServerAndNamesTheSession() throws {
        let first = try XCTUnwrap(model.servers.first { $0.name == "First" })
        let second = try XCTUnwrap(model.servers.first { $0.name == "Second" })
        XCTAssertEqual(model.selectedServerId, second.id, "the last server added is selected")
        let outcome = model.resolveDeepLink(DeepLink.session(serverId: first.id, sessionId: "sess-1").url)
        XCTAssertEqual(outcome, .open(sessionId: "sess-1"))
        XCTAssertEqual(model.selectedServerId, first.id)
    }

    func testALinkToTheSelectedServerDoesNotReselectIt() throws {
        let selected = try XCTUnwrap(model.selectedServerId)
        XCTAssertEqual(model.resolveDeepLink(DeepLink.session(serverId: selected, sessionId: "s").url), .open(sessionId: "s"))
        XCTAssertEqual(model.selectedServerId, selected)
    }

    func testALinkToAServerThisDeviceDoesNotHaveChangesNothing() throws {
        let before = model.selectedServerId
        let outcome = model.resolveDeepLink(DeepLink.session(serverId: UUID(), sessionId: "s").url)
        XCTAssertEqual(outcome, .unknownServer)
        XCTAssertEqual(model.selectedServerId, before)
    }

    func testAnInvalidLinkChangesNothing() throws {
        let before = model.selectedServerId
        XCTAssertEqual(model.resolveDeepLink(URL(string: "agmente://session/nope")!), .invalid)
        XCTAssertEqual(model.resolveDeepLink(URL(string: "https://example.com")!), .invalid)
        XCTAssertEqual(model.selectedServerId, before)
    }
}

private final class FakeCenter: NotificationAuthorizing {
    var status: PushAuthorization = .notDetermined
    var grant = true
    var error: Error?
    private(set) var requests = 0

    func authorizationStatus() async -> PushAuthorization { status }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        if let error { throw error }
        status = grant ? .authorized : .denied
        return grant
    }
}

private final class FakeRegistrar: RemoteNotificationRegistrar {
    private(set) var registrations = 0
    @MainActor func registerForRemoteNotifications() { registrations += 1 }
}

@MainActor
final class PushRegistrationTests: XCTestCase {
    func testNothingIsAskedOrRegisteredUntilThePersonChooses() async {
        let center = FakeCenter(), registrar = FakeRegistrar()
        let push = PushRegistration(center: center, registrar: registrar)
        await push.refreshStatus()
        XCTAssertEqual(push.authorization, .notDetermined)
        XCTAssertEqual(center.requests, 0, "refreshing the status never asks")
        XCTAssertEqual(registrar.registrations, 0)
    }

    func testAllowingAsksOnceAndThenRegisters() async {
        let center = FakeCenter(), registrar = FakeRegistrar()
        let push = PushRegistration(center: center, registrar: registrar)
        await push.enable()
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(push.authorization, .authorized)
        XCTAssertTrue(push.isAllowed)
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertNil(push.failure)
    }

    func testRefusingDoesNotRegister() async {
        let center = FakeCenter(), registrar = FakeRegistrar()
        center.grant = false
        let push = PushRegistration(center: center, registrar: registrar)
        await push.enable()
        XCTAssertEqual(push.authorization, .denied)
        XCTAssertFalse(push.isAllowed)
        XCTAssertEqual(registrar.registrations, 0)
    }

    func testAnErrorFromTheSystemIsShown() async {
        let center = FakeCenter(), registrar = FakeRegistrar()
        center.error = NSError(domain: "UNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed"])
        let push = PushRegistration(center: center, registrar: registrar)
        await push.enable()
        XCTAssertEqual(push.failure, "Could not ask for permission: Notifications are not allowed")
        XCTAssertEqual(registrar.registrations, 0)
    }

    func testAnAllowedDeviceRegistersAgainEachLaunchBecauseTheTokenCanChange() async {
        let center = FakeCenter(), registrar = FakeRegistrar()
        center.status = .authorized
        let push = PushRegistration(center: center, registrar: registrar)
        await push.refreshStatus()
        XCTAssertEqual(registrar.registrations, 1)
        XCTAssertEqual(center.requests, 0)
    }

    func testTheTokenIsKeptAsHexAndAFailureClearsIt() {
        let push = PushRegistration(center: FakeCenter(), registrar: FakeRegistrar())
        push.didRegister(deviceToken: Data([0x00, 0x0a, 0xff, 0x10]))
        XCTAssertEqual(push.deviceToken, "000aff10")
        push.didFailToRegister(NSError(domain: "NSCocoaErrorDomain", code: 3000, userInfo: [NSLocalizedDescriptionKey: "no valid “aps-environment” entitlement string found for application"]))
        XCTAssertNil(push.deviceToken)
        XCTAssertEqual(push.failure, "Registration failed: no valid “aps-environment” entitlement string found for application")
        push.didRegister(deviceToken: Data([1]))
        XCTAssertNil(push.failure, "a later success clears the failure")
    }
}

private final class PushFakeCaller: GatewayCalling, @unchecked Sendable {
    var calls: [String] = []
    var params: ACP.Value?
    var error: Error?
    func gatewayCall(method: String, params: ACP.Value?) async throws -> ACP.Value {
        calls.append(method)
        self.params = params
        if let error { throw error }
        return .object([:])
    }
}

final class PushGatewaySyncTests: XCTestCase {
    private let withPush = GatewayInfo(version: "1", extensions: ["projects", "push"])
    private let withoutPush = GatewayInfo(version: "1", extensions: ["projects"])

    func testSendsTheTokenToAGatewayThatOffersPush() async {
        let fake = PushFakeCaller()
        let outcome = await PushGatewaySync.sync(token: "ab12", allowed: true, info: withPush, client: GatewayClient(fake), environment: .sandbox)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(fake.calls, ["_agmente/push/register"])
        XCTAssertEqual(fake.params, .object(["deviceToken": .string("ab12"), "environment": .string("sandbox")]))
    }

    func testSendsNothingWhenAnyConditionFails() async {
        let cases: [(String?, Bool, GatewayInfo?, PushGatewaySync.Outcome)] = [
            (nil, true, withPush, .skippedNoToken),
            ("", true, withPush, .skippedNoToken),
            ("ab12", false, withPush, .skippedNotAllowed),
            ("ab12", true, withoutPush, .skippedNoPush),
            ("ab12", true, nil, .skippedNoPush),
        ]
        for (token, allowed, info, expected) in cases {
            let fake = PushFakeCaller()
            let outcome = await PushGatewaySync.sync(token: token, allowed: allowed, info: info, client: GatewayClient(fake))
            XCTAssertEqual(outcome, expected)
            XCTAssertTrue(fake.calls.isEmpty, "no call for \(expected)")
        }
    }

    func testAGatewayRefusalIsReportedWithoutTheToken() async {
        let fake = PushFakeCaller()
        fake.error = GatewayError.rpc(code: -32602, message: "deviceToken must be 64 to 200 hex digits")
        let outcome = await PushGatewaySync.sync(token: "secret-token-value", allowed: true, info: withPush, client: GatewayClient(fake))
        XCTAssertEqual(outcome, .failed("deviceToken must be 64 to 200 hex digits"))
        if case .failed(let message) = outcome { XCTAssertFalse(message.contains("secret-token-value")) }
    }
}
