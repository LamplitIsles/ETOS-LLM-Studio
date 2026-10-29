// ============================================================================
// ChatServicePromptConstruction.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的系统提示词拼装与周期性时间路标构造。
// ============================================================================

import Foundation

extension ChatService {
    func buildFinalSystemPrompt(
        includeSystemTime: Bool,
        roleplayPrompt: String? = nil
    ) -> String {
        var parts: [String] = []

        if let roleplayPrompt,
           !roleplayPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(roleplayPrompt)
        }

        if includeSystemTime {
            parts.append(makeSystemTimePromptBlock())
        }

        return parts.joined(separator: "\n\n")
    }

    func tailContextRole(apiFormat: String, openAIUsesSystemRole: Bool) -> MessageRole {
        let normalizedAPIFormat = apiFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch ProviderAPIFormatFamily(apiFormat: normalizedAPIFormat) {
        case .anthropic, .gemini, .geminiInteractions:
            // 这两类协议会把所有 system 消息提升到请求前缀，尾部上下文统一使用 user。
            return .user
        case .openAICompatible, .openAIResponses:
            return openAIUsesSystemRole ? .system : .user
        }
    }

    func makeTailSystemTimeMessage(apiFormat: String, openAIUsesSystemRole: Bool) -> ChatMessage {
        ChatMessage(
            role: tailContextRole(apiFormat: apiFormat, openAIUsesSystemRole: openAIUsesSystemRole),
            content: makeSystemTimePromptBlock()
        )
    }

    func appendTailContextMessage(
        _ message: ChatMessage,
        to messages: inout [ChatMessage],
        apiFormat: String
    ) {
        guard message.role == .user else {
            messages.append(message)
            return
        }

        let normalizedAPIFormat = apiFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let movesSystemMessagesToPrefix: Bool
        switch ProviderAPIFormatFamily(apiFormat: normalizedAPIFormat) {
        case .anthropic, .gemini, .geminiInteractions:
            movesSystemMessagesToPrefix = true
        case .openAICompatible, .openAIResponses:
            movesSystemMessagesToPrefix = false
        }

        if !movesSystemMessagesToPrefix {
            guard messages.last?.role == .user else {
                messages.append(message)
                return
            }
            let lastIndex = messages.index(before: messages.endIndex)
            let separator = messages[lastIndex].content.isEmpty ? "" : "\n\n"
            messages[lastIndex].content += separator + message.content
            return
        }

        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else {
            messages.append(message)
            return
        }

        let messagesAfterUser = messages[messages.index(after: userIndex)...]
        guard messagesAfterUser.allSatisfy({ $0.role == .system }) else {
            messages.append(message)
            return
        }

        let separator = messages[userIndex].content.isEmpty ? "" : "\n\n"
        messages[userIndex].content += separator + message.content
    }

    func makeSystemTimePromptBlock() -> String {
        BuiltInPromptStore.render(
            .systemTime,
            variables: ["time": SystemTimeContextFormatter.description()]
        )
    }

    func xmlEscapedAttribute(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func injectPeriodicTimeLandmarkIfNeeded(
        into chatHistory: [ChatMessage],
        sessionID: UUID,
        now: Date,
        intervalMinutes: Int
    ) -> [ChatMessage] {
        guard !chatHistory.isEmpty else { return chatHistory }

        let safeIntervalMinutes = max(1, intervalMinutes)
        let interval = TimeInterval(safeIntervalMinutes * 60)
        if let lastInjectedAt = periodicTimeLandmarkLastInjectedAtBySessionID[sessionID],
           now.timeIntervalSince(lastInjectedAt) < interval {
            return chatHistory
        }

        let cutoff = now.addingTimeInterval(-interval)
        var anchorIndex: Int?
        var anchorTime: Date?

        for (index, message) in chatHistory.enumerated() {
            guard let timestamp = messageTimelineTimestamp(for: message), timestamp <= cutoff else {
                continue
            }
            if let bestTime = anchorTime {
                if timestamp >= bestTime {
                    anchorTime = timestamp
                    anchorIndex = index
                }
            } else {
                anchorTime = timestamp
                anchorIndex = index
            }
        }

        guard let resolvedIndex = anchorIndex, let resolvedAnchorTime = anchorTime else {
            return chatHistory
        }

        var updated = chatHistory
        updated.insert(
            makePeriodicTimeLandmarkMessage(anchorTime: resolvedAnchorTime),
            at: resolvedIndex
        )
        periodicTimeLandmarkLastInjectedAtBySessionID[sessionID] = now
        return updated
    }

    func messageTimelineTimestamp(for message: ChatMessage) -> Date? {
        if let requestedAt = message.requestedAt {
            return requestedAt
        }
        if let requestStartedAt = message.responseMetrics?.requestStartedAt {
            return requestStartedAt
        }
        return message.responseMetrics?.responseCompletedAt
    }

    func makePeriodicTimeLandmarkMessage(anchorTime: Date) -> ChatMessage {
        let content = BuiltInPromptStore.render(
            .systemTime,
            variables: ["time": SystemTimeContextFormatter.description(at: anchorTime)]
        )
        return ChatMessage(role: .system, content: content)
    }

    func findSafeInsertIndex(_ preferredIndex: Int, in messages: [ChatMessage]) -> Int {
        guard !messages.isEmpty else { return max(0, preferredIndex) }
        var index = max(0, min(preferredIndex, messages.count))
        guard index > 0, index < messages.count else { return index }

        var cursor = 0
        while cursor < messages.count {
            let message = messages[cursor]
            let hasToolCalls = message.role == .assistant && !(message.toolCalls?.isEmpty ?? true)
            guard hasToolCalls else {
                cursor += 1
                continue
            }

            let rangeStart = cursor + 1
            var rangeEnd = rangeStart
            while rangeEnd < messages.count, messages[rangeEnd].role == .tool {
                rangeEnd += 1
            }

            if rangeStart < rangeEnd && index >= rangeStart && index < rangeEnd {
                index = cursor
                break
            }
            cursor = max(cursor + 1, rangeEnd)
        }

        return index
    }
}
