// ============================================================================
// ChatServiceMessageHandling.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的消息写入、更新与回复原子化。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    // MARK: - 消息生命周期与重试恢复

    func finalizeInterruptedReasoningMessage(_ message: ChatMessage, completedAt: Date = Date()) -> ChatMessage {
        var updated = message
        updated.isReceivingStream = false
        let reasoning = (updated.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return updated }

        var metrics = updated.responseMetrics ?? MessageResponseMetrics()
        if metrics.reasoningStartedAt == nil {
            metrics.reasoningStartedAt = metrics.requestStartedAt ?? updated.requestedAt ?? completedAt
        }
        if metrics.reasoningCompletedAt == nil {
            metrics.reasoningCompletedAt = completedAt
        }
        updated.responseMetrics = metrics
        return updated
    }

    func removeMessage(withID messageID: UUID, in sessionID: UUID) async {
        if messagesSnapshot(for: sessionID).contains(where: { $0.id == messageID }) {
            do {
                _ = try await deleteConversationMessage(id: messageID, from: sessionID)
            } catch {
                logger.error("原子移除占位消息失败：\(error.localizedDescription)")
                return
            }
            logger.info("已移除占位消息 \(messageID.uuidString)。")
        }
    }

    func shouldRemoveLoadingMessageOnCancel(loadingMessageID: UUID, in sessionID: UUID) -> Bool {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == loadingMessageID }) else {
            return false
        }
        return !messageHasDisplayablePayload(message)
    }

    func finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: UUID, in sessionID: UUID) async {
        await updateExistingConversationMessage(id: loadingMessageID, in: sessionID) { message in
            let finalized = finalizeInterruptedReasoningMessage(message)
            guard finalized != message else { return false }
            message = finalized
            return true
        }
    }

    func messageHasDisplayablePayload(_ message: ChatMessage) -> Bool {
        let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasToolCalls = !(message.toolCalls ?? []).isEmpty
        let hasImages = !(message.imageFileNames ?? []).isEmpty
        let hasAudio = message.audioFileName != nil
        let hasFiles = !(message.fileFileNames ?? []).isEmpty
        return hasContent || hasReasoning || hasToolCalls || hasImages || hasAudio || hasFiles
    }
}
