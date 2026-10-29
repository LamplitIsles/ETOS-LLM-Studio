// ============================================================================
// TemporaryChatSessionTests.swift
// ============================================================================

import Testing
import Combine
import Foundation
@testable import ETOSCore

@Suite("临时对话会话测试", .serialized)
struct TemporaryChatSessionTests {
    @Test("对话开始后只能关闭已开启的临时对话")
    func toggleAvailabilityRespectsConversationState() {
        #expect(TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: false,
            hasConversationStarted: false
        ))
        #expect(!TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: false,
            hasConversationStarted: true
        ))
        #expect(TemporaryChatToggleAvailability.isAvailable(
            isTemporaryChatEnabled: true,
            hasConversationStarted: true
        ))
    }
}
