// ============================================================================
// ChatServiceSessionManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的会话创建、删除、分支、文件夹管理与当前会话切换。
// ============================================================================

import Foundation
import Combine
import os.log

public extension Notification.Name {
    static let temporaryChatStateDidChange = Notification.Name("com.ETOS.temporaryChat.stateDidChange")
}

public enum TemporaryChatToggleAvailability {
    /// 已开启的临时对话始终允许关闭；新的临时对话只能在对话开始前开启。
    public static func isAvailable(
        isTemporaryChatEnabled: Bool,
        hasConversationStarted: Bool
    ) -> Bool {
        isTemporaryChatEnabled || !hasConversationStarted
    }
}

extension ChatService {
    // MARK: - 公开方法 (会话管理)

    public func isTemporaryChatEnabled(for sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        ephemeralSessionLock.lock()
        defer { ephemeralSessionLock.unlock() }
        return ephemeralSessionIDs.contains(sessionID)
    }

    public func temporaryChatMessageCount(for sessionID: UUID) -> Int? {
        guard isTemporaryChatEnabled(for: sessionID) else { return nil }
        return runtimeMessagesSnapshot(for: sessionID)?.count ?? 0
    }

    /// 切换到唯一的运行期临时会话。
    public func enableTemporaryChat() {
        createNewSession()
        guard let sessionID = currentSessionSubject.value?.id else { return }
        ephemeralSessionLock.lock()
        ephemeralSessionIDs.insert(sessionID)
        ephemeralSessionLock.unlock()
        notifyTemporaryChatStateDidChange(sessionID: sessionID)
    }

    public func createNewSession() {
        let sourceSessionID = currentSessionSubject.value?.id
        var updatedSessions = chatSessionsSubject.value

        // 约束：最多只保留一个临时会话，重复点击“新建对话”时复用现有临时会话。
        let temporarySessions = updatedSessions.filter(\.isTemporary)
        if let reusableTemporary = temporarySessions.first {
            var didMutateList = false

            // 若历史遗留了多个临时会话，清理多余项并删除其会话文件。
            if temporarySessions.count > 1 {
                let removableIDs = Set(temporarySessions.dropFirst().map(\.id))
                updatedSessions.removeAll { removableIDs.contains($0.id) }
                didMutateList = true
                logger.info("检测到多个临时会话，已清理多余会话: \(removableIDs.count) 个。")
            }

            // 将唯一临时会话放到顶部，保证列表行为一致。
            if let index = updatedSessions.firstIndex(where: { $0.id == reusableTemporary.id }), index > 0 {
                let temporary = updatedSessions.remove(at: index)
                updatedSessions.insert(temporary, at: 0)
                didMutateList = true
            }

            if didMutateList {
                chatSessionsSubject.send(updatedSessions)
            }

            // 始终切换到复用的临时会话，并刷新其消息列表（通常为空）。
            if let target = updatedSessions.first(where: { $0.id == reusableTemporary.id }) {
                inheritLocalAgentMode(from: sourceSessionID, to: target.id)
                if currentSessionSubject.value?.id == target.id {
                    let messages = messagesForSessionActivation(target.id)
                    storeRuntimeMessagesSnapshot(messages, for: target.id)
                    publishMessages(messages)
                } else {
                    setCurrentSession(target)
                }
                logger.info("复用了已有临时会话。")
            }
            return
        }

        let newSession = ChatSession(
            id: UUID(),
            name: NSLocalizedString("新的对话", comment: "Default new chat session name"),
            isTemporary: true
        )
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        inheritLocalAgentMode(from: sourceSessionID, to: newSession.id)
        currentSessionSubject.send(newSession)
        storeRuntimeMessagesSnapshot([], for: newSession.id)
        publishMessages([])
        logger.info("创建了新的临时会话。")
    }

    /// 创建一个带初始消息的正式会话，并切换到该会话。
    @discardableResult
    public func createSavedSession(
        name: String,
        initialMessages: [ChatMessage] = [],
        preferredModelIdentifier: String? = nil,
        toolContextIsolationEnabled: Bool = false,
        folderID: UUID? = nil,
        activate: Bool = true
    ) -> ChatSession {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmedName.isEmpty
            ? NSLocalizedString("新的对话", comment: "Default new chat session name")
            : trimmedName
        let newSession = ChatSession(
            id: UUID(),
            name: sessionName,
            preferredModelIdentifier: preferredModelIdentifier,
            toolContextIsolationEnabled: toolContextIsolationEnabled,
            folderID: folderID,
            isTemporary: false
        )

        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        storeRuntimeMessagesSnapshot(initialMessages, for: newSession.id)
        if activate {
            currentSessionSubject.send(newSession)
            publishMessages(initialMessages)
        }
        logger.info("创建了会话: \(newSession.name)")
        return newSession
    }

