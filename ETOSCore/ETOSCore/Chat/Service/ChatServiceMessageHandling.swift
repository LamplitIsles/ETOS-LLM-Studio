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
    // MARK: - 错误消息与消息写入

    public func addErrorMessage(_ content: String, sessionID: UUID? = nil, httpStatusCode: Int? = nil) {
        let resolvedSessionID: UUID
        if let sessionID {
            resolvedSessionID = sessionID
        } else if let currentSessionID = currentSessionSubject.value?.id {
            resolvedSessionID = currentSessionID
        } else {
            return
        }
        // 格式化错误内容，使其更简洁易读
        let (formattedContent, fullContent) = formatErrorContent(content, httpStatusCode: httpStatusCode)

        func makeErrorMessage(
            _ requestedAt: Date?,
            _ prefix: String? = nil,
            metadata: ResponseAttemptMetadata? = nil
        ) -> ChatMessage {
            let resolvedContent: String
            let resolvedFullContent: String?
            if let prefix, !prefix.isEmpty {
                resolvedContent = "\(prefix)\n\n\(formattedContent)"
                if let fullContent {
                    resolvedFullContent = "\(prefix)\n\n\(fullContent)"
                } else {
                    resolvedFullContent = nil
                }
            } else {
                resolvedContent = formattedContent
                resolvedFullContent = fullContent
            }
            var message = ChatMessage(
                id: UUID(),
                role: .error,
                content: resolvedContent,
                requestedAt: requestedAt,
                fullErrorContent: resolvedFullContent
            )
            applyResponseAttemptMetadata(metadata, to: &message)
            return message
        }

        let messages = mutateRuntimeMessages(for: resolvedSessionID, requireCurrentRequestIfPresent: true) { messages in
            let loadingIndex: Int? = {
                // 优先使用当前请求记录的 loading 消息，避免误命中历史中的空 assistant（例如工具调用占位消息）。
                if let loadingMessageID = loadingMessageID(for: resolvedSessionID),
                   let index = messages.firstIndex(where: { $0.id == loadingMessageID && $0.role == .assistant }) {
                    return index
                }

                // 回退策略仅允许替换“最后一条消息且为空 assistant”，避免破坏中间历史结构。
                guard let lastIndex = messages.indices.last else { return nil }
                let lastMessage = messages[lastIndex]
                let isLastLoadingAssistant = lastMessage.role == .assistant
                    && lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return isLastLoadingAssistant ? lastIndex : nil
            }()

            // 找到正在加载中的消息
            if let loadingIndex {
                let loadingMessage = finalizeInterruptedReasoningMessage(messages[loadingIndex])
                messages[loadingIndex] = loadingMessage
                let loadingAttemptMetadata = responseAttemptMetadata(from: loadingMessage)
                let shouldPreserveLoadingMessage = messageHasDisplayablePayload(loadingMessage)

                if shouldPreserveLoadingMessage {
                    messages.insert(makeErrorMessage(loadingMessage.requestedAt, metadata: loadingAttemptMetadata), at: loadingIndex + 1)
                    logger.error("流式内容已保留，并追加错误消息。")
                } else {
                    // 正常场景：将 loading message 转为 error
                    messages[loadingIndex] = ChatMessage(
                        id: loadingMessage.id,
                        role: .error,
                        content: formattedContent,
                        requestedAt: loadingMessage.requestedAt,
                        modelReference: loadingMessage.modelReference,
                        costEstimate: loadingMessage.costEstimate,
                        fullErrorContent: fullContent,
                        sentSystemPromptSnapshot: loadingMessage.sentSystemPromptSnapshot,
                        responseGroupID: loadingMessage.responseGroupID,
                        responseAttemptID: loadingMessage.responseAttemptID,
                        responseAttemptIndex: loadingMessage.responseAttemptIndex,
                        selectedResponseAttemptID: loadingMessage.selectedResponseAttemptID ?? loadingMessage.responseAttemptID
                    )
                    logger.error("错误消息已添加。")
                }
            } else {
                // 没有 loading message，直接添加错误
                messages.append(makeErrorMessage(nil))
                logger.error("错误消息已添加。")
            }

            messages = messages.flatMap(ChatMessageAtomicContentSupport.atomized)

            return true
        }
        if let messages { publishMessagesIfCurrentSession(messages, for: resolvedSessionID) }
    }

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

    func attachCostEstimateIfPossible(
        to message: inout ChatMessage,
        using context: RequestLogContext
    ) {
        message.modelReference = message.modelReference ?? context.modelReference
        message.costEstimate = ModelCostCalculator.estimateCost(
            usage: message.tokenUsage,
            pricing: context.modelPricing,
            requestedAt: message.requestedAt ?? context.requestedAt
        )
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

    /// 将最终确定的消息更新到消息列表中
    @discardableResult
    func updateMessage(with newMessage: ChatMessage, for loadingMessageID: UUID, in sessionID: UUID) async -> Bool {
        guard let priorMessages = currentRequestMessages(containing: loadingMessageID, in: sessionID) else { return false }
        let didProcessRoleplay = RoleplayRuntime.processMVU(
            content: newMessage.content,
            messageID: loadingMessageID,
            versionIndex: priorMessages.first(where: { $0.id == loadingMessageID })?.getCurrentVersionIndex() ?? 0,
            sessionID: sessionID,
            previousMessages: priorMessages.filter { $0.id != loadingMessageID },
            store: roleplayStore
        )
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let newMessage = messageRegexRules.isEmpty
            ? newMessage
            : applyMessageRegexRules(to: newMessage, rules: messageRegexRules, mode: .persist)
        let didUpdate = replaceExistingResponseMessage(id: loadingMessageID, in: sessionID) { existingMessage in
            // 无论普通请求还是轮次重试，都只替换已预先放入正确位置的占位气泡。
            let preservedToolCalls = existingMessage.toolCalls
            let mergedToolCalls: [InternalToolCall]? = {
                if let newCalls = newMessage.toolCalls, !newCalls.isEmpty {
                    return newCalls
                }
                // 如果新消息没有附带工具调用，则沿用之前的记录，方便在最终答案中回顾工具使用详情。
                return preservedToolCalls
            }()
            var updatedMessage = ChatMessage(
                id: loadingMessageID, // 保持ID不变
                role: newMessage.role,
                content: newMessage.content,
                requestedAt: existingMessage.requestedAt ?? newMessage.requestedAt,
                reasoningContent: newMessage.reasoningContent,
                reasoningProviderSpecificFields: newMessage.reasoningProviderSpecificFields ?? existingMessage.reasoningProviderSpecificFields,
                providerResponseMetadata: newMessage.providerResponseMetadata ?? existingMessage.providerResponseMetadata,
                toolCalls: mergedToolCalls, // 确保 toolCalls 保持最新或沿用历史数据
                toolCallsPlacement: newMessage.toolCallsPlacement ?? existingMessage.toolCallsPlacement,
                tokenUsage: newMessage.tokenUsage ?? existingMessage.tokenUsage,
                modelReference: newMessage.modelReference ?? existingMessage.modelReference,
                costEstimate: newMessage.costEstimate ?? existingMessage.costEstimate,
                audioFileName: newMessage.audioFileName ?? existingMessage.audioFileName,
                imageFileNames: newMessage.imageFileNames ?? existingMessage.imageFileNames,
                modelExcludedImageFileNames: newMessage.modelExcludedImageFileNames
                    ?? existingMessage.modelExcludedImageFileNames,
                fileFileNames: newMessage.fileFileNames ?? existingMessage.fileFileNames,
                videoAnalysisResults: newMessage.videoAnalysisResults ?? existingMessage.videoAnalysisResults,
                fullErrorContent: newMessage.fullErrorContent ?? existingMessage.fullErrorContent,
                sentSystemPromptSnapshot: newMessage.sentSystemPromptSnapshot ?? existingMessage.sentSystemPromptSnapshot,
                responseMetrics: newMessage.responseMetrics ?? existingMessage.responseMetrics,
                responseGroupID: newMessage.responseGroupID ?? existingMessage.responseGroupID,
                responseAttemptID: newMessage.responseAttemptID ?? existingMessage.responseAttemptID,
                responseAttemptIndex: newMessage.responseAttemptIndex ?? existingMessage.responseAttemptIndex,
                selectedResponseAttemptID: newMessage.selectedResponseAttemptID ?? existingMessage.selectedResponseAttemptID
            )
            updatedMessage.usesRainbowThinkingSweep = existingMessage.usesRainbowThinkingSweep
            return ChatMessageAtomicContentSupport.atomized(updatedMessage)
        }
        if didUpdate, didProcessRoleplay != nil {
            // 流式正文可能已与最终消息相同；变量快照落盘后仍需显式重算酒馆 HTML。
            RoleplayDisplayedMessageBridge.postDidChange(sessionID: sessionID)
        }
        return didUpdate
    }

    // MARK: - 成就追踪

    func scheduleAssistantReplyAchievementDetectionIfNeeded(_ content: String) {
        Task.detached(priority: .utility) {
            guard !content.isEmpty else { return }

            let hasUnlockedSteadyCatch = await AchievementCenter.shared.hasUnlocked(id: .steadyCatch)
            if !hasUnlockedSteadyCatch,
               AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: content) {
                await AchievementCenter.shared.unlock(id: .steadyCatch)
            }

            let hasUnlockedLanguageLubrication = await AchievementCenter.shared.hasUnlocked(id: .languageLubrication)
            if !hasUnlockedLanguageLubrication,
               AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: content) {
                await AchievementCenter.shared.unlock(id: .languageLubrication)
            }
        }
    }

    func scheduleUserMessageAchievementDetectionIfNeeded(
        content: String,
        userMessageCount: Int,
        sentAt: Date,
        previousAssistantReply: String?
    ) {
        Task.detached(priority: .utility) {
            let hasUnlockedPoliteHuman = await AchievementCenter.shared.hasUnlocked(id: .politeHuman)
            let ids = AchievementTriggerEvaluator.userMessageAchievementIDs(
                for: content,
                userMessageCount: userMessageCount,
                sentAt: sentAt,
                previousAssistantReply: previousAssistantReply,
                includePoliteHuman: !hasUnlockedPoliteHuman
            )
            guard !ids.isEmpty else { return }

            for id in ids {
                let hasUnlocked = await AchievementCenter.shared.hasUnlocked(id: id)
                guard !hasUnlocked else { continue }
                await AchievementCenter.shared.unlock(id: id)
            }
        }
    }

    func latestAssistantReply(in sessionID: UUID) -> String? {
        messagesSnapshot(for: sessionID).last(where: {
            $0.role == .assistant
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content
    }

    func registerRetryAchievementAttempt(sessionID: UUID, content: String) {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            resetConsecutiveRetryTracking()
            return
        }

        let signature = RetryAchievementSignature(sessionID: sessionID, content: trimmedContent)
        if consecutiveRetrySignature == signature {
            consecutiveRetryCount += 1
        } else {
            consecutiveRetrySignature = signature
            consecutiveRetryCount = 1
        }

        if AchievementTriggerEvaluator.shouldUnlockSchrodingerQuestion(consecutiveRetryCount: consecutiveRetryCount) {
            scheduleAchievementUnlockIfNeeded(.schrodingerQuestion)
        }
    }

    func resetConsecutiveRetryTracking() {
        consecutiveRetrySignature = nil
        consecutiveRetryCount = 0
    }
}
