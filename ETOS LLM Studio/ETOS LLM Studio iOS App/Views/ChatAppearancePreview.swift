#if os(iOS)
import SwiftUI
import ETOSCore

/// Uses the same message bubbles as CFL chat without creating a conversation.
struct ChatAppearancePreview: View {
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let enableAdvancedRenderer: Bool

    @StateObject private var user = ChatMessageRenderState(message: ChatMessage(
        role: .user,
        content: NSLocalizedString("预览用户消息", value: "Hello! How does this look?", comment: "Appearance preview user message")
    ))
    @StateObject private var assistant = ChatMessageRenderState(message: ChatMessage(
        role: .assistant,
        content: NSLocalizedString("预览助手消息", value: "Here's a **preview** with a formula: $E=mc^2$.", comment: "Appearance preview assistant message")
    ))
    @State private var width: CGFloat?

    var body: some View {
        VStack(spacing: 4) {
            bubble(user, markdown: false)
            bubble(assistant, markdown: enableMarkdown)
        }
        .padding(.vertical, 12)
        .background {
            ChatBackgroundLayer(isChatVisible: false, updatesDisplayTarget: false)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
            if measured > 0 { width = measured }
        }
        .clipped()
        .environment(\.markdownRemoteImagesEnabled, false)
        .allowsHitTesting(false)
    }

    private func bubble(_ message: ChatMessageRenderState, markdown: Bool) -> some View {
        ChatBubble(
            messageState: message,
            layoutWidth: width,
            isReasoningExpanded: .constant(false),
            isToolCallsExpanded: .constant(false),
            enableMarkdown: markdown,
            enableBackground: enableBackground,
            enableLiquidGlass: enableLiquidGlass,
            enableNoBubbleUI: enableNoBubbleUI,
            enableAdvancedRenderer: enableAdvancedRenderer,
            enableMathRendering: enableAdvancedRenderer,
            isCurrentResponse: false,
            mergeWithPrevious: false,
            mergeWithNext: false,
            allowsReadAloud: true,
            onSwitchToPreviousVersion: {},
            onSwitchToNextVersion: {}
        )
    }
}
#endif
