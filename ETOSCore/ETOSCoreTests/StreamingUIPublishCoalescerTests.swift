// ============================================================================
// StreamingUIPublishCoalescerTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件验证流式显示模式的刷新与淡入策略。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

struct ChatStreamingDisplayModeTests {
    @Test("流式显示模式提供不同刷新与淡入节奏")
    func testStreamingDisplayModePolicies() {
        #if os(watchOS)
        #expect(ChatStreamingDisplayMode.immediate.uiPublishInterval == 0.080)
        #expect(ChatStreamingDisplayMode.gentle.uiPublishInterval == 0.160)
        #else
        #expect(ChatStreamingDisplayMode.immediate.uiPublishInterval == 0.060)
        #expect(ChatStreamingDisplayMode.gentle.uiPublishInterval == 0.120)
        #endif
        #expect(ChatStreamingDisplayMode.immediate.textRevealDuration == 0.28)
        #expect(ChatStreamingDisplayMode.gentle.textRevealDuration == 0.45)
        #expect(ChatStreamingDisplayMode.immediate.textRevealStaggerWindow == 0.04)
        #expect(ChatStreamingDisplayMode.gentle.textRevealStaggerWindow == 0.10)
        #expect(ChatStreamingDisplayMode.immediate.viewportFollowDuration == 0.12)
        #expect(ChatStreamingDisplayMode.gentle.viewportFollowDuration == 0.20)
        #expect(ChatStreamingDisplayMode.normalized("unknown") == .immediate)
        #expect(AppConfigKey.chatStreamingDisplayMode.defaultValue == .text("immediate"))
        #expect(AppConfigKey.chatStreamingDisplayMode.participatesInSync)
    }

}