    public func deleteSessions(_ sessionsToDelete: [ChatSession]) {
        var currentSessions = chatSessionsSubject.value
        let currentModeBeforeDeletion = currentSessionSubject.value.map {
            Persistence.localAgentMode(sessionID: $0.id)
        }
        let existingPermanentSessionIDs = Set(currentSessions.filter { !$0.isTemporary }.map(\.id))
        let deletingSessionIDs = Set(sessionsToDelete.map(\.id))
        let isClearingAllConversationRecords = !existingPermanentSessionIDs.isEmpty
            && existingPermanentSessionIDs.isSubset(of: deletingSessionIDs)
        for session in sessionsToDelete {
            cancelRequestForSessionDeletion(session.id)
            prepareConversationRuntimeForSessionDeletion(session.id)
            ephemeralSessionLock.lock()
            let removedTemporaryState = ephemeralSessionIDs.remove(session.id)
            ephemeralSessionLock.unlock()
            if removedTemporaryState != nil {
                notifyTemporaryChatStateDidChange(sessionID: session.id)
            }
            clearRuntimeMessagesSnapshot(for: session.id)

            periodicTimeLandmarkLastInjectedAtBySessionID.removeValue(forKey: session.id)
        }
        currentSessions.removeAll { session in sessionsToDelete.contains { $0.id == session.id } }
        var newCurrentSession = currentSessionSubject.value
        if let current = newCurrentSession, sessionsToDelete.contains(where: { $0.id == current.id }) {
            if let firstSession = currentSessions.first {
                newCurrentSession = firstSession
            } else {
                let newSession = ChatSession(
                    id: UUID(),
                    name: NSLocalizedString("新的对话", comment: "Default new chat session name"),
                    isTemporary: true
                )
                currentSessions.append(newSession)
                newCurrentSession = newSession
                if let currentModeBeforeDeletion {
                    _ = Persistence.saveLocalAgentMode(
                        currentModeBeforeDeletion,
                        sessionID: newSession.id
                    )
                }
            }
        }
        chatSessionsSubject.send(currentSessions)
        if newCurrentSession?.id != currentSessionSubject.value?.id {
            setCurrentSession(newCurrentSession)
        }
        if isClearingAllConversationRecords {
            scheduleAchievementUnlockIfNeeded(.memoryPurge)
        }
    }

    private func notifyTemporaryChatStateDidChange(sessionID: UUID) {
        NotificationCenter.default.post(
            name: .temporaryChatStateDidChange,
            object: self,
            userInfo: ["sessionID": sessionID]
        )
    }

    @discardableResult
    public func branchSession(from sourceSession: ChatSession, copyMessages: Bool) -> ChatSession {
        let newSession = ChatSession(
            id: UUID(),
            name: String(
                format: NSLocalizedString("分支: %@", comment: "Branched chat session name"),
                sourceSession.name
            ),
            preferredModelIdentifier: sourceSession.preferredModelIdentifier,
            tagIDs: sourceSession.tagIDs,
            toolContextIsolationEnabled: sourceSession.toolContextIsolationEnabled,
            folderID: sourceSession.folderID,
            isTemporary: false
        )
        logger.info("创建了分支会话: \(newSession.name)")
        if copyMessages {
            var sourceMessages = messagesSnapshot(for: sourceSession.id)
            if !sourceMessages.isEmpty {
                for i in sourceMessages.indices {
                    if let originalFileName = sourceMessages[i].audioFileName,
                       let audioData = Persistence.loadAudio(fileName: originalFileName) {
                        let ext = (originalFileName as NSString).pathExtension
                        let newFileName = "\(UUID().uuidString).\(ext)"
                        if Persistence.saveAudio(audioData, fileName: newFileName) != nil {
                            sourceMessages[i].audioFileName = newFileName
                            logger.info("  - 复制了音频文件: \(originalFileName) -> \(newFileName)")
                        }
                    }
                    if let originalFileNames = sourceMessages[i].fileFileNames, !originalFileNames.isEmpty {
                        sourceMessages[i].fileFileNames = originalFileNames
                        logger.info("  - 复用了 \(originalFileNames.count) 个文件附件引用。")
                    }
                }
                storeRuntimeMessagesSnapshot(sourceMessages, for: newSession.id)
                logger.info("  - 复制了 \(sourceMessages.count) 条消息到新会话。")
            }
        }
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        inheritLocalAgentMode(from: sourceSession.id, to: newSession.id)
        setCurrentSession(newSession)
        return newSession
    }

