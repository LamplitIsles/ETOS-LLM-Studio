// ============================================================================
// ChatServiceToolContinuationTests.swift
// ============================================================================
// 覆盖工具结果写回位置、混合调用收敛与多步请求的实际上下文。
// ============================================================================

import Foundation
import Combine
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("迟到工具结果紧随原调用，保留同版本后续工具链", arguments: [false, true])
    func delayedToolResultStaysWithOriginalCall(hasAttemptMetadata: Bool) async throws {
        await cleanup()
        let session = createPermanentTestSession(name: "迟到工具结果回归")
        defer { chatService.deleteSessions([session]) }
        let sessionID = session.id
        let user = ChatMessage(role: .user, content: "检索并整理结果")
        let attempt = hasAttemptMetadata
            ? ChatService.ResponseAttemptMetadata(groupID: user.id, attemptID: UUID(), attemptIndex: 0)
            : nil
        let firstCall = InternalToolCall(id: "first-search", toolName: "search_memory", arguments: "{}")
        let delayedCall = InternalToolCall(id: "background-save", toolName: "save_memory", arguments: "{}")
        let nextCall = InternalToolCall(id: "next-search", toolName: "search_memory", arguments: "{}")
        var source = ChatMessage(role: .assistant, content: "检索中", toolCalls: [firstCall, delayedCall])
        var firstResult = ChatMessage(role: .tool, content: "第一轮检索结果", toolCalls: [firstCall])
        var nextSource = ChatMessage(role: .assistant, content: "", toolCalls: [nextCall])
        var nextResult = ChatMessage(role: .tool, content: "第二轮检索结果", toolCalls: [nextCall])
        var loading = ChatMessage(role: .assistant, content: "")
        var delayedResult = ChatMessage(role: .tool, content: "后台保存完成", toolCalls: [delayedCall])
        chatService.applyResponseAttemptMetadata(attempt, to: &source)
        chatService.applyResponseAttemptMetadata(attempt, to: &firstResult)
        chatService.applyResponseAttemptMetadata(attempt, to: &nextSource)
        chatService.applyResponseAttemptMetadata(attempt, to: &nextResult)
        chatService.applyResponseAttemptMetadata(attempt, to: &loading)
        chatService.applyResponseAttemptMetadata(attempt, to: &delayedResult)
        chatService.updateMessages([user, source, firstResult, nextSource, nextResult, loading], for: sessionID)

        let updated = try await chatService.insertConversationResponseAttemptMessagesAtomically(
            [delayedResult], afterAttemptOf: source.id, in: sessionID
        )
        let expectedIDs = [user.id, source.id, firstResult.id, delayedResult.id, nextSource.id, nextResult.id, loading.id]
        #expect(updated.map(\.id) == expectedIDs)

        let prepared = chatService.preparedMessagesForRequest(
            from: updated, loadingMessageID: loading.id, session: chatService.currentSessionSubject.value
        )
        #expect(prepared.map(\.id) == Array(expectedIDs.dropLast()))
        #expect(prepared.filter { $0.role == .tool }.map(\.content) == [
            "第一轮检索结果", "后台保存完成", "第二轮检索结果"
        ])
        await cleanup()
    }

}
