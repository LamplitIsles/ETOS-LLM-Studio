// ============================================================================
// ChatServiceSessionFolderManagement.swift
// ============================================================================
// ETOS LLM Studio
//
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public func setCurrentSession(_ session: ChatSession?) {
        sessionSelectionLock.withLock {
            sessionSelectionToken = UUID()
            applyCurrentSession(session)
        }
    }

    func applyCurrentSession(_ session: ChatSession?, preparedMessages: [ChatMessage]? = nil) {
        if let session, !chatSessionsSubject.value.contains(where: { $0.id == session.id }) { return }
        let currentSession = currentSessionSubject.value
        if currentSession == session { return }

        if let session, session.id == currentSession?.id {
            currentSessionSubject.send(session)

            var sessions = chatSessionsSubject.value
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
                chatSessionsSubject.send(sessions)
            }

            logger.info("已更新当前会话元数据: \(session.name)")
            return
        }

        let messages = preparedMessages ?? session.map { messagesForSessionActivation($0.id) } ?? []
        currentSessionSubject.send(session)
        let latestMessages = session.flatMap { runtimeMessagesSnapshot(for: $0.id) } ?? messages
        publishMessages(latestMessages)
        logger.info("已切换到会话: \(session?.name ?? "无")")
    }

    @MainActor
    func promoteSessionToTopIfNeeded(sessionID: UUID) async {
        guard let index = chatSessionsSubject.value.firstIndex(where: { $0.id == sessionID }), index > 0 else { return }
        var sessions = chatSessionsSubject.value
        let session = sessions.remove(at: index)
        sessions.insert(session, at: 0)
        chatSessionsSubject.send(sessions)
        logger.info("已将会话移动到列表顶部。")
    }
}
