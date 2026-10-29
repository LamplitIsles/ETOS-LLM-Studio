// ============================================================================
// ChatServiceRequestPreparation.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的请求预处理、重试辅助与工具名规范化。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    struct ResponseAttemptMetadata: Sendable {
        let groupID: UUID
        let attemptID: UUID
        let attemptIndex: Int
    }

    struct AuxiliaryContextPolicy {
        let includeBuiltInAppTools: Bool
        let includeShortcutTools: Bool
        let includeSkills: Bool
    }

    func auxiliaryContextPolicy(
        for session: ChatSession?
    ) -> AuxiliaryContextPolicy {
        let toolIsolationActive = session?.isToolContextIsolationActive ?? false
        if toolIsolationActive {
            logger.info("当前会话已屏蔽工具，将跳过工具定义与历史工具调用。")
        }
        return AuxiliaryContextPolicy(
            includeBuiltInAppTools: !toolIsolationActive,
            includeShortcutTools: !toolIsolationActive,
            includeSkills: !toolIsolationActive
        )
    }

    func resolveRequestTooling(
        for session: ChatSession?,
        localAgentContext: AgentRuntimeContext? = nil
    ) async -> (tools: [InternalToolDefinition]?, policy: AuxiliaryContextPolicy) {
        let policy = auxiliaryContextPolicy(for: session)

        var resolvedTools: [InternalToolDefinition] = []
        if policy.includeBuiltInAppTools {
            let builtInAppTools = await MainActor.run { AppToolManager.shared.builtInToolsForLLM() }
            resolvedTools.append(contentsOf: builtInAppTools)
        }
        if policy.includeShortcutTools {
            let shortcutTools = await MainActor.run { ShortcutToolManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: shortcutTools)
        }
        if policy.includeSkills {
            let skillTools = await MainActor.run { SkillManager.shared.chatToolsForLLM() }
            resolvedTools.append(contentsOf: skillTools)
        }
        if let runID = localAgentContext?.runID {
            resolvedTools = await SkillAllowedToolRuntime.shared.filteredTools(
                resolvedTools,
                runID: runID
            )
        }
        return (resolvedTools.isEmpty ? nil : resolvedTools, policy)
    }

    func preparedMessagesForRequest(
        from messages: [ChatMessage],
        loadingMessageID: UUID,
        session: ChatSession?
    ) -> [ChatMessage] {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        let baseMessages = visibleMessages.filter { $0.role != .error && $0.id != loadingMessageID }
        let normalizedMessages = normalizedMessagesForToolCallChain(baseMessages)
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let isToolIsolationActive = session?.isToolContextIsolationActive == true

        if !isToolIsolationActive {
            guard !messageRegexRules.isEmpty else {
                return normalizedMessages
            }
            return normalizedMessages.map { applyMessageRegexRules(to: $0, rules: messageRegexRules, mode: .sendOnly) }
        }

        return normalizedMessages.compactMap { message in
            if message.role == .tool {
                if isToolIsolationActive {
                    return nil
                }
            }

            var sanitized = message
            if isToolIsolationActive {
                sanitized.toolCalls = nil
                sanitized.toolCallsPlacement = nil
            }

            if sanitized.role == .assistant,
               sanitized.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               sanitized.toolCalls?.isEmpty != false {
                return nil
            }
            if messageRegexRules.isEmpty {
                return sanitized
            }
            return applyMessageRegexRules(to: sanitized, rules: messageRegexRules, mode: .sendOnly)
        }
    }

    func limitedChatHistory(_ messages: [ChatMessage], maxMessages: Int) -> [ChatMessage] {
        guard maxMessages > 0, messages.count > maxMessages else { return messages }

        let turns = ChatConversationTurnSupport.turns(in: messages)
        guard !turns.isEmpty else { return Array(messages.suffix(maxMessages)) }

        var retainedCount = 0
        var retainedStart = messages.endIndex
        for turn in turns.reversed() {
            let turnCount = turn.range.count
            if retainedCount > 0, retainedCount + turnCount > maxMessages {
                break
            }
            retainedStart = turn.range.lowerBound
            retainedCount += turnCount
            if retainedCount >= maxMessages {
                break
            }
        }
        return Array(messages[retainedStart...])
    }

    func responseAttemptMetadata(from message: ChatMessage) -> ResponseAttemptMetadata? {
        guard let groupID = message.responseGroupID,
              let attemptID = message.responseAttemptID else {
            return nil
        }
        return ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: attemptID,
            attemptIndex: message.responseAttemptIndex ?? 0
        )
    }

    func responseAttemptMetadata(for messageID: UUID, in sessionID: UUID) -> ResponseAttemptMetadata? {
        guard let message = messagesSnapshot(for: sessionID).first(where: { $0.id == messageID }) else {
            return nil
        }
        return responseAttemptMetadata(from: message)
    }

    func applyResponseAttemptMetadata(_ metadata: ResponseAttemptMetadata?, to message: inout ChatMessage) {
        guard let metadata else { return }
        message.responseGroupID = metadata.groupID
        message.responseAttemptID = metadata.attemptID
        message.responseAttemptIndex = metadata.attemptIndex
        message.selectedResponseAttemptID = metadata.attemptID
    }

    func insertingResponseAttemptMessages(
        _ additions: [ChatMessage],
        afterAttemptOf referenceMessageID: UUID,
        in messages: [ChatMessage]
    ) -> [ChatMessage] {
        guard !additions.isEmpty else { return messages }
        var updatedMessages = messages
        let referenceMessage = updatedMessages.first(where: { $0.id == referenceMessageID })
        let attemptID = referenceMessage?.responseAttemptID ?? additions.first?.responseAttemptID

        let insertionIndex: Int
        if let attemptID,
           let lastAttemptIndex = updatedMessages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            insertionIndex = updatedMessages.index(after: lastAttemptIndex)
        } else if let referenceIndex = updatedMessages.firstIndex(where: { $0.id == referenceMessageID }) {
            insertionIndex = updatedMessages.index(after: referenceIndex)
        } else {
            insertionIndex = updatedMessages.endIndex
        }

        updatedMessages.insert(contentsOf: additions, at: insertionIndex)
        return updatedMessages
    }

    func normalizedMessagesForToolCallChain(_ source: [ChatMessage]) -> [ChatMessage] {
        guard !source.isEmpty else { return source }

        var normalized: [ChatMessage] = []
        normalized.reserveCapacity(source.count)

        var index = 0
        while index < source.count {
            let message = source[index]

            if message.role == .tool {
                index += 1
                continue
            }

            guard message.role == .assistant,
                  let toolCalls = message.toolCalls,
                  !toolCalls.isEmpty else {
                normalized.append(message)
                index += 1
                continue
            }

            let validToolCallIDs = orderedToolCallIDs(from: toolCalls)
            let validToolCallIDSet = Set(validToolCallIDs)

            var nextIndex = index + 1
            var contiguousToolMessages: [ChatMessage] = []
            while nextIndex < source.count, source[nextIndex].role == .tool {
                contiguousToolMessages.append(source[nextIndex])
                nextIndex += 1
            }

            var matchedToolMessages: [ChatMessage] = []
            var matchedToolCallIDs = Set<String>()
            if !validToolCallIDSet.isEmpty {
                for toolMessage in contiguousToolMessages {
                    guard let toolCallID = normalizedToolCallID(from: toolMessage),
                          validToolCallIDSet.contains(toolCallID),
                          matchedToolCallIDs.insert(toolCallID).inserted else {
                        continue
                    }
                    matchedToolMessages.append(toolMessage)
                }
            }

            let hasMainContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let filteredCalls = toolCalls.filter { call in
                guard let toolCallID = normalizedToolCallID(call.id) else { return false }
                return matchedToolCallIDs.contains(toolCallID)
            }

            if filteredCalls.isEmpty {
                if hasMainContent {
                    var sanitizedAssistant = message
                    sanitizedAssistant.toolCalls = nil
                    sanitizedAssistant.toolCallsPlacement = nil
                    normalized.append(sanitizedAssistant)
                }
            } else {
                var sanitizedAssistant = message
                sanitizedAssistant.toolCalls = filteredCalls
                normalized.append(sanitizedAssistant)
                normalized.append(contentsOf: matchedToolMessages)
            }

            index = max(nextIndex, index + 1)
        }

        return normalized
    }

    func orderedToolCallIDs(from toolCalls: [InternalToolCall]) -> [String] {
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(toolCalls.count)
        var seen = Set<String>()
        for toolCall in toolCalls {
            guard let normalizedID = normalizedToolCallID(toolCall.id),
                  seen.insert(normalizedID).inserted else { continue }
            orderedIDs.append(normalizedID)
        }
        return orderedIDs
    }

    func normalizedToolCallID(from message: ChatMessage) -> String? {
        message.toolCalls?.first.flatMap { normalizedToolCallID($0.id) }
    }

    func normalizedToolCallID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