    /// 从指定消息处创建分支会话
    /// - Parameters:
    ///   - sourceSession: 源会话
    ///   - upToMessage: 包含此消息及之前的所有消息
    /// - Returns: 新创建的分支会话
    @discardableResult
    public func branchSessionFromMessage(from sourceSession: ChatSession, upToMessage: ChatMessage) -> ChatSession {
        let newSession = ChatSession(
            id: UUID(),
            name: String(
                format: NSLocalizedString("分支: %@", comment: "Branched chat session name"),
                sourceSession.name
            ),
            preferredModelIdentifier: sourceSession.preferredModelIdentifier,
            tagIDs: sourceSession.tagIDs,
            toolContextIsolationEnabled: sourceSession.toolContextIsolationEnabled,
            folderID: sourceSession.folderID,
            isTemporary: false
        )
        logger.info("从消息处创建分支会话: \(newSession.name)")

        let sourceMessages = ChatResponseAttemptSupport.visibleMessages(from: messagesSnapshot(for: sourceSession.id))
        if let messageIndex = sourceMessages.firstIndex(where: { $0.id == upToMessage.id }) {
            var messagesToCopy = Array(sourceMessages[0...messageIndex])

            for i in messagesToCopy.indices {
                if let originalFileName = messagesToCopy[i].audioFileName,
                   let audioData = Persistence.loadAudio(fileName: originalFileName) {
                    let ext = (originalFileName as NSString).pathExtension
                    let newFileName = "\(UUID().uuidString).\(ext)"
                    if Persistence.saveAudio(audioData, fileName: newFileName) != nil {
                        messagesToCopy[i].audioFileName = newFileName
                        logger.info("  - 复制了音频文件: \(originalFileName) -> \(newFileName)")
                    }
                }

                if let originalImageFileNames = messagesToCopy[i].imageFileNames, !originalImageFileNames.isEmpty {
                    var newImageFileNames: [String] = []
                    var copiedImageNamesByOriginal: [String: String] = [:]
                    for originalImageFileName in originalImageFileNames {
                        if let imageData = Persistence.loadImage(fileName: originalImageFileName) {
                            let ext = (originalImageFileName as NSString).pathExtension
                            let newImageFileName = "\(UUID().uuidString).\(ext)"
                            if Persistence.saveImage(imageData, fileName: newImageFileName) != nil {
                                newImageFileNames.append(newImageFileName)
                                copiedImageNamesByOriginal[originalImageFileName] = newImageFileName
                                logger.info("  - 复制了图片文件: \(originalImageFileName) -> \(newImageFileName)")
                            }
                        }
                    }
                    if !newImageFileNames.isEmpty {
                        messagesToCopy[i].imageFileNames = newImageFileNames
                        let excludedNames = (messagesToCopy[i].modelExcludedImageFileNames ?? [])
                            .compactMap { copiedImageNamesByOriginal[$0] }
                        messagesToCopy[i].modelExcludedImageFileNames = excludedNames.isEmpty ? nil : excludedNames
                    }
                }

                if let originalFileNames = messagesToCopy[i].fileFileNames, !originalFileNames.isEmpty {
                    messagesToCopy[i].fileFileNames = originalFileNames
                    logger.info("  - 复用了 \(originalFileNames.count) 个文件附件引用。")
                }
            }

            storeRuntimeMessagesSnapshot(messagesToCopy, for: newSession.id)
            logger.info("  - 复制了 \(messagesToCopy.count) 条消息到新会话（截止到指定消息）。")
        } else {
            logger.warning("  - 未找到指定的消息，创建空分支会话。")
        }

        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        inheritLocalAgentMode(from: sourceSession.id, to: newSession.id)
        setCurrentSession(newSession)
        return newSession
    }

    /// 新会话只在创建时复制一次来源模式；后续切换始终读取各自的会话记录。
    private func inheritLocalAgentMode(from sourceSessionID: UUID?, to targetSessionID: UUID) {
        guard let sourceSessionID, sourceSessionID != targetSessionID else { return }
        _ = Persistence.saveLocalAgentMode(
            Persistence.localAgentMode(sessionID: sourceSessionID),
            sessionID: targetSessionID
        )
    }

