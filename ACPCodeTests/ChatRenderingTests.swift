import Foundation
import Testing
@testable import ACPCode

struct ChatRenderingTests {

    @Test func entryMapperGeneratesExpectedKinds() {
        let user = ChatMessage(role: .user, content: "hello", isStreaming: false)

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            segments: [
                AssistantSegment(kind: .message, text: "answer"),
                AssistantSegment(kind: .thought, text: "thinking"),
            ]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [user, assistant])

        #expect(entries.contains(where: { $0.kind == .userText }))
        #expect(entries.contains(where: { $0.kind == .assistantMarkdown }))
        #expect(entries.contains(where: { $0.kind == .assistantThought }))
        #expect(entries.contains(where: { $0.kind == .streamingIndicator }))
    }

    @Test func entryMapperExtractsFileChangeSummary() {
        let toolCall = ToolCallDisplay(
            toolCallId: "tc1",
            title: "Edit: Sources/File.swift",
            kind: "edit",
            status: "completed",
            output: "@@ -1 +1 @@\n-old\n+new"
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [AssistantSegment(kind: .toolCall, text: toolCall.title, toolCall: toolCall)]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [assistant])

        #expect(entries.contains(where: { $0.kind == .fileChanges }))
    }

    @Test func renderDiffDetectsInsertUpdateRemove() {
        let oldEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a"),
            .system(messageId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, text: "b", isError: false),
        ]
        let newEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a updated"),
            .assistantMarkdown(
                messageId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                segmentId: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                text: "new"
            ),
        ]

        let diff = ChatRenderDiff.make(old: oldEntries, new: newEntries)

        #expect(diff.updated.count == 1)
        #expect(diff.inserted.count == 1)
        #expect(diff.removed.count == 1)
    }

    @Test func scrollAnimationPolicy_NoAnimationBeforeFirstRender() {
        let oldMessages: [ChatMessage] = []
        let newMessages = [makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "hello")]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: false
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_NoAnimationForHistoryHydration() {
        let oldMessages: [ChatMessage] = []
        let newMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_AnimatesForTailAppend() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
        ]
        let newMessages = oldMessages + [
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == true)
    }

    @Test func scrollAnimationPolicy_NoAnimationWhenInsertedBeyondThreshold() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
        ]
        let newMessages = oldMessages + [
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
            makeMessage(id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", content: "4"),
            makeMessage(id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", content: "5"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_AnimatesForStreamingUpdate() {
        let oldLast = makeMessage(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            content: "partial",
            isStreaming: true
        )
        var newLast = oldLast
        newLast.content = "partial plus more"

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: [oldLast],
            to: [newLast],
            hasRendered: true
        )

        #expect(result == true)
    }

    @Test func scrollAnimationPolicy_NoAnimationForSessionSwitchWithReorder() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]
        let newMessages = [
            makeMessage(id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", content: "new session"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    private func makeMessage(
        id: String,
        content: String,
        isStreaming: Bool = false
    ) -> ChatMessage {
        let stored = StoredMessageInfo(
            messageId: UUID(uuidString: id)!,
            role: ChatMessage.Role.assistant.rawValue,
            content: content,
            createdAt: Date(timeIntervalSince1970: 0),
            segmentsData: nil
        )
        var message = ChatMessage(from: stored)
        message.isStreaming = isStreaming
        return message
    }
}
