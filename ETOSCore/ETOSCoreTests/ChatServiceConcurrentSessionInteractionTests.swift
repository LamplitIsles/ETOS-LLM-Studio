// ============================================================================
// ChatServiceConcurrentSessionInteractionTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 聊天服务并发会话的取消请求、流式失败与测试基础设施。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("聊天服务并发会话交互测试")
struct ChatServiceConcurrentSessionInteractionTests {

    @MainActor
    @Test("删除正在生成的消息只取消匹配请求")
    func testCancellingRequestBeforeDeletingMatchesLoadingMessage() async {
        let service = ChatService()
        let session = service.createSavedSession(name: "删除流式消息")
        let loadingMessageID = UUID()
        let requestTask = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        service.setRequestContext(
            ChatService.RequestExecutionContext(
                token: UUID(),
                task: requestTask,
                loadingMessageID: loadingMessageID,
                imageGenerationContext: nil
            ),
            for: session.id
        )
        defer {
            requestTask.cancel()
            service.deleteSessions([session])
        }

        await service.cancelRequestIfGenerating(messageID: UUID(), in: session.id)
        #expect(service.hasActiveRequestContext(for: session.id))

        await service.cancelRequestIfGenerating(messageID: loadingMessageID, in: session.id)
        #expect(!service.hasActiveRequestContext(for: session.id))
        #expect(!service.runningSessionIDsSubject.value.contains(session.id))
    }

    @MainActor
    @Test("切回后台运行会话时优先使用运行期消息快照")
    func testActivatingRunningBackgroundSessionUsesRuntimeMessageSnapshot() {
        let service = ChatService()
        let sessionA = service.createSavedSession(name: "后台工具会话")
        let sessionB = service.createSavedSession(name: "当前会话")
        defer {
            service.deleteSessions([sessionA, sessionB])
        }

        let toolCall = InternalToolCall(
            id: "call_widget",
            toolName: "app_show_widget",
            arguments: #"{"widget_code":"<div>hi</div>"}"#
        )
        let staleAssistant = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [toolCall],
            responseGroupID: sessionA.id,
            responseAttemptID: UUID(),
            responseAttemptIndex: 0
        )

        var resolvedCall = toolCall
        resolvedCall.result = "OK"
        let freshAssistant = ChatMessage(
            id: staleAssistant.id,
            role: .assistant,
            content: "",
            toolCalls: [resolvedCall],
            responseGroupID: staleAssistant.responseGroupID,
            responseAttemptID: staleAssistant.responseAttemptID,
            responseAttemptIndex: staleAssistant.responseAttemptIndex
        )
        let followUpLoading = ChatMessage(
            role: .assistant,
            content: "",
            responseGroupID: staleAssistant.responseGroupID,
            responseAttemptID: staleAssistant.responseAttemptID,
            responseAttemptIndex: staleAssistant.responseAttemptIndex
        )
        let runtimeMessages = [freshAssistant, followUpLoading]
        let token = UUID()
        service.setRequestContext(
            ChatService.RequestExecutionContext(
                token: token,
                task: nil,
                loadingMessageID: followUpLoading.id,
                imageGenerationContext: nil
            ),
            for: sessionA.id
        )
        service.storeRuntimeMessagesSnapshot(runtimeMessages, for: sessionA.id)

        service.setCurrentSession(sessionB)
        let activatedMessages = service.messagesForSessionActivation(sessionA.id)

        #expect(activatedMessages.map(\.id) == runtimeMessages.map(\.id))
        #expect(activatedMessages.first?.toolCalls?.first?.result == "OK")

        service.clearRequestContextIfNeeded(for: sessionA.id, token: token)
    }
}