    public func deleteLastMessage(for session: ChatSession) {
        var messages = messagesSnapshot(for: session.id)
        if !messages.isEmpty {
            let lastMessage = messages.removeLast()
            invalidateAttachmentCache(for: lastMessage)
            storeRuntimeMessagesSnapshot(messages, for: session.id)
            logger.info("删除了会话的最后一条消息: \(session.name)")
            if session.id == currentSessionSubject.value?.id {
                publishMessages(messages)
            }
        }
    }

    public func deleteMessage(_ message: ChatMessage, targetSessionID: UUID? = nil) {
        guard let sessionID = targetSessionID ?? currentSessionSubject.value?.id else { return }
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let targetMessage = messages[messageIndex]
        let deletedMessages = [targetMessage]
        for deletedMessage in deletedMessages {
            invalidateAttachmentCache(for: deletedMessage)
        }
        reanchorResponseGroupsAfterDeletingUsers(
            in: &messages,
            deletingMessageIDs: [targetMessage.id]
        )
        messages.remove(at: messageIndex)
        repairSelectedResponseAttempts(in: &messages, affectedBy: deletedMessages)

        persistAndPublishMessages(messages, for: sessionID)
        logger.info("已删除消息: \(targetMessage.id.uuidString)")
    }

    /// 删除明确选中的消息，并清理已经合并进所选气泡的隐藏工具结果记录。
    public func deleteMessages(withIDs messageIDs: Set<UUID>) {
        guard !messageIDs.isEmpty,
              let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        let resolvedMessageIDs = BatchSelectionSupport.deletionIDs(
            selectedIDs: messageIDs,
            in: messages
        )
        let deletedMessages = messages.filter { resolvedMessageIDs.contains($0.id) }
        guard !deletedMessages.isEmpty else { return }

        for deletedMessage in deletedMessages {
            invalidateAttachmentCache(for: deletedMessage)
        }
        reanchorResponseGroupsAfterDeletingUsers(
            in: &messages,
            deletingMessageIDs: resolvedMessageIDs
        )
        messages.removeAll { resolvedMessageIDs.contains($0.id) }
        repairSelectedResponseAttempts(in: &messages, affectedBy: deletedMessages)

        publishMessages(messages)
        storeRuntimeMessagesSnapshot(messages, for: currentSession.id)
        logger.info("已批量删除选中消息: \(deletedMessages.count) 条。")
    }

    public func deleteAllVersions(of message: ChatMessage, targetSessionID: UUID? = nil) {
        guard let sessionID = targetSessionID ?? currentSessionSubject.value?.id else { return }
        var messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let targetMessage = messages[messageIndex]

        // 确认期间其他版本可能已删除；最后一轮也要连同工具结果一起移除。
        if let groupID = targetMessage.responseGroupID
            ?? (messages.contains(where: { $0.responseGroupID == targetMessage.id }) ? targetMessage.id : nil) {
            let deletedMessages = messages.filter { $0.responseGroupID == groupID }
            guard !deletedMessages.isEmpty else { return }
            for deletedMessage in deletedMessages {
                invalidateAttachmentCache(for: deletedMessage)
            }
            messages.removeAll { $0.responseGroupID == groupID }
            if let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
                messages[anchorIndex].selectedResponseAttemptID = nil
            }

            persistAndPublishMessages(messages, for: sessionID)
            logger.info("已删除回复组的所有版本: \(groupID.uuidString)")
            return
        }

