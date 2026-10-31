// ============================================================================
// ChatServiceVersionAndMetricTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的重试版本管理与流式响应测速测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

extension ChatServiceTests {
    @Test("删除回复尝试中的非当前版本不会切换当前版本")
    func testDeleteUnselectedResponseAttemptKeepsCurrentSelection() async throws {
        await cleanup()

        guard let sessionID = chatService.currentSessionSubject.value?.id else {
            Issue.record("当前会话为空，无法验证回复版本删除行为。")
            await cleanup()
            return
        }

        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        let userMessage = ChatMessage(
            role: .user,
            content: "请重新生成",
            selectedResponseAttemptID: secondAttemptID
        )
        let firstAssistant = ChatMessage(
            role: .assistant,
            content: "第一版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: firstAttemptID,
            responseAttemptIndex: 0
        )
        let secondAssistant = ChatMessage(
            role: .assistant,
            content: "第二版回复",
            responseGroupID: userMessage.id,
            responseAttemptID: secondAttemptID,
            responseAttemptIndex: 1
        )
        chatService.updateMessages([userMessage, firstAssistant, secondAssistant], for: sessionID)

        let updatedMessages = try #require(
            ChatResponseAttemptSupport.deleteAttempt(
                at: 0,
                groupID: userMessage.id,
                in: chatService.messagesForSessionSubject.value
            )
        )
        if let anchorIndex = updatedMessages.firstIndex(where: { $0.id == userMessage.id && $0.role == .user }) {
            #expect(updatedMessages[anchorIndex].selectedResponseAttemptID == secondAttemptID)
        } else {
            Issue.record("未找到回复尝试锚点消息。")
        }

        #expect(ChatResponseAttemptSupport.visibleMessages(from: updatedMessages).map(\.id) == [
            userMessage.id,
            secondAssistant.id
        ])

        await cleanup()
    }
}
