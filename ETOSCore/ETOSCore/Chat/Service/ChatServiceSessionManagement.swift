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

public enum ChatSessionDeletionError: Error, Sendable {
    case busy(sessionIDs: Set<UUID>)
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

    public func createNewSession() {
        sessionSelectionLock.withLock { createNewSessionWhileSelectionIsLocked() }
    }

    private func createNewSessionWhileSelectionIsLocked() {
        let sourceSessionID = currentSessionSubject.value?.id
        var updatedSessions = chatSessionsSubject.value

        // 约束：最多只保留一个临时会话，重复点击“新建对话”时复用现有临时会话。
        let temporarySessions = updatedSessions.filter(\.isTemporary)
        if let reusableTemporary = temporarySessions.first {
            var didMutateList = false

            // 若历史遗留了多个临时会话，清理多余项并删除其会话文件。
            if temporarySessions.count > 1 {
                let candidates = Set(temporarySessions.dropFirst().map(\.id))
                let removableIDs = candidates.subtracting(busySessionIDs(in: candidates))
                if !removableIDs.isEmpty {
                    updatedSessions.removeAll { removableIDs.contains($0.id) }
                    didMutateList = true
                    logger.info("检测到多个临时会话，已清理多余会话: \(removableIDs.count) 个。")
                }
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
        storeRuntimeMessagesSnapshot([], for: newSession.id)
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        inheritLocalAgentMode(from: sourceSessionID, to: newSession.id)
        currentSessionSubject.send(newSession)
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
        sessionSelectionLock.withLock {
            createSavedSessionWhileSelectionIsLocked(
                name: name, initialMessages: initialMessages, preferredModelIdentifier: preferredModelIdentifier,
                toolContextIsolationEnabled: toolContextIsolationEnabled, folderID: folderID, activate: activate
            )
        }
    }

    private func createSavedSessionWhileSelectionIsLocked(
        name: String,
        initialMessages: [ChatMessage],
        preferredModelIdentifier: String?,
        toolContextIsolationEnabled: Bool,
        folderID: UUID?,
        activate: Bool
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

        storeRuntimeMessagesSnapshot(initialMessages, for: newSession.id)
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        if activate {
            currentSessionSubject.send(newSession)
            publishMessages(initialMessages)
        }
        logger.info("创建了会话: \(newSession.name)")
        return newSession
    }

    public func deleteSessions(_ sessionsToDelete: [ChatSession]) -> Result<Void, ChatSessionDeletionError> {
        sessionSelectionLock.withLock {
            let busy = busySessionIDs(in: Set(sessionsToDelete.map(\.id)))
            guard busy.isEmpty else { return .failure(.busy(sessionIDs: busy)) }
            deleteSessionsWhileSelectionIsLocked(sessionsToDelete)
            return .success(())
        }
    }

    private func deleteSessionsWhileSelectionIsLocked(_ sessionsToDelete: [ChatSession]) {
        var currentSessions = chatSessionsSubject.value
        let currentModeBeforeDeletion = currentSessionSubject.value.map {
            Persistence.localAgentMode(sessionID: $0.id)
        }
        let existingPermanentSessionIDs = Set(currentSessions.filter { !$0.isTemporary }.map(\.id))
        let deletingSessionIDs = Set(sessionsToDelete.map(\.id))
        let isClearingAllConversationRecords = !existingPermanentSessionIDs.isEmpty
            && existingPermanentSessionIDs.isSubset(of: deletingSessionIDs)
        // Make the entire batch unavailable to reentrant request admission
        // before publishing notifications for any individual deletion.
        for session in sessionsToDelete {
            clearRuntimeMessagesSnapshot(for: session.id)
        }
        for session in sessionsToDelete {
            cancelRequestForSessionDeletion(session.id)
            ephemeralSessionLock.lock()
            let removedTemporaryState = ephemeralSessionIDs.remove(session.id)
            ephemeralSessionLock.unlock()
            if removedTemporaryState != nil {
                notifyTemporaryChatStateDidChange(sessionID: session.id)
            }
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
                storeRuntimeMessagesSnapshot([], for: newSession.id)
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

    /// 新会话只在创建时复制一次来源模式；后续切换始终读取各自的会话记录。
    private func inheritLocalAgentMode(from sourceSessionID: UUID?, to targetSessionID: UUID) {
        guard let sourceSessionID, sourceSessionID != targetSessionID else { return }
        _ = Persistence.saveLocalAgentMode(
            Persistence.localAgentMode(sessionID: sourceSessionID),
            sessionID: targetSessionID
        )
    }

    /// 更新整个消息列表（用于版本管理等批量操作）
    public func updateMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        persistAndPublishMessages(messages, for: sessionID)
        logger.info("已更新会话消息列表: \(sessionID.uuidString)")
    }

}