        deleteMessage(targetMessage, targetSessionID: sessionID)
    }

    public func updateMessageContent(_ message: ChatMessage, with newContent: String) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].content = newContent
        publishMessages(messages)
        storeRuntimeMessagesSnapshot(messages, for: currentSession.id)
        logger.info("已更新消息内容: \(message.id.uuidString)")
    }

    /// 更新单条消息（包括内容和思考过程）
    public func updateMessage(_ updatedMessage: ChatMessage) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let index = messages.firstIndex(where: { $0.id == updatedMessage.id }) else { return }
        messages.replaceSubrange(
            index...index,
            with: ChatMessageAtomicContentSupport.atomized(updatedMessage)
        )
        publishMessages(messages)
        storeRuntimeMessagesSnapshot(messages, for: currentSession.id)
        logger.info("已更新消息: \(updatedMessage.id.uuidString)")
    }

    /// 更新整个消息列表（用于版本管理等批量操作）
    public func updateMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        persistAndPublishMessages(messages, for: sessionID)
        logger.info("已更新会话消息列表: \(sessionID.uuidString)")
    }

    /// 桌面历史操作显式指定来源；回复尝试切换整条工具链，旧格式仍切换正文版本。
    @discardableResult
    public func selectMessageVersion(at index: Int, of original: ChatMessage, sessionID: UUID) -> Bool {
        guard !hasActiveRequestContext(for: sessionID), conversationSession(withID: sessionID) != nil else { return false }
        let source = messagesSnapshot(for: sessionID)
        guard let position = source.firstIndex(where: { $0.id == original.id }), source[position] == original else { return false }
        let updated: [ChatMessage]
        if let info = ChatResponseAttemptSupport.versionInfo(for: original, in: source) {
            let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: info.responseGroupID, in: source)
            guard attempts.indices.contains(index) else { return false }
            updated = ChatResponseAttemptSupport.selectAttempt(attemptID: attempts[index], groupID: info.responseGroupID, in: source)
        } else {
            guard original.getAllVersions().indices.contains(index) else { return false }
            var messages = source
            messages[position].switchToVersion(index)
            updated = messages
        }
        updateMessages(updated, for: sessionID)
        return true
    }

    public func updateSession(_ session: ChatSession) {
        var session = session
        if isTemporaryChatEnabled(for: session.id) {
            // 编辑标题、提示词等元数据不能隐式关闭临时模式；只有显式保存才允许落盘。
            session.isTemporary = true
        } else {
            guard !session.isTemporary else { return }
        }
        var currentSessions = chatSessionsSubject.value
        if let index = currentSessions.firstIndex(where: { $0.id == session.id }) {
            currentSessions[index] = session
            chatSessionsSubject.send(currentSessions)

            // 关键修复：如果被修改的是当前会话，则必须同步更新 currentSessionSubject
            if currentSessionSubject.value?.id == session.id {
                currentSessionSubject.send(session)
                logger.info("  - 同步更新了当前活动会话的状态。")
            }

            logger.info("更新了会话详情: \(session.name)")
        }
    }

    private func reanchorResponseGroupsAfterDeletingUsers(
        in messages: inout [ChatMessage],
        deletingMessageIDs: Set<UUID>
    ) {
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        for turn in ChatConversationTurnSupport.turns(in: visibleMessages) {
            guard let userRange = turn.userRange else { continue }
            let oldAnchorID = visibleMessages[userRange.index(before: userRange.endIndex)].id
            guard deletingMessageIDs.contains(oldAnchorID),
                  let newAnchorID = visibleMessages[userRange]
                    .reversed()
                    .first(where: { !deletingMessageIDs.contains($0.id) })?
                    .id else {
                continue
            }

            let selectedAttemptID = ChatResponseAttemptSupport.selectedAttemptID(
                for: oldAnchorID,
                in: messages
            )
            for index in messages.indices {
                if messages[index].responseGroupID == oldAnchorID {
                    messages[index].responseGroupID = newAnchorID
                }
                if messages[index].id == newAnchorID {
                    messages[index].selectedResponseAttemptID = selectedAttemptID
                }
            }
        }
    }

    private func repairSelectedResponseAttempts(in messages: inout [ChatMessage], affectedBy deletedMessages: [ChatMessage]) {
        let affectedGroupIDs = Set(deletedMessages.compactMap(\.responseGroupID))
        guard !affectedGroupIDs.isEmpty else { return }

        for groupID in affectedGroupIDs {
            guard let anchorIndex = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }),
                  let selectedAttemptID = messages[anchorIndex].selectedResponseAttemptID else {
                continue
            }
            guard !responseAttemptHasDisplaySegment(groupID: groupID, attemptID: selectedAttemptID, in: messages) else {
                continue
            }

            let replacementAttemptID = ChatResponseAttemptSupport
                .orderedAttemptIDs(for: groupID, in: messages)
                .reversed()
                .first { responseAttemptHasDisplaySegment(groupID: groupID, attemptID: $0, in: messages) }
            messages[anchorIndex].selectedResponseAttemptID = replacementAttemptID
        }
    }

    private func responseAttemptHasDisplaySegment(groupID: UUID, attemptID: UUID, in messages: [ChatMessage]) -> Bool {
        messages.contains {
            $0.responseGroupID == groupID
                && $0.responseAttemptID == attemptID
                && ($0.role == .assistant || $0.role == .error)
        }
    }
}
