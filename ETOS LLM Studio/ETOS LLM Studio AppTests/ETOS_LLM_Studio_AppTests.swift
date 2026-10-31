// ============================================================================
// ETOS_LLM_Studio_AppTests.swift
// ============================================================================
// ETOS_LLM_Studio_AppTests 测试文件
// - 覆盖 iOS App 层的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

import Foundation
import SwiftUI
import Testing
import UIKit
import ETOSCore
@testable import ETOS_LLM_Studio_App

@MainActor
struct ETOS_LLM_Studio_AppTests {

    @Test("相邻气泡的局部重测量身份不会冲突")
    func testChatBubbleLayoutIdentityIncludesMessageID() {
        let firstMessageID = UUID()
        let secondMessageID = UUID()
        let first = ChatBubbleLayoutIdentity(
            messageID: firstMessageID,
            structuralRevision: 0,
            isStreaming: false,
            hasPreparedMarkdown: false,
            hasPreparedReasoningMarkdown: false
        )
        let second = ChatBubbleLayoutIdentity(
            messageID: secondMessageID,
            structuralRevision: 0,
            isStreaming: false,
            hasPreparedMarkdown: false,
            hasPreparedReasoningMarkdown: false
        )

        #expect(first != second)
        #expect(first == ChatBubbleLayoutIdentity(
            messageID: firstMessageID,
            structuralRevision: 0,
            isStreaming: false,
            hasPreparedMarkdown: false,
            hasPreparedReasoningMarkdown: false
        ))
    }

    @Test("静态 Markdown 就绪前保持流式视图身份")
    func testChatBubbleLayoutIdentityRemainsStableDuringMarkdownHandoff() {
        let messageID = UUID()
        let streaming = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 7,
            isStreaming: true,
            hasPreparedMarkdown: false,
            hasPreparedReasoningMarkdown: false
        )
        let handingOff = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 8,
            isStreaming: false,
            isStaticMarkdownHandoffInProgress: true,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: false
        )
        let staticMarkdown = ChatBubbleLayoutIdentity(
            messageID: messageID,
            structuralRevision: 8,
            isStreaming: false,
            hasPreparedMarkdown: true,
            hasPreparedReasoningMarkdown: true
        )

        #expect(streaming == handingOff)
        #expect(handingOff != staticMarkdown)
    }

    @Test("助手开始流式输出后锁定气泡宽度")
    func testStreamingAssistantBubbleUsesStableWidth() {
        #expect(ChatBubble.shouldForceBubbleWidth(
            usesNoBubbleStyle: false,
            isOutgoing: false,
            isAssistant: true,
            hasAudio: false,
            locksStreamingAssistantWidth: true,
            mergesWithAdjacentBubble: false,
            rendersReasoningToolTimeline: false
        ))
        #expect(!ChatBubble.shouldForceBubbleWidth(
            usesNoBubbleStyle: false,
            isOutgoing: false,
            isAssistant: true,
            hasAudio: false,
            locksStreamingAssistantWidth: false,
            mergesWithAdjacentBubble: false,
            rendersReasoningToolTimeline: false
        ))
        #expect(!ChatBubble.shouldForceBubbleWidth(
            usesNoBubbleStyle: false,
            isOutgoing: true,
            isAssistant: false,
            hasAudio: false,
            locksStreamingAssistantWidth: true,
            mergesWithAdjacentBubble: false,
            rendersReasoningToolTimeline: false
        ))
        #expect(!ChatBubble.shouldForceBubbleWidth(
            usesNoBubbleStyle: false,
            isOutgoing: false,
            isAssistant: false,
            hasAudio: false,
            locksStreamingAssistantWidth: true,
            mergesWithAdjacentBubble: false,
            rendersReasoningToolTimeline: false
        ))
    }


    @Test("Markdown 围栏闭合容错：重复语言标签闭合会被规范为标准围栏")
    func testMarkdownFenceNormalizationForRepeatedLanguageClosing() async {
        let source = """
```markdown
# 标题
```markdown
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        let expected = """
```markdown
# 标题
```
"""
        #expect(prepared.normalizedText == expected)
    }

    @MainActor
    @Test("Markdown 围栏闭合容错会补齐未闭合代码块")
    func testMarkdownFenceNormalizationClosesOpenFence() async {
        let source = """
```swift
let value = 42
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        let expected = """
```swift
let value = 42
```
"""
        #expect(prepared.normalizedText == expected)
    }

    @MainActor
    @Test("Markdown 围栏闭合容错不影响标准写法")
    func testMarkdownFenceNormalizationKeepsValidFence() async {
        let source = """
```swift
let value = 42
```
"""
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        #expect(prepared.normalizedText == source)
    }

    @Test("思考标题提取支持 Gemini 加粗首行")
    func testThinkingTitleExtractionSupportsGeminiBoldLine() {
        let source = """
**定位展开状态**

需要确认自动预览和用户手动展开的状态是否冲突。
"""

        #expect(ETPreparedMarkdownRenderPayload.extractThinkingTitle(from: source) == "定位展开状态")
    }

    @MainActor
    @Test("iOS 会为裸 TeX 准备原生内联公式")
    func testBareTeXPreparesNativeInlineMath() async {
        let source = #"答案是 \frac{1}{2}。"#

        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)

        #expect(prepared.containsMathContent)
        #expect(prepared.mathSegments == [
            .text("答案是 "),
            .inlineMath(#"\frac{1}{2}"#),
            .text("。")
        ])
        #expect(prepared.mathRenderText == #"答案是 \(\frac{1}{2}\)。"#)
    }

    @MainActor
    @Test("iOS 官方社群入口使用指定账号与 App 深链")
    func testOfficialCommunityLinks() {
        #expect(OfficialCommunity.qq.account == "974605250")
        #expect(
            OfficialCommunity.qq.appURL.absoluteString
                == "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=974605250&card_type=group&source=qrcode"
        )

        #expect(OfficialCommunity.telegram.account == "@ETOSLLMStudio")
        #expect(
            OfficialCommunity.telegram.appURL.absoluteString
                == "tg://resolve?domain=ETOSLLMStudio"
        )
        #expect(
            OfficialCommunity.telegram.fallbackURL?.absoluteString
                == "https://t.me/ETOSLLMStudio"
        )

        #expect(OfficialCommunity.testFlight.account == nil)
        #expect(
            OfficialCommunity.testFlight.appURL.absoluteString
                == "https://testflight.apple.com/join/d4PgF4CK"
        )
        #expect(
            OfficialCommunity.visibleCommunities(for: .appStore)
                == [.qq, .telegram, .testFlight]
        )
        #expect(
            OfficialCommunity.visibleCommunities(for: .testFlight)
                == [.qq, .telegram]
        )
    }

    @Test("iOS 工具执行失败使用红色失败状态")
    func testFailedToolCallStatusPresentation() {
        let status = ChatBubble.ToolCallBubbleStatus.failed

        #expect(status.title == NSLocalizedString("执行失败", comment: "Tool execution failed status"))
        #expect(status.iconName == "xmark.circle.fill")
        #expect(status.accentColor == .red)
    }

}
