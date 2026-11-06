import Foundation

struct ChatEntryMapper {
    func entries(from messages: [ChatMessage]) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        entries.reserveCapacity(messages.count * 2)

        for message in messages {
            switch message.role {
            case .user:
                mapUserMessage(message, into: &entries)
            case .assistant:
                mapAssistantMessage(message, into: &entries)
            case .system:
                mapSystemMessage(message, into: &entries)
            }
        }

        return entries
    }

    private func mapUserMessage(_ message: ChatMessage, into entries: inout [ChatEntry]) {
        if !message.images.isEmpty {
            entries.append(.userImages(messageId: message.id, images: message.images))
        }

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            entries.append(.userText(messageId: message.id, text: text))
        }
    }

    private func mapAssistantMessage(_ message: ChatMessage, into entries: inout [ChatEntry]) {
        let segments = resolvedSegments(for: message)
        let fileChangeSegments = segments.filter { FileChangeSummary.isFileChangeSegment($0) }
        let contentSegments = segments.filter { !FileChangeSummary.isFileChangeSegment($0) }

        var hasVisibleContent = false

        for segment in contentSegments {
            switch segment.kind {
            case .message:
                if let media = segment.media {
                    entries.append(.media(messageId: message.id, segmentId: segment.id, item: media))
                    hasVisibleContent = true
                    continue
                }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entries.append(.assistantMarkdown(messageId: message.id, segmentId: segment.id, text: text))
                hasVisibleContent = true
            case .thought:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entries.append(.assistantThought(messageId: message.id, segmentId: segment.id, text: text, isStreaming: message.isStreaming))
                hasVisibleContent = true
            case .plan:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entries.append(.assistantPlan(messageId: message.id, segmentId: segment.id, text: text, isStreaming: message.isStreaming))
                hasVisibleContent = true
            case .toolCall:
                entries.append(.toolCall(messageId: message.id, segment: segment, isStreaming: message.isStreaming))
                hasVisibleContent = true
            }
        }

        let fileChangeItems = FileChangeSummary.items(from: fileChangeSegments)
        if !fileChangeItems.isEmpty {
            entries.append(.fileChanges(messageId: message.id, items: fileChangeItems))
            hasVisibleContent = true
        }

        if message.isStreaming {
            entries.append(.streamingIndicator(messageId: message.id, suffix: hasVisibleContent ? "tail" : "solo"))
        }
    }

    private func mapSystemMessage(_ message: ChatMessage, into entries: inout [ChatEntry]) {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(.system(messageId: message.id, text: text, isError: message.isError))
    }

    private func resolvedSegments(for message: ChatMessage) -> [AssistantSegment] {
        if !message.segments.isEmpty {
            return message.segments
        }

        let parsed = parseAssistantContent(message.content)
        return parsed.compactMap { segment in
            if segment.isToolCall {
                let parsed = parseToolCallDisplay(from: segment.text)
                return AssistantSegment(kind: .toolCall, text: parsed.title, toolCall: parsed)
            }

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AssistantSegment(kind: .message, text: text)
        }
    }

    private struct ContentSegment {
        let text: String
        let isToolCall: Bool
    }

    private func parseAssistantContent(_ content: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var currentText = ""

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Tool call:") {
                if !currentText.isEmpty {
                    segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
                    currentText = ""
                }
                segments.append(ContentSegment(text: line, isToolCall: true))
            } else {
                if !currentText.isEmpty {
                    currentText += "\n"
                }
                currentText += line
            }
        }

        if !currentText.isEmpty {
            segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
        }

        return segments
    }

    private func parseToolCallDisplay(from text: String) -> ToolCallDisplay {
        var displayContent = text
        if displayContent.hasPrefix("Tool call: ") {
            displayContent = String(displayContent.dropFirst("Tool call: ".count))
        }

        var toolKind: String? = nil
        if displayContent.hasPrefix("["), let endBracket = displayContent.firstIndex(of: "]") {
            toolKind = String(displayContent[displayContent.index(after: displayContent.startIndex)..<endBracket])
            displayContent = String(displayContent[displayContent.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
        }

        var status: String? = nil
        if let statusStart = displayContent.lastIndex(of: "("),
           let statusEnd = displayContent.lastIndex(of: ")"),
           statusStart < statusEnd {
            status = String(displayContent[displayContent.index(after: statusStart)..<statusEnd])
            displayContent = String(displayContent[..<statusStart]).trimmingCharacters(in: .whitespaces)
        }

        return ToolCallDisplay(toolCallId: nil, title: displayContent, kind: toolKind, status: status)
    }
}
