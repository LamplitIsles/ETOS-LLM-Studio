// ============================================================================
// ConversationRuntimeTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖普通聊天的流式更新与并发输入合并语义。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("聊天消息并发测试")
struct ConversationRuntimeTests {
    @MainActor
    @Test("流式更新只替换加载消息，不覆盖并发插入的 steering")
    func streamingMergePreservesConcurrentSteering() {
        let service = ChatService()
        let session = service.createSavedSession(name: "并发 steering", activate: false)
        defer { service.deleteSessions([session]) }
        let loading = ChatMessage(role: .assistant, content: "生成中")
        let steering = ChatMessage(role: .user, content: "用户追加方向")
        service.storeRuntimeMessagesSnapshot([loading, steering], for: session.id)

        var updatedLoading = loading
        updatedLoading.content = "生成完成"
        let merged = service.messagesByMergingStreamingUpdate(
            [updatedLoading],
            loadingMessageID: loading.id,
            sessionID: session.id
        )

        #expect(merged.map(\.id) == [loading.id, steering.id])
        #expect(merged.first?.content == "生成完成")
        #expect(merged.last?.content == "用户追加方向")
    }

}
