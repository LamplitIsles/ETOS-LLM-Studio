// ============================================================================
// ChatViewModelSessionManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatViewModel 中会话、文件夹、消息编辑、重试与消息版本管理。
// ============================================================================

import Foundation
import Combine
import ETOSCore
import os.log

extension ChatViewModel {
    func deleteMessage(_ message: ChatMessage) {
        chatService.deleteMessage(message)
    }

    /// 正文与图片附件是同一条记录中的独立展示部分；有图片时只清正文气泡。
    func deleteTextBubbleOrMessage(_ message: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let sessionID = currentSession?.id {
                await chatService.cancelRequestIfGenerating(
                    messageID: message.id,
                    in: sessionID
                )
            }
            guard let currentMessage = findMessage(by: message.id) else { return }
            guard !(currentMessage.imageFileNames ?? []).isEmpty else {
                deleteAllVersions(of: currentMessage)
                return
            }

            var updatedMessage = currentMessage
            updatedMessage.clearContentVersions()
            updatedMessage.reasoningContent = nil
            updatedMessage.reasoningProviderSpecificFields = nil
            updatedMessage.providerResponseMetadata = nil
            updatedMessage.toolCalls = nil
            updatedMessage.toolCallsPlacement = nil
            updatedMessage.fullErrorContent = nil
            updateMessage(updatedMessage, expected: currentMessage)
        }
    }

    func deleteMessages(withIDs messageIDs: Set<UUID>) {
        chatService.deleteMessages(withIDs: messageIDs)
    }

    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        deleteSessions(sessionsToDelete)
    }

    @discardableResult
    func deleteSessions(_ sessions: [ChatSession]) -> Bool {
        switch chatService.deleteSessions(sessions) {
        case .success:
            return true
        case .failure(.busy):
            messageEditErrorMessage = NSLocalizedString("请先停止当前请求并等待结束，再删除会话。", comment: "Cannot delete a session while its request is active")
            return false
        }
    }

    func messageCount(for session: ChatSession) async -> Int {
        if session.id == currentSession?.id {
            return allMessagesForSession.count
        }
        if let temporaryCount = chatService.temporaryChatMessageCount(for: session.id) {
            return temporaryCount
        }
        return chatService.messagesSnapshot(for: session.id).count
    }

    @discardableResult
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        chatService.branchSession(from: sourceSession, copyMessages: copyMessages)
    }

    @discardableResult
    func branchSessionFromMessage(upToMessage: ChatMessage) -> ChatSession {
        guard let session = currentSession else {
            logger.error("无法创建分支会话：当前会话为空，将创建新会话作为回退。")
            chatService.createNewSession()
            if let fallbackSession = chatService.currentSessionSubject.value {
                return fallbackSession
            }
            logger.error("创建新会话失败，返回临时会话实例作为回退。")
            return ChatSession(id: UUID(), name: NSLocalizedString("新的对话", comment: ""), isTemporary: true)
        }
        return chatService.branchSessionFromMessage(from: session, upToMessage: upToMessage)
    }

    func deleteLastMessage(for session: ChatSession) {
        chatService.deleteLastMessage(for: session)
    }

    func createNewSession() {
        chatService.createNewSession()
    }

    func isTemporaryChatEnabled(for sessionID: UUID?) -> Bool {
        chatService.isTemporaryChatEnabled(for: sessionID)
    }

    func enableTemporaryChat() {
        chatService.enableTemporaryChat()
    }

    func prepareDailyPulseIfNeeded() async {
        await DailyPulseManager.shared.generateIfNeeded()
    }

    func prepareMorningDailyPulseDeliveryIfNeeded(referenceDate: Date = Date()) async {
        let coordinator = DailyPulseDeliveryCoordinator.shared
        await coordinator.waitForSettingsLoad()
        guard !Task.isCancelled else { return }
        await DailyPulseManager.shared.generateForScheduledDeliveryIfNeeded(
            reminderEnabled: coordinator.reminderEnabled,
            deliveryTimes: coordinator.deliveryTimes,
            referenceDate: referenceDate
        )
    }

    @discardableResult
    func saveDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) -> ChatSession? {
        if let savedSessionID = card.savedSessionID,
           let existing = chatSessions.first(where: { $0.id == savedSessionID }) {
            Task { [weak self] in await self?.chatService.selectSession(existing) }
            return existing
        }
        return DailyPulseManager.shared.saveCardAsSession(cardID: card.id, runID: runID)
    }

    func continueDailyPulseCard(_ card: DailyPulseCard, from runID: UUID) {
        let existing = card.savedSessionID.flatMap { id in chatSessions.first { $0.id == id } }
        guard let session = existing
            ?? DailyPulseManager.shared.saveCardAsSession(cardID: card.id, runID: runID) else { return }
        Task { [weak self] in
            guard let self else { return }
            await chatService.selectSession(session)
            guard chatService.currentSessionSubject.value?.id == session.id else { return }
            userInput = DailyPulseManager.defaultContinuationPrompt(for: card)
            NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
        }
    }

    func applyDailyPulseContinuation(sessionID: UUID, prompt: String) {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            Task { [weak self] in
                guard let self else { return }
                await chatService.selectSession(session)
                guard chatService.currentSessionSubject.value?.id == session.id else { return }
                userInput = prompt
            }
        } else {
            userInput = prompt
        }
    }

    func setSelectedModel(_ model: RunnableModel) {
        chatService.setSelectedModel(model)
    }

    func setCurrentSession(_ session: ChatSession) {
        Task { [weak self] in await self?.chatService.selectSession(session) }
    }

    func requestMessageJump(sessionID: UUID, messageOrdinal: Int) {
        pendingSearchJumpTarget = SessionMessageJumpTarget(sessionID: sessionID, messageOrdinal: messageOrdinal)
    }

    func clearPendingMessageJumpTarget() {
        pendingSearchJumpTarget = nil
    }

    @discardableResult
    func setCurrentSessionIfExists(sessionID: UUID) -> Bool {
        if let session = chatSessions.first(where: { $0.id == sessionID })
            ?? chatService.chatSessionsSubject.value.first(where: { $0.id == sessionID }) {
            Task { [weak self] in await self?.chatService.selectSession(session) }
            return true
        }
        return false
    }

    func updateSession(_ session: ChatSession) {
        chatService.updateSession(session)
    }

    func updateSessionName(_ session: ChatSession, newName: String) {
        var updated = session
        updated.name = newName
        chatService.updateSession(updated)
    }

    @discardableResult
    func createSessionFolder(name: String, parentID: UUID? = nil) -> SessionFolder? {
        chatService.createSessionFolder(name: name, parentID: parentID)
    }

    func renameSessionFolder(_ folder: SessionFolder, newName: String) {
        chatService.renameSessionFolder(folderID: folder.id, newName: newName)
    }

    func deleteSessionFolder(_ folder: SessionFolder) {
        chatService.deleteSessionFolder(folderID: folder.id)
    }

    func moveSessionFolder(_ folder: SessionFolder, toParentID parentID: UUID?) {
        chatService.moveSessionFolder(folder, toParentID: parentID)
    }

    func moveSession(_ session: ChatSession, toFolderID folderID: UUID?) {
        chatService.moveSession(session, toFolderID: folderID)
    }

    @discardableResult
    func createSessionTag(name: String, color: SessionTagColor?) -> SessionTag? {
        chatService.createSessionTag(name: name, color: color)
    }

    func updateSessionTag(_ tag: SessionTag, name: String, color: SessionTagColor?) {
        chatService.updateSessionTag(tag, name: name, color: color)
    }

    func deleteSessionTag(_ tag: SessionTag) {
        chatService.deleteSessionTag(tag)
    }

    func setSessionTags(for session: ChatSession, tagIDs: [UUID]) {
        chatService.setSessionTags(sessionID: session.id, tagIDs: tagIDs)
    }

    func commitEditedMessage(_ updatedMessage: ChatMessage, original: ChatMessage) async throws {
        try await chatService.updateEditedMessage(updatedMessage, original: original)
        messageToEdit = nil
    }

    func retryMessage(_ message: ChatMessage, prefill: Bool = false) {
        messageEditErrorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
    }

    func retryVideoAnalysis(
        _ message: ChatMessage,
        fileName: String
    ) async throws -> VideoAnalysisResult {
        try await chatService.retryVideoAnalysis(
            messageID: message.id,
            fileName: fileName,
            sessionID: currentSession?.id
        )
    }

    func rewriteMessage(
        _ message: ChatMessage,
        instruction: String,
        referenceVersions: [MessageRewriteReferenceVersion] = [],
        selectionTarget: MessageRewriteSelectionTarget? = nil
    ) {
        let sessionID = currentSession?.id
        Task {
            do {
                try await chatService.rewriteMessage(
                    message,
                    instruction: instruction,
                    aiTemperature: aiTemperature,
                    sessionID: sessionID,
                    referenceVersions: referenceVersions,
                    selectionTarget: selectionTarget
                )
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    messageRewriteErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func canRetry(message: ChatMessage) -> Bool {
        false
    }

    func canRewrite(message: ChatMessage) -> Bool {
        false
    }

    func saveCurrentSessionDetails() {
        guard let session = currentSession else { return }
        chatService.updateSession(session)
    }

    func responseAttemptVersionInfo(for message: ChatMessage) -> ChatResponseAttemptVersionInfo? {
        responseAttemptVersionIndex[message.id]
    }

    func hasDisplayVersions(for message: ChatMessage) -> Bool {
        responseAttemptVersionInfo(for: message) != nil || message.hasMultipleVersions
    }

    func displayVersionCount(for message: ChatMessage) -> Int {
        responseAttemptVersionInfo(for: message)?.totalCount ?? message.getAllVersions().count
    }

    func displayCurrentVersionIndex(for message: ChatMessage) -> Int {
        responseAttemptVersionInfo(for: message)?.currentIndex ?? message.getCurrentVersionIndex()
    }

    func switchToPreviousVersion(of message: ChatMessage) {
        switchToVersion(max(0, displayCurrentVersionIndex(for: message) - 1), of: message)
    }

    func switchToNextVersion(of message: ChatMessage) {
        switchToVersion(min(displayVersionCount(for: message) - 1, displayCurrentVersionIndex(for: message) + 1), of: message)
    }

    func switchToVersion(_ index: Int, of message: ChatMessage) {
        guard let sessionID = currentSession?.id else { return }
        if !chatService.selectMessageVersion(at: index, of: message, sessionID: sessionID) {
            reportMessageEditFailure()
        }
    }

    func deleteCurrentVersion(of message: ChatMessage) {
        deleteVersion(at: displayCurrentVersionIndex(for: message), of: message)
    }

    func deleteVersion(at index: Int, of message: ChatMessage) {
        guard let sessionID = currentSession?.id else { return }
        if !chatService.deleteMessageVersion(at: index, of: message, sessionID: sessionID) {
            reportMessageEditFailure()
        }
    }

    func deleteAllVersions(of message: ChatMessage) {
        chatService.deleteAllVersions(of: message)
    }

    func addVersionToMessage(_ message: ChatMessage, newContent: String) {
        guard let sessionID = currentSession?.id else { return }
        if !chatService.addMessageVersion(content: newContent, to: message, sessionID: sessionID) {
            reportMessageEditFailure()
        }
    }

    func findMessage(by id: UUID) -> ChatMessage? {
        allMessagesForSession.first { $0.id == id }
    }

    @discardableResult
    func updateMessage(_ message: ChatMessage, expected: ChatMessage, sessionID: UUID? = nil) -> Bool {
        guard let sessionID = sessionID ?? currentSession?.id else { return false }
        guard chatService.replaceMessage(message, expected: expected, sessionID: sessionID) else {
            reportMessageEditFailure()
            return false
        }
        return true
    }

    func reportMessageEditFailure() {
        messageEditErrorMessage = NSLocalizedString("消息已变化或正在生成，请刷新后重试。", comment: "Message edit conflict")
    }

}
