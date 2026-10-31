// ============================================================================
// ChatServiceResponseExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的响应执行、消息发布与标准响应处理。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    /// 仅在内存中保留“最近一条助手消息”的流式速度采样，避免历史样本长期占用内存。
    func normalizedMessagesForRuntime(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) -> [ChatMessage] {
        guard !messages.isEmpty else { return messages }
        let keepMessageID = preferredMessageID ?? messages.last(where: { $0.role == .assistant })?.id

        return messages.map { message in
            guard var metrics = message.responseMetrics, metrics.speedSamples != nil else {
                return message
            }
            if let keepMessageID, message.id == keepMessageID {
                return message
            }
            var trimmedMessage = message
            metrics.speedSamples = nil
            trimmedMessage.responseMetrics = metrics
            return trimmedMessage
        }
    }

    func publishMessages(
        _ messages: [ChatMessage],
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        let normalized = normalizedMessagesForRuntime(messages, keepingSpeedSamplesFor: preferredMessageID)
        messagesForSessionSubject.send(normalized)
    }

    func scheduleAchievementUnlockIfNeeded(_ id: AchievementID) {
        Task.detached(priority: .utility) {
            let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: id)
        }
    }
}
