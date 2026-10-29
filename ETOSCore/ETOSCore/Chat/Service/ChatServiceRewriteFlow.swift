// ============================================================================
// ChatServiceRewriteFlow.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的单条助手回复重写请求与版本写回。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public enum MessageRewriteError: LocalizedError {
        case unavailable
        case currentSessionMissing
        case messageNotFound
        case unsupportedMessageRole
        case emptyInstruction
        case emptyOriginalContent
        case emptyRewriteResult
        case selectionOutdated

        public var errorDescription: String? {
            switch self {
            case .unavailable:
                return NSLocalizedString("此功能暂不可用。", comment: "Legacy message rewrite unavailable")
            case .currentSessionMissing:
                return NSLocalizedString("当前没有可用会话，无法重写消息。", comment: "Rewrite message error")
            case .messageNotFound:
                return NSLocalizedString("找不到要重写的消息。", comment: "Rewrite message error")
            case .unsupportedMessageRole:
                return NSLocalizedString("只能重写 AI 回复。", comment: "Rewrite message error")
            case .emptyInstruction:
                return NSLocalizedString("请填写重写要求。", comment: "Rewrite message error")
            case .emptyOriginalContent:
                return NSLocalizedString("这条回复没有可重写的正文。", comment: "Rewrite message error")
            case .emptyRewriteResult:
                return NSLocalizedString("AI 返回了空内容，请调整重写要求后重试。", comment: "Rewrite message error")
            case .selectionOutdated:
                return NSLocalizedString("原回复已发生变化，请重新选择要重写的文字。", comment: "Partial rewrite stale selection error")
            }
        }
    }

    public func rewriteMessage(
        _ message: ChatMessage,
        instruction: String,
        aiTemperature: Double,
        sessionID: UUID? = nil,
        referenceVersions: [MessageRewriteReferenceVersion] = [],
        selectionTarget: MessageRewriteSelectionTarget? = nil,
        runnableModel: RunnableModel? = nil,
        expectedMessage: ChatMessage? = nil,
        requestLease: ChatRequestLease? = nil
    ) async throws {
        throw MessageRewriteError.unavailable
    }

    private func generateRewriteContent(
        originalContent: String,
        instruction: String,
        referenceVersions: [MessageRewriteReferenceVersion],
        aiTemperature: Double,
        sessionID: UUID,
        runnableModel: RunnableModel?
    ) async throws -> String {
        let systemPrompt = BuiltInPromptStore.render(.messageRewriteSystem)
        let userPrompt: String
        let referenceVersionBlock = makeReferenceVersionPromptBlock(referenceVersions)
        if referenceVersionBlock.isEmpty {
            userPrompt = BuiltInPromptStore.render(
                .messageRewriteUser,
                variables: [
                    "instruction": markdownSeparatedContent(instruction),
                    "original": originalContent
                ]
            )
        } else {
            userPrompt = BuiltInPromptStore.render(
                .messageRewriteUserWithReferences,
                variables: [
                    "instruction": markdownSeparatedContent(instruction),
                    "reference_versions": markdownSeparatedContent(referenceVersionBlock),
                    "original": originalContent
                ]
            )
        }

        return try await generateDetachedChatCompletion(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: aiTemperature,
            runnableModel: runnableModel,
            requestSource: .messageRewrite,
            sessionID: sessionID
        )
    }

    private func generatePartialRewriteReplacement(
        originalContent: String,
        selectionTarget: MessageRewriteSelectionTarget,
        instruction: String,
        aiTemperature: Double,
        sessionID: UUID,
        runnableModel: RunnableModel?
    ) async throws -> String {
        let systemPrompt = BuiltInPromptStore.render(.messagePartialRewriteSystem)
        let userPrompt = BuiltInPromptStore.render(
            .messagePartialRewriteUser,
            variables: [
                "instruction": instruction,
                "selection": selectionTarget.sourceText,
                "original": originalContent
            ]
        )

        return try await generateDetachedChatCompletion(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: aiTemperature,
            runnableModel: runnableModel,
            requestSource: .messageRewrite,
            sessionID: sessionID
        )
    }

    private func markdownSeparatedContent(_ content: String) -> String {
        "\(content)\n\n---"
    }

    private func makeReferenceVersionPromptBlock(
        _ referenceVersions: [MessageRewriteReferenceVersion]
    ) -> String {
        referenceVersions
            .sorted { $0.versionNumber < $1.versionNumber }
            .map { version in
                String(
                    format: NSLocalizedString("版本 %d：\n%@", comment: "Message rewrite reference version prompt item"),
                    version.versionNumber,
                    version.content
                )
            }
            .joined(separator: "\n\n")
    }

    private func prepareRewriteAttemptMetadata(
        in messages: inout [ChatMessage],
        targetIndex: Int
    ) -> ResponseAttemptMetadata {
        if let groupID = messages[targetIndex].responseGroupID {
            return prepareRewriteAttemptMetadataForExistingGroup(
                groupID: groupID,
                in: &messages
            )
        }

        let groupID = previousUserMessageID(before: targetIndex, in: messages) ?? messages[targetIndex].id
        let legacyAttemptID = UUID()
        messages[targetIndex].responseGroupID = groupID
        messages[targetIndex].responseAttemptID = legacyAttemptID
        messages[targetIndex].responseAttemptIndex = 0
        messages[targetIndex].selectedResponseAttemptID = legacyAttemptID
        if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            messages[anchorIndex].selectedResponseAttemptID = legacyAttemptID
        }

        return ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: 1
        )
    }

    private func prepareRewriteAttemptMetadataForExistingGroup(
        groupID: UUID,
        in messages: inout [ChatMessage]
    ) -> ResponseAttemptMetadata {
        let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)
        let nextAttemptIndex = messages
            .filter { $0.responseGroupID == groupID }
            .compactMap(\.responseAttemptIndex)
            .max()
            .map { $0 + 1 } ?? attempts.count
        let newAttempt = ResponseAttemptMetadata(
            groupID: groupID,
            attemptID: UUID(),
            attemptIndex: nextAttemptIndex
        )
        if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            messages[anchorIndex].selectedResponseAttemptID = newAttempt.attemptID
        }
        for index in messages.indices where messages[index].responseGroupID == groupID {
            messages[index].selectedResponseAttemptID = newAttempt.attemptID
        }
        return newAttempt
    }

    private func previousUserMessageID(before targetIndex: Int, in messages: [ChatMessage]) -> UUID? {
        guard targetIndex > messages.startIndex else { return nil }
        return messages[..<targetIndex].last(where: { $0.role == .user })?.id
    }

    private func rewriteInsertionIndex(
        in messages: [ChatMessage],
        targetIndex: Int,
        attemptID: UUID?
    ) -> Int {
        if let attemptID,
           let lastAttemptIndex = messages.lastIndex(where: { $0.responseAttemptID == attemptID }) {
            return messages.index(after: lastAttemptIndex)
        }
        return messages.index(after: targetIndex)
    }

    private func applyRewriteResult(
        _ rewrittenMessage: ChatMessage,
        loadingMessageID: UUID,
        sessionID: UUID
    ) async {
        let messageRegexRules = MessageRegexRuleStore.currentRules()
        let rewrittenMessage = messageRegexRules.isEmpty
            ? rewrittenMessage
            : applyMessageRegexRules(to: rewrittenMessage, rules: messageRegexRules, mode: .persist)
        let updated = await updateExistingConversationMessage(
            id: loadingMessageID, in: sessionID, requiresRequestIdentity: true
        ) { existingMessage in
            existingMessage = ChatMessage(
                id: loadingMessageID,
                role: .assistant,
                content: rewrittenMessage.content,
                requestedAt: existingMessage.requestedAt ?? rewrittenMessage.requestedAt,
                reasoningContent: nil,
                reasoningProviderSpecificFields: nil,
                toolCalls: nil,
                toolCallsPlacement: nil,
                tokenUsage: rewrittenMessage.tokenUsage ?? existingMessage.tokenUsage,
                modelReference: rewrittenMessage.modelReference ?? existingMessage.modelReference,
                costEstimate: rewrittenMessage.costEstimate ?? existingMessage.costEstimate,
                sentSystemPromptSnapshot: existingMessage.sentSystemPromptSnapshot,
                responseMetrics: rewrittenMessage.responseMetrics ?? existingMessage.responseMetrics,
                responseGroupID: rewrittenMessage.responseGroupID,
                responseAttemptID: rewrittenMessage.responseAttemptID,
                responseAttemptIndex: rewrittenMessage.responseAttemptIndex,
                selectedResponseAttemptID: rewrittenMessage.selectedResponseAttemptID
            )
            return true
        }
        guard updated else { return }
        logger.info("已完成消息重写并保存为新版本: \(loadingMessageID.uuidString)")
    }
}
