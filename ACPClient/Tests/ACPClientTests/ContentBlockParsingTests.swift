import XCTest
import ACP
@testable import ACPClient

final class ContentBlockParsingTests: XCTestCase {
    private let handler = ACPSessionUpdateHandler()

    private func update(_ kind: String, content: ACP.Value, extra: [String: ACP.Value] = [:]) -> ACP.Value {
        var update: [String: ACP.Value] = ["sessionUpdate": .string(kind), "content": content]
        for (key, value) in extra { update[key] = value }
        return .object(["sessionId": .string("s1"), "update": .object(update)])
    }

    func testImageBlock() {
        let content: ACP.Value = .object([
            "type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/png"),
        ])
        let events = handler.handle(params: update("agent_message_chunk", content: content))
        XCTAssertEqual(events, [.media(.image(mimeType: "image/png", data: "AAAA", uri: nil))])
    }

    func testImageBlockWithoutDataIsIgnored() {
        let content: ACP.Value = .object(["type": .string("image"), "mimeType": .string("image/png")])
        XCTAssertEqual(handler.handle(params: update("agent_message_chunk", content: content)), [])
    }

    func testResourceBlobAndText() {
        let blob: ACP.Value = .object([
            "type": .string("resource"),
            "resource": .object(["uri": .string("file:///a.png"), "mimeType": .string("image/png"), "blob": .string("QUJD")]),
        ])
        XCTAssertEqual(
            handler.handle(params: update("agent_message_chunk", content: blob)),
            [.media(.resource(uri: "file:///a.png", mimeType: "image/png", blob: "QUJD", text: nil))]
        )
        let text: ACP.Value = .object([
            "type": .string("resource"),
            "resource": .object(["uri": .string("file:///a.txt"), "text": .string("hi")]),
        ])
        XCTAssertEqual(
            handler.handle(params: update("agent_message_chunk", content: text)),
            [.media(.resource(uri: "file:///a.txt", mimeType: nil, blob: nil, text: "hi"))]
        )
    }

    func testResourceLink() {
        let content: ACP.Value = .object([
            "type": .string("resource_link"), "uri": .string("https://example.com/x.png"),
            "name": .string("x.png"), "mimeType": .string("image/png"), "size": .int(1234),
        ])
        XCTAssertEqual(
            handler.handle(params: update("agent_message_chunk", content: content)),
            [.media(.resourceLink(uri: "https://example.com/x.png", name: "x.png", title: nil, mimeType: "image/png", size: 1234))]
        )
        let empty: ACP.Value = .object(["type": .string("resource_link"), "uri": .string("")])
        XCTAssertEqual(handler.handle(params: update("agent_message_chunk", content: empty)), [])
    }

    func testTextBlockStaysTextOnly() {
        let content: ACP.Value = .object(["type": .string("text"), "text": .string("hello")])
        XCTAssertEqual(handler.handle(params: update("agent_message_chunk", content: content)), [.agentMessage(text: "hello")])
    }

    func testToolCallUpdateContentWrapperYieldsMediaAfterUpdate() {
        let content: ACP.Value = .array([
            .object(["type": .string("content"), "content": .object([
                "type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/jpeg"),
            ])]),
            .object(["type": .string("diff"), "path": .string("a")]),
        ])
        let events = handler.handle(params: update(
            "tool_call_update", content: content,
            extra: ["toolCallId": .string("t1"), "status": .string("completed")]
        ))
        XCTAssertEqual(events.count, 2)
        guard case .toolCallUpdate = events[0] else { return XCTFail("expected tool call update first") }
        XCTAssertEqual(events[1], .media(.image(mimeType: "image/jpeg", data: "AAAA", uri: nil)))
    }

    func testDeeplyNestedAndHugeArraysAreBounded() {
        var nested: ACP.Value = .object(["type": .string("image"), "data": .string("AA"), "mimeType": .string("image/png")])
        for _ in 0..<50 { nested = .object(["type": .string("content"), "content": nested]) }
        XCTAssertEqual(ACPSessionUpdateParser.mediaBlocks(from: ["content": nested]), [])

        let one: ACP.Value = .object(["type": .string("image"), "data": .string("AA"), "mimeType": .string("image/png")])
        let many = ACP.Value.array(Array(repeating: one, count: 500))
        XCTAssertEqual(ACPSessionUpdateParser.mediaBlocks(from: ["content": many]).count, 64)
    }
}
