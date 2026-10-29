// ============================================================================
// ChatServiceMessageSending.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的用户消息发送入口、附件落盘、临时会话转正与请求任务启动。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public func sendAndProcessMessage(
        content: String,
        aiTemperature: Double,
        aiTopP: Double,
        maxChatHistory: Int,
        enableStreaming: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true,
        audioAttachment: AudioAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        fileAttachments: [FileAttachment] = [],
        isRetry: Bool = false,
        targetSessionID: UUID? = nil,
        messageAuthorKind: ConversationMessageAuthorKind = .user,
        sourceSessionID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        conversationEventID: UUID? = nil,
        conversationRun: ConversationRun? = nil,
        existingInputMessageID: UUID? = nil,
        requestedLocalAgentMode: LocalAgentMode? = nil,
        onMessagesPrepared: ChatSendPresentationHandler? = nil,
        requestLease: ChatRequestLease? = nil,
        onInputAccepted: ChatInputAcceptanceHandler? = nil
    ) async {

        let resolvedTargetSessionID = targetSessionID ?? currentSessionSubject.value?.id
        let currentSessionSnapshot = currentSessionSubject.value
        guard let resolvedTargetSessionID,
              var currentSession = currentSessionSnapshot?.id == resolvedTargetSessionID
                ? currentSessionSnapshot
                : conversationSession(withID: resolvedTargetSessionID) else {
            addErrorMessage(
                NSLocalizedString("错误: 没有目标会话。", comment: "No target session error"),
                sessionID: resolvedTargetSessionID
            )
            requestStatusSubject.send(.error)
            return
        }

        let lease: ChatRequestLease
        if let requestLease {
            guard requestLease.sessionID == currentSession.id,
                  ownsRequestReservation(sessionID: currentSession.id, token: requestLease.token) else { return }
            lease = requestLease
        } else {
            switch beginRequest(sessionID: currentSession.id) {
            case .success(let acquired): lease = acquired
            case .failure: return
            }
        }
        guard lease.claim(for: self) else { return }
        var acceptedGroup: [ChatMessage] = []
        var inputStillRetained = false
        var requestTaskRegistered = false
        defer {
            if !requestTaskRegistered, !acceptedGroup.isEmpty,
               Task.isCancelled || !ownsRequestReservation(sessionID: currentSession.id, token: lease.token) {
                if rollbackUnsentInput(acceptedGroup, sessionID: currentSession.id, token: lease.token, sourceRetained: inputStillRetained) {
                    lease.setInputAccepted(false)
                } else if runtimeMessagesSnapshot(for: currentSession.id) == nil {
                    lease.setInputAccepted(false)
                } else {
                    reportRetainedStoppedInput(sessionID: currentSession.id, token: lease.token)
                }
            }
            lease.finishPreparation()
        }

        // 新增后台等待前固定目标与模型；输入准备期间切换界面不能改写本轮路由。
        let runConfiguredModelIdentifier = conversationRun?.requestConfiguration.modelIdentifier
        let runConfiguredModel = runConfiguredModelIdentifier.flatMap { identifier in
            activatedConversationModels.first(where: { $0.id == identifier })
        }
        let selectedModel = runConfiguredModel ?? currentSession.preferredModelIdentifier.flatMap { identifier in
            activatedConversationModels.first(where: { $0.id == identifier })
        } ?? selectedModelSubject.value
        let preparationSessionID = currentSession.id
        let preparedMode = await Task.detached(priority: .userInitiated) { () -> LocalAgentMode? in
            if let requestedLocalAgentMode {
                // 明确选择仍为本次发送的权威值；未指定时在后台读取持久化模式。
                guard Persistence.saveLocalAgentMode(requestedLocalAgentMode, sessionID: preparationSessionID) else {
                    return nil
                }
                return requestedLocalAgentMode
            }
            return Persistence.localAgentMode(sessionID: preparationSessionID)
        }.value
        guard let effectiveLocalAgentMode = preparedMode else {
            addErrorMessage(
                NSLocalizedString("错误: 无法保存会话模式。", comment: "Unable to persist requested session mode"),
                sessionID: currentSession.id
            )
            requestStatusSubject.send(.error)
            return
        }

        if !isRetry {
            resetConsecutiveRetryTracking()
        }

        // 只有图像类型模型进入独立生图通道，聊天模型的图片输出由对话响应处理。
        // 已排队的 Run 必须使用入队时固化的模型；用户后来切换全局模型不能污染它。
        if let conversationRun, runConfiguredModelIdentifier != nil, runConfiguredModel == nil {
            let reason = NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            return
        }
        if let selectedModel,
           shouldRouteMessageToImageGeneration(using: selectedModel) {
            if audioAttachment != nil {
                let reason = NSLocalizedString("生图模式不支持语音附件。", comment: "Image mode does not support audio attachments")
                addErrorMessage(reason, sessionID: currentSession.id)
                requestStatusSubject.send(.error)
                return
            }
            if !fileAttachments.isEmpty {
                let reason = NSLocalizedString("生图模式仅支持文本提示词和图片参考图。", comment: "Image mode only supports text prompt and reference images")
                addErrorMessage(reason, sessionID: currentSession.id)
                requestStatusSubject.send(.error)
                return
            }

            await ChatRequestTaskIdentity.$current.withValue(.init(sessionID: currentSession.id, token: lease.token)) {
                await generateImageAndProcessMessage(
                    prompt: content,
                    imageAttachments: imageAttachments,
                    runnableModel: selectedModel,
                    targetSessionID: currentSession.id,
                    onMessagesPrepared: onMessagesPrepared,
                    requestLease: lease,
                    onInputAccepted: onInputAccepted
                )
            }
            return
        }

        // 准备用户消息和UI占位消息
        let audioPlaceholder = NSLocalizedString("[语音消息]", comment: "Audio message placeholder")
        let imagePlaceholder = NSLocalizedString("[图片]", comment: "Image message placeholder")
        let filePlaceholder = NSLocalizedString("[文件]", comment: "File message placeholder")
        let videoPlaceholder = NSLocalizedString("[视频]", comment: "Video message placeholder")
        // async 默认可能继承 UI actor，必须显式离开它执行规则和附件 I/O。
        // 准备期沿用原有不可取消语义，等待全部结果后才提交身份与服务状态。
        let preparedInput = await Task.detached(priority: .userInitiated) {
            ChatSendMessagePreparation.prepare(
                content: content, audioAttachment: audioAttachment,
                imageAttachments: imageAttachments, fileAttachments: fileAttachments,
                placeholders: (audioPlaceholder, imagePlaceholder, filePlaceholder, videoPlaceholder),
                authorKind: messageAuthorKind, sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID, conversationEventID: conversationEventID
            )
        }.value
        guard !Task.isCancelled,
              ownsRequestReservation(sessionID: currentSession.id, token: lease.token) else { return }
        guard preparedInput.failures.isEmpty else {
            addErrorMessage(NSLocalizedString("内容准备失败，请检查附件后重试。", comment: "Input attachment preparation failed"), sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            return
        }
        let messageContent = preparedInput.content
        let requestTimestamp = preparedInput.requestedAt
        let savedImageFileNames = preparedInput.imageFileNames
        let messageIDsBySource = preparedInput.messageIDsBySource
        var userMessages = preparedInput.messages
        var primaryUserMessage = preparedInput.primaryMessage

        if let existingInputMessageID {
            let existingMessages = messagesSnapshot(for: currentSession.id)
            guard let existingMessage = existingMessages.first(where: {
                $0.id == existingInputMessageID && $0.role == .user
            }) else {
                addErrorMessage(
                    NSLocalizedString("错误: 未找到待处理的会话输入。", comment: "Missing queued conversation input"),
                    sessionID: currentSession.id
                )
                requestStatusSubject.send(.error)
                return
            }
            // steering 输入的文本和附件共用同一事件 ID，延后执行时也必须保留整个原子消息序列。
            if let eventID = existingMessage.conversationEventID {
                let eventMessages = existingMessages.filter {
                    $0.role == .user && $0.conversationEventID == eventID
                }
                userMessages = eventMessages.isEmpty ? [existingMessage] : eventMessages
            } else {
                userMessages = [existingMessage]
            }
            primaryUserMessage = existingMessage
        }

        // 兜底：如果没有生成任何用户消息，直接报错返回
        guard !userMessages.isEmpty else {
            addErrorMessage(
                NSLocalizedString("错误: 待发送消息为空。", comment: "Empty message error"),
                sessionID: currentSession.id
            )
            requestStatusSubject.send(.error)
            return
        }

        // 用于命名会话/记忆检索的代表消息：优先用户正文，其次第一条附件消息。
        if primaryUserMessage == nil {
            primaryUserMessage = userMessages.first
        }

        if let onMessagesPrepared, existingInputMessageID == nil,
           let responseMessage = userMessages.last {
            // 发布第一条附件之前就交出整组身份，UI 不必靠正文、时间或追加顺序猜测。
            await onMessagesPrepared(ChatSendPresentation(
                sessionID: currentSession.id,
                messageIDsBySource: messageIDsBySource,
                responseGroupID: responseMessage.id
            ))
        }

        let responseAttempt = ResponseAttemptMetadata(
            groupID: userMessages[userMessages.index(before: userMessages.endIndex)].id,
            attemptID: UUID(),
            attemptIndex: 0
        )
        if let anchorUserIndex = userMessages.indices.last {
            userMessages[anchorUserIndex].selectedResponseAttemptID = responseAttempt.attemptID
            if primaryUserMessage?.id == userMessages[anchorUserIndex].id {
                primaryUserMessage = userMessages[anchorUserIndex]
            }
        }
        let previousAssistantReply = latestAssistantReply(in: currentSession.id)
        let loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: requestTimestamp,
            responseGroupID: responseAttempt.groupID,
            responseAttemptID: responseAttempt.attemptID,
            responseAttemptIndex: responseAttempt.attemptIndex,
            selectedResponseAttemptID: responseAttempt.attemptID
        ) // 内容为空的助手消息作为加载占位符
        var wasTemporarySession = false

        do {
            try appendConversationMessagesAtomically(
                existingInputMessageID == nil ? userMessages + [loadingMessage] : [loadingMessage],
                to: currentSession.id, requestToken: lease.token
            )
        } catch is CancellationError {
            return
        } catch {
            addErrorMessage(error.localizedDescription, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            return
        }
        acceptedGroup = existingInputMessageID == nil ? userMessages + [loadingMessage] : [loadingMessage]
        lease.setInputAccepted(true)
        if let onInputAccepted, existingInputMessageID == nil, let responseMessage = userMessages.last {
            let cancelled = Task.isCancelled || !ownsRequestReservation(sessionID: currentSession.id, token: lease.token)
            inputStillRetained = await onInputAccepted(ChatSendPresentation(sessionID: currentSession.id,
                messageIDsBySource: messageIDsBySource, responseGroupID: responseMessage.id), cancelled)
        }
        guard !Task.isCancelled,
              ownsRequestReservation(sessionID: currentSession.id, token: lease.token) else { return }
        let messages = messagesSnapshot(for: currentSession.id)
        scheduleUserMessageAchievementDetectionIfNeeded(
            content: messageContent,
            userMessageCount: messages.filter { $0.role == .user }.count,
            sentAt: requestTimestamp,
            previousAssistantReply: previousAssistantReply
        )

        // 注意：当音频作为附件直接发送给模型时，不再需要后台转文字
        // 因为每次发送消息都会重新加载音频文件并以 base64 发送
        // UI 上通过 audioFileName 属性标识这是一条语音消息

        // 处理临时会话的转换
        if currentSession.isTemporary,
           !isTemporaryChatEnabled(for: currentSession.id),
           let sessionTitleSource = primaryUserMessage {
            wasTemporarySession = true // 标记此为首次交互
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            currentSession.isTemporary = false
            if currentSessionSubject.value?.id == currentSession.id {
                currentSessionSubject.send(currentSession)
            }
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) { updatedSessions[index] = currentSession }
            chatSessionsSubject.send(updatedSessions)
            logger.info("临时会话已转为永久会话: \(currentSession.name)")

            // 用户发送第一条消息时，立即异步生成标题（无需等待AI响应）
            let trimmedTitleSource = sessionTitleSource.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholderTitle = trimmedTitleSource == audioPlaceholder
                || trimmedTitleSource == imagePlaceholder
                || trimmedTitleSource == filePlaceholder
                || trimmedTitleSource == videoPlaceholder
            if !trimmedTitleSource.isEmpty && !isPlaceholderTitle {
                let sessionIDForTitle = currentSession.id
                let userMessageForTitle = sessionTitleSource
                Task {
                    await self.generateAndApplySessionTitle(for: sessionIDForTitle, firstUserMessage: userMessageForTitle)
                }
            } else {
                logger.info("跳过自动标题生成：首条消息为空或仅包含附件占位。")
            }
        } else if !currentSession.isTemporary {
            // 老会话重新收到消息时，将其排到列表顶部
            await promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        } else if let sessionTitleSource = primaryUserMessage,
                  currentSession.name == NSLocalizedString("新的对话", comment: "Default new chat session name") {
            currentSession.name = String(sessionTitleSource.content.prefix(20))
            if currentSessionSubject.value?.id == currentSession.id {
                currentSessionSubject.send(currentSession)
            }
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) {
                updatedSessions[index] = currentSession
                chatSessionsSubject.send(updatedSessions)
            }
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)

        let agentCapabilities = AgentToolCapabilityPolicy.resolve(
            mode: effectiveLocalAgentMode,
            isToolContextIsolated: currentSession.isToolContextIsolationActive,
            localLinuxEnabled: AppConfigStore.boolValue(for: .localLinuxEnabled)
        )
        let shouldPrepareAgentRun = agentCapabilities.preparesAgentRun
        let includeLocalLinuxCapability = agentCapabilities.includesLocalLinuxTools
        let requestConfiguration = ConversationRunRequestConfiguration(
            modelIdentifier: selectedModel?.id,
            temperature: aiTemperature,
            topP: aiTopP,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            includeSystemTime: includeSystemTime,
            systemTimeInjectionPosition: systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
            enableResponseSpeedMetrics: enableResponseSpeedMetrics,
            browserDataProfile: Persistence.browserAgentDataProfile(sessionID: currentSession.id),
            agentToolsEnabled: shouldPrepareAgentRun,
            localLinuxToolsEnabled: includeLocalLinuxCapability
        )
        var runtimeRun = conversationRun ?? ConversationRun(
            sessionID: currentSession.id,
            requestConfiguration: requestConfiguration
        )
        runtimeRun.status = .running
        runtimeRun.startedAt = runtimeRun.startedAt ?? Date()
        runtimeRun.requestConfiguration = requestConfiguration
        runtimeRun.loadingMessageID = loadingMessage.id
        let runtimeRunID = runtimeRun.id
        let rootRuntimeRunID = runtimeRun.rootRunID
        let parentRuntimeRunID = runtimeRun.parentRunID

        let requestToken = lease.token
        guard updateReservedRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: nil,
                conversationRunID: runtimeRun.id,
                rootConversationRunID: runtimeRun.rootRunID,
                requestConfiguration: requestConfiguration,
                taskRegistrationPending: true
            ),
            for: currentSession.id
        ) else { return }

        let startGate = ChatRequestStartGate()
        let requestTask = Task<Void, Error> { [weak self] in
            try await startGate.waitUntilRegistered()
            guard let self else { return }
            try await ChatRequestTaskIdentity.$current.withValue(.init(sessionID: currentSession.id, token: requestToken)) {
                var localAgentContext: AgentRuntimeContext?
                if includeLocalLinuxCapability {
                    do {
                        let prepared = try await LocalAgentRuntimeContextManager.shared.beginRun(
                            sessionID: currentSession.id,
                            triggeringMessageID: responseAttempt.groupID,
                            runID: runtimeRunID,
                            rootRunID: rootRuntimeRunID,
                            parentRunID: parentRuntimeRunID,
                            browserSessionID: currentSession.id,
                            requestedMode: effectiveLocalAgentMode
                        )
                        localAgentContext = prepared.context
                        _ = try await LocalLinuxRuntimeController.shared.ensureReady(trigger: .agentRequest)
                        try Task.checkCancellation()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await LocalAgentRuntimeContextManager.shared.finishRun(
                            id: runtimeRunID,
                            state: .failed
                        )
                        self.addErrorMessage(
                            String(
                                format: NSLocalizedString("错误: 无法准备 Agent Run：%@", comment: "Prepare local Agent run failure"),
                                error.localizedDescription
                            ),
                            sessionID: currentSession.id
                        )
                        self.emitSessionRequestStatus(.error, sessionID: currentSession.id)
                        return
                    }
                }
                let requestTooling = await self.resolveRequestTooling(
                    for: currentSession,
                    localAgentContext: localAgentContext
                )
                await self.executeMessageRequest(
                    messages: messages,
                    loadingMessageID: loadingMessage.id,
                    currentSessionID: currentSession.id,
                    userMessage: primaryUserMessage,
                    wasTemporarySession: wasTemporarySession,
                    aiTemperature: aiTemperature,
                    aiTopP: aiTopP,
                    maxChatHistory: maxChatHistory,
                    enableStreaming: enableStreaming,
                    tools: requestTooling.tools,
                    includeSystemTime: includeSystemTime,
                    systemTimeInjectionPosition: systemTimeInjectionPosition,
                    enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                    periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                    enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                    currentAudioAttachment: audioAttachment,
                    currentImageAttachments: imageAttachments.filter {
                        savedImageFileNames.contains($0.fileName)
                    },
                    currentFileAttachments: fileAttachments
                )
            }
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken, startGate: startGate)
        requestTaskRegistered = true

        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }

        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("请求已被用户取消，将等待后续动作。")
        } catch {
            // URLError.cancelled 不会匹配 CancellationError，需要单独检测
            if isCancellationError(error) {
                logger.info("请求已被用户取消 (URLError)，将等待后续动作。")
            } else {
                logger.error("请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }

    private func encodeConversationToolResult<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let result = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return result
    }
}
