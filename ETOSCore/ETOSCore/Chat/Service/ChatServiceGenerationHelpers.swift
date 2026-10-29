// ============================================================================
// ChatServiceGenerationHelpers.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的独立推理、会话标题、快捷指令描述与记忆摘要辅助生成。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    func scheduleReasoningSummaryIfNeeded(for messageID: UUID, in sessionID: UUID) {
        guard isReasoningSummaryEnabled() else { return }

        let messages = messagesSnapshot(for: sessionID)
        guard let message = messages.first(where: { $0.id == messageID }),
              message.role == .assistant else {
            return
        }

        let reasoning = (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoning.isEmpty else { return }

        let existingSummary = message.responseMetrics?.reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existingSummary.isEmpty else { return }

        Task { [weak self] in
            await self?.performReasoningSummaryIfNeeded(
                for: messageID,
                in: sessionID,
                reasoning: reasoning
            )
        }
    }

    private func performReasoningSummaryIfNeeded(for messageID: UUID, in sessionID: UUID, reasoning: String) async {
        guard let runnableModel = resolvedReasoningSummaryModel() else { return }

        let summarySystemPrompt = BuiltInPromptStore.render(.reasoningSummarySystem)
        let summaryUserPrompt = BuiltInPromptStore.render(
            .reasoningSummaryUser,
            variables: ["reasoning": reasoning]
        )

        do {
            let rawSummary = try await generateDetachedChatCompletion(
                systemPrompt: summarySystemPrompt,
                userPrompt: summaryUserPrompt,
                temperature: 0.2,
                runnableModel: runnableModel,
                requestSource: .reasoningSummary,
                sessionID: sessionID
            )
            let summary = sanitizeReasoningSummaryText(rawSummary)
            guard !summary.isEmpty else { return }
            await applyReasoningSummary(summary, for: messageID, in: sessionID, expectedReasoning: reasoning)
        } catch {
            logger.warning("异步思考摘要生成失败: \(error.localizedDescription)")
        }
    }

    private func sanitizeReasoningSummaryText(_ rawSummary: String, maxLength: Int = 24) -> String {
        let normalized = normalizeEscapedNewlinesIfNeeded(rawSummary)
        let singleLine = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !singleLine.isEmpty else { return "" }

        let prefixes = ["思考摘要：", "思考摘要:", "摘要：", "摘要:", "总结：", "总结:"]
        let trimmedPrefix = prefixes.first(where: { singleLine.hasPrefix($0) }).map {
            String(singleLine.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? singleLine

        guard !trimmedPrefix.isEmpty else { return "" }
        if trimmedPrefix.count <= maxLength {
            return trimmedPrefix
        }
        return String(trimmedPrefix.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyReasoningSummary(_ summary: String, for messageID: UUID, in sessionID: UUID, expectedReasoning: String) async {
        await updateExistingConversationMessage(id: messageID, in: sessionID) { message in
            let currentReasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard currentReasoning == expectedReasoning else { return false }
            var metrics = message.responseMetrics ?? MessageResponseMetrics()
            guard metrics.reasoningSummary != summary else { return false }
            metrics.reasoningSummary = summary
            message.responseMetrics = metrics
            return true
        }
    }

    private func escapeXMLText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public func generateShortcutToolDescription(
        toolName: String,
        metadata: [String: JSONValue],
        source: String?
    ) async -> String? {
        guard let runnableModel = resolvedChatCapableModel() else {
            return nil
        }

        let metadataText: String = {
            guard !metadata.isEmpty else { return "{}" }
            return JSONValue.dictionary(metadata).prettyPrintedCompact()
        }()

        let sourceText = source?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : NSLocalizedString("无", comment: "")

        let prompt = BuiltInPromptStore.render(
            .shortcutDescription,
            variables: [
                "shortcut_name": escapeXMLText(toolName),
                "metadata": escapeXMLText(metadataText),
                "source_summary": escapeXMLText(sourceText)
            ]
        )

        do {
            let rawDescription = try await generateDetachedChatCompletion(
                userPrompt: prompt,
                temperature: 0.2,
                runnableModel: runnableModel,
                requestSource: .shortcutDescription
            )
            let text = rawDescription
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’"))
            return text.isEmpty ? nil : text
        } catch {
            logger.warning("生成快捷指令描述失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 执行一次不落入聊天历史的独立推理请求，适合标题生成、每日摘要等辅助功能。
    public func generateDetachedChatCompletion(
        systemPrompt: String? = nil,
        userPrompt: String,
        temperature: Double = 0.4,
        runnableModel: RunnableModel? = nil,
        requestSource: UsageRequestSource,
        sessionID: UUID? = nil,
        responseValidator: (@Sendable (String) throws -> Void)? = nil
    ) async throws -> String {
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserPrompt.isEmpty else { return "" }

        var requestMessages: [ChatMessage] = []
        if let systemPrompt {
            let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSystemPrompt.isEmpty {
                requestMessages.append(ChatMessage(
                    role: .system,
                    content: trimmedSystemPrompt
                ))
            }
        }
        requestMessages.append(ChatMessage(role: .user, content: trimmedUserPrompt))

        return try await generateDetachedChatCompletion(
            messages: requestMessages,
            temperature: temperature,
            runnableModel: runnableModel,
            requestSource: requestSource,
            sessionID: sessionID,
            responseValidator: responseValidator
        )
    }

    /// 执行保留消息角色与顺序的独立推理请求，不写入主聊天历史。
    public func generateDetachedChatCompletion(
        messages: [ChatMessage],
        temperature: Double = 0.4,
        runnableModel: RunnableModel? = nil,
        requestSource: UsageRequestSource,
        sessionID: UUID? = nil,
        audioAttachments: [UUID: AudioAttachment] = [:],
        imageAttachments: [UUID: [ImageAttachment]] = [:],
        fileAttachments: [UUID: [FileAttachment]] = [:],
        responseValidator: (@Sendable (String) throws -> Void)? = nil
    ) async throws -> String {
        let requestMessages = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !requestMessages.isEmpty else { return "" }
        guard let targetModel = runnableModel ?? detachedChatCompletionFallbackModel() else {
            throw DetachedCompletionError.noAvailableModel
        }

        let requestContext = RequestLogContext(
            requestID: UUID(),
            sessionID: sessionID,
            providerID: targetModel.provider.id,
            providerName: targetModel.provider.name,
            modelID: targetModel.model.modelName,
            requestSource: requestSource,
            isStreaming: false,
            requestedAt: Date()
        )

        guard let adapter = adapters[targetModel.effectiveAPIFormat] else {
            throw DetachedCompletionError.unsupportedAdapter
        }

        var preparedFileAttachments = fileAttachments
        var selectedGeminiAPIKey: String?
        if let geminiAdapter = (adapter as? GeminiAdapter) ?? (adapter as? GeminiInteractionsAdapter)?.geminiAdapter {
            let preparation = try await prepareGeminiNativeVideoAttachments(
                fileAttachments,
                provider: targetModel.provider,
                adapter: geminiAdapter
            )
            preparedFileAttachments = preparation.attachments
            selectedGeminiAPIKey = preparation.apiKey
        }

        let payload: [String: Any] = [
            "temperature": temperature,
            "stream": false
        ]
        var commonPayload = payload
        commonPayload[ReasoningContentEchoPayload.key] = await openAIReasoningContentEchoModeControlValue()
        if let selectedGeminiAPIKey {
            commonPayload[GeminiAdapter.apiKeyControlKey] = selectedGeminiAPIKey
        }
        guard let request = adapter.buildChatRequest(
            for: targetModel,
            commonPayload: commonPayload,
            messages: requestMessages,
            tools: nil,
            audioAttachments: audioAttachments,
            imageAttachments: imageAttachments,
            fileAttachments: preparedFileAttachments
        ) else {
            throw DetachedCompletionError.buildRequestFailed
        }

        var didPersistTerminalStatus = false
        do {
            let data = try await fetchData(for: request, provider: targetModel.provider)
            let responseMessage: ChatMessage
            do {
                responseMessage = try adapter.parseResponse(data: data)
            } catch {
                didPersistTerminalStatus = true
                persistRequestLog(
                    context: requestContext,
                    status: .failed,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "parse_response_failed"
                )
                throw error
            }

            let content = responseMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try responseValidator?(content)
            } catch {
                didPersistTerminalStatus = true
                persistRequestLog(
                    context: requestContext,
                    status: .failed,
                    tokenUsage: responseMessage.tokenUsage,
                    finishedAt: Date(),
                    errorKind: "response_validation_failed"
                )
                throw error
            }

            didPersistTerminalStatus = true
            persistRequestLog(
                context: requestContext,
                status: .success,
                tokenUsage: responseMessage.tokenUsage,
                finishedAt: Date()
            )
            return content
        } catch is CancellationError {
            if !didPersistTerminalStatus {
                persistRequestLog(
                    context: requestContext,
                    status: .cancelled,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: "cancelled"
                )
            }
            throw CancellationError()
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            if !didPersistTerminalStatus {
                persistRequestLog(
                    context: requestContext,
                    status: .failed,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    httpStatusCode: code,
                    errorKind: "bad_status_code"
                )
            }
            throw NetworkError.badStatusCode(code: code, responseBody: bodyData)
        } catch {
            let errorKind = isCancellationError(error) ? "cancelled" : "network_error"
            let status: RequestLogStatus = isCancellationError(error) ? .cancelled : .failed
            if !didPersistTerminalStatus {
                persistRequestLog(
                    context: requestContext,
                    status: status,
                    tokenUsage: nil,
                    finishedAt: Date(),
                    errorKind: errorKind
                )
            }
            throw error
        }
    }

    func detachedChatCompletionFallbackModel() -> RunnableModel? {
        selectedModelSubject.value?.model.isChatModel == true
            ? selectedModelSubject.value
            : activatedChatModels.first
    }

    func generateAndApplySessionTitle(for sessionID: UUID, firstUserMessage: ChatMessage) async {
        let isAutoNamingEnabled = await MainActor.run {
            AppConfigStore.shared.enableAutoSessionNaming
        }
        guard isAutoNamingEnabled else {
            logger.info("自动标题功能已禁用，跳过生成。")
            return
        }

        let dedicatedModelIdentifier = Persistence.readAppConfigText(key: AppConfigKey.titleGenerationModelIdentifier.rawValue) ?? ""
        guard let runnableModel = resolveTitleGenerationModel() else {
            logger.error("无法获取标题模型，无法生成标题。")
            return
        }
        let usingDedicatedTitleModel = !dedicatedModelIdentifier.isEmpty && dedicatedModelIdentifier == runnableModel.id

        logger.info(
            "开始为会话 \(sessionID.uuidString) 生成标题，使用\(usingDedicatedTitleModel ? "独立标题模型" : "当前对话模型"): \(runnableModel.model.displayName, privacy: .public)"
        )

        let titlePrompt = BuiltInPromptStore.render(
            .sessionTitle,
            variables: ["question": firstUserMessage.content]
        )

        do {
            let rawTitle = try await generateDetachedChatCompletion(
                userPrompt: titlePrompt,
                temperature: 0.5,
                runnableModel: runnableModel,
                requestSource: .sessionTitle,
                sessionID: sessionID
            )

            let newTitle = rawTitle
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’"))

            guard !newTitle.isEmpty else {
                logger.warning("AI返回的标题为空。")
                return
            }

            var currentSessions = chatSessionsSubject.value
            if let index = currentSessions.firstIndex(where: { $0.id == sessionID }) {
                currentSessions[index].name = newTitle

                if var currentSession = currentSessionSubject.value, currentSession.id == sessionID {
                    currentSession.name = newTitle
                    currentSessionSubject.send(currentSession)
                }

                chatSessionsSubject.send(currentSessions)
                logger.info("成功生成并应用新标题: '\(newTitle)'")
            }
        } catch {
            logger.error("生成会话标题时发生网络或解析错误: \(error.localizedDescription)")
        }
    }

    private func resolveTitleGenerationModel() -> RunnableModel? {
        let dedicatedModelIdentifier = Persistence.readAppConfigText(key: AppConfigKey.titleGenerationModelIdentifier.rawValue) ?? ""
        if !dedicatedModelIdentifier.isEmpty,
           let dedicatedModel = activatedChatModels.first(
                where: { $0.id == dedicatedModelIdentifier && $0.model.isChatModel }
           ) {
            return dedicatedModel
        }
        if let selectedModel = selectedModelSubject.value,
           selectedModel.model.isChatModel {
            return selectedModel
        }
        return activatedChatModels.first
    }
}
