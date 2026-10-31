import ETOSCore
import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("iOS 回复流式状态", .serialized)
struct ChatResponseStreamingStateTests {
    @Test("同一气泡在等待、流式开始与结束时实时更新扫光，历史和导出保持静态", arguments: [true, false])
    func thinkingSweepFollowsObservedMessageState(isCurrentResponse: Bool) {
        var message = ChatMessage(role: .assistant, content: "")
        let state = ChatMessageRenderState(message: message)
        let bubble = ChatBubble(
            messageState: state,
            isReasoningExpanded: .constant(false),
            isToolCallsExpanded: .constant(false),
            enableMarkdown: true,
            enableBackground: false,
            enableLiquidGlass: false,
            enableNoBubbleUI: false,
            isCurrentResponse: isCurrentResponse,
            mergeWithPrevious: false,
            mergeWithNext: false,
            onSwitchToPreviousVersion: {},
            onSwitchToNextVersion: {}
        )

        // 请求尚未进入流式接收器或使用非流式响应时，等待文字也应扫光。
        #expect(bubble.shouldShimmerThinkingPlaceholder == isCurrentResponse)
        #expect(!bubble.showsStreamingIndicators)
        #expect(!bubble.shouldShimmerReasoningHeader)

        // 只更新被观察的消息，不重建外层列表或气泡，覆盖原先布尔快照滞留的问题。
        message.isReceivingStream = true
        message.reasoningContent = "正在分析"
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(bubble.showsStreamingIndicators == isCurrentResponse)
        #expect(bubble.shouldShimmerReasoningHeader == isCurrentResponse)

        message.isReceivingStream = false
        message.responseMetrics = MessageResponseMetrics()
        message.responseMetrics?.responseCompletedAt = Date()
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(!bubble.showsStreamingIndicators)
        #expect(!bubble.shouldShimmerReasoningHeader)
        #expect(!bubble.shouldShimmerThinkingPlaceholder)

        message.role = .error
        message.responseMetrics = nil
        state.update(with: message)
        state.updateVisualMessage(message)
        #expect(!bubble.shouldShimmerThinkingPlaceholder)
        #expect(!bubble.showsStreamingIndicators)
    }
}
