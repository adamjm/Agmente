import SwiftUI
import MarkdownView

struct ChatTranscriptInsets: Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    static let zero = ChatTranscriptInsets(top: 0, left: 0, bottom: 0, right: 0)
}

#if canImport(UIKit)
import UIKit

private extension ChatTranscriptInsets {
    var platformInsets: UIEdgeInsets {
        UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}

struct ChatTranscriptContainerView: UIViewRepresentable {
    let state: ChatTranscriptState
    let messages: [ChatMessage]
    let contentInsets: ChatTranscriptInsets
    let actionHandlers: ChatEntryActionHandlers
    var onAtBottomChanged: ((Bool) -> Void)?
    var config: ChatRendererConfig = .default

    final class Coordinator {
        var hasRendered = false
        var lastMessages: [ChatMessage] = []
        var lastInsets: ChatTranscriptInsets = .zero
        var onAtBottomChanged: ((Bool) -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> HighPerformanceChatListView {
        let view = HighPerformanceChatListView()
        view.config = config
        view.actionHandlers = actionHandlers
        view.updateContentInsets(contentInsets.platformInsets)
        context.coordinator.lastInsets = contentInsets
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        view.onAtBottomChanged = { [weak state] isAtBottom in
            Task { @MainActor in
                state?.isAtBottom = isAtBottom
            }
            context.coordinator.onAtBottomChanged?(isAtBottom)
        }
        state.listView = view
        state.scrollToBottomHandler = nil
        return view
    }

    func updateUIView(_ uiView: HighPerformanceChatListView, context: Context) {
        uiView.config = config
        uiView.actionHandlers = actionHandlers
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        if context.coordinator.lastInsets != contentInsets {
            uiView.updateContentInsets(contentInsets.platformInsets)
            context.coordinator.lastInsets = contentInsets
        }
        if !context.coordinator.hasRendered || context.coordinator.lastMessages != messages {
            let shouldAnimateScrollToBottom = shouldAnimateScrollToBottom(
                from: context.coordinator.lastMessages,
                to: messages,
                hasRendered: context.coordinator.hasRendered
            )
            uiView.render(
                messages: messages,
                animated: false,
                scrollToBottomAnimated: shouldAnimateScrollToBottom
            )
            context.coordinator.lastMessages = messages
            context.coordinator.hasRendered = true
        }
        state.listView = uiView
        state.scrollToBottomHandler = nil
    }

    private func shouldAnimateScrollToBottom(
        from oldMessages: [ChatMessage],
        to newMessages: [ChatMessage],
        hasRendered: Bool
    ) -> Bool {
        ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: hasRendered
        )
    }
}
#elseif canImport(AppKit)
import AppKit

struct ChatTranscriptContainerView: View {
    let state: ChatTranscriptState
    let messages: [ChatMessage]
    let contentInsets: ChatTranscriptInsets
    let actionHandlers: ChatEntryActionHandlers
    var onAtBottomChanged: ((Bool) -> Void)?
    var config: ChatRendererConfig = .default

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        fallbackRow(for: message)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, contentInsets.top)
                .padding(.bottom, contentInsets.bottom)
                .padding(.leading, contentInsets.left)
                .padding(.trailing, contentInsets.right)
            }
            .onAppear {
                state.listView = nil
                state.isAtBottom = true
                state.scrollToBottomHandler = { animated in
                    guard let lastId = messages.last?.id else { return }
                    if animated {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
                onAtBottomChanged?(true)
            }
            .onChange(of: messages.count) { _, _ in
                state.isAtBottom = true
                onAtBottomChanged?(true)
            }
            .onDisappear {
                state.scrollToBottomHandler = nil
            }
        }
    }

    @ViewBuilder
    private func fallbackRow(for message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(roleTitle(for: message.role))
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            if !message.content.isEmpty {
                Text(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(message.images) { image in
                        Image(nsImage: image.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(10)
        .background(backgroundColor(for: message))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func roleTitle(for role: ChatMessage.Role) -> String {
        switch role {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .system:
            return "System"
        }
    }

    private func backgroundColor(for message: ChatMessage) -> Color {
        if message.isError {
            return Color.red.opacity(0.12)
        }
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.1)
        case .assistant, .system:
            return Color.secondary.opacity(0.1)
        }
    }
}
#endif
