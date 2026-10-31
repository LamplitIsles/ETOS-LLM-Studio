// ============================================================================
// ChatSessionManagementTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的会话与文件夹管理测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

extension ChatServiceTests {
    @Test("Create New Session")
    func testCreateNewSession() {
        let initialCurrentSession = chatService.currentSessionSubject.value

        chatService.messagesForSessionSubject.send([ChatMessage(role: .user, content: "dummy message")])
        #expect(chatService.messagesForSessionSubject.value.isEmpty == false)

        chatService.createNewSession()

        let newSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value
        let newMessages = chatService.messagesForSessionSubject.value

        #expect(newSessions.count == 1)
        #expect(newSessions.filter(\.isTemporary).count == 1)
        #expect(newSessions.first?.id == newCurrentSession?.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.id == initialCurrentSession?.id)
        #expect(newMessages.isEmpty == true)
    }

    @Test("Create New Session when no temporary session exists")
    func testCreateNewSessionWhenNoTemporarySessionExists() {
        guard var onlySession = chatService.chatSessionsSubject.value.first else {
            Issue.record("缺少初始会话")
            return
        }
        onlySession.isTemporary = false
        chatService.chatSessionsSubject.send([onlySession])
        chatService.setCurrentSession(onlySession)
        #expect(Persistence.saveLocalAgentMode(.agent, sessionID: onlySession.id))

        chatService.createNewSession()

        let sessions = chatService.chatSessionsSubject.value
        let temporarySessions = sessions.filter(\.isTemporary)
        #expect(sessions.count == 2)
        #expect(temporarySessions.count == 1)
        #expect(sessions.first?.isTemporary == true)
        #expect(chatService.currentSessionSubject.value?.id == sessions.first?.id)
        if let newSessionID = sessions.first?.id {
            #expect(Persistence.localAgentMode(sessionID: newSessionID) == .agent)
        }
    }

    @Test("新会话继承当前模式且历史会话保持独立")
    func newSessionInheritsCurrentAgentModeWithoutChangingHistory() throws {
        let reusableTemporary = try #require(chatService.chatSessionsSubject.value.first)
        let source = chatService.createSavedSession(name: "Agent 来源会话")
        #expect(Persistence.saveLocalAgentMode(.agent, sessionID: source.id))
        #expect(Persistence.saveLocalAgentMode(.chat, sessionID: reusableTemporary.id))

        chatService.createNewSession()

        let inheritedSession = try #require(chatService.currentSessionSubject.value)
        #expect(inheritedSession.id == reusableTemporary.id)
        #expect(Persistence.localAgentMode(sessionID: inheritedSession.id) == .agent)

        #expect(Persistence.saveLocalAgentMode(.chat, sessionID: inheritedSession.id))
        chatService.setCurrentSession(source)
        #expect(Persistence.localAgentMode(sessionID: source.id) == .agent)
        chatService.setCurrentSession(inheritedSession)
        #expect(Persistence.localAgentMode(sessionID: inheritedSession.id) == .chat)
    }

    @Test("Switch Session")
    func testSwitchSession() {
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        chatService.createNewSession()

        let messageForSession1 = ChatMessage(role: .user, content: "This is a test for session 1")
        chatService.updateMessages([messageForSession1], for: session1.id)

        chatService.setCurrentSession(session1)

        let currentSession = chatService.currentSessionSubject.value
        let currentMessages = chatService.messagesForSessionSubject.value

        #expect(currentSession?.id == session1.id)
        #expect(currentMessages.count == 1)
        #expect(currentMessages.first?.content == messageForSession1.content)
    }

    @Test("Delete Session")
    func testDeleteSession() {
        guard var session1 = chatService.currentSessionSubject.value else {
            Issue.record("缺少初始会话")
            return
        }
        session1.isTemporary = false
        chatService.chatSessionsSubject.send([session1])
        chatService.setCurrentSession(session1)
        chatService.createNewSession()
        let session2 = chatService.currentSessionSubject.value!
        let initialCount = chatService.chatSessionsSubject.value.count
        #expect(initialCount == 2)

        chatService.deleteSessions([session2])

        let finalSessions = chatService.chatSessionsSubject.value
        let finalCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == initialCount - 1)
        #expect(finalSessions.contains(where: { $0.id == session2.id }) == false)
        #expect(finalCurrentSession?.id == session1.id)
    }

    @Test("删除会话不会移除其他会话仍在引用的附件实体文件")
    func testDeleteSessionKeepsFileAttachmentReferencedByOtherSession() async {
        let fileName = "shared-delete-check-\(UUID().uuidString).txt"
        defer { Persistence.deleteFile(fileName: fileName) }

        _ = Persistence.saveFile(Data("共享附件".utf8), fileName: fileName)
        let session1 = chatService.createSavedSession(name: "引用会话一")
        let session2 = chatService.createSavedSession(name: "引用会话二")
        chatService.updateMessages([
            ChatMessage(role: .user, content: "[文件]", fileFileNames: [fileName])
        ], for: session1.id)
        chatService.updateMessages([
            ChatMessage(role: .user, content: "[文件]", fileFileNames: [fileName])
        ], for: session2.id)

        chatService.deleteSessions([session1])

        #expect(Persistence.fileExists(fileName: fileName))

        chatService.deleteSessions([session2])
    }

    @Test("Delete last session creates a new temporary one")
    func testDeleteLastSession_CreatesNewTemporarySession() {
        let initialSessions = chatService.chatSessionsSubject.value
        #expect(initialSessions.count == 1)
        let lastSession = initialSessions.first!

        chatService.deleteSessions([lastSession])

        let finalSessions = chatService.chatSessionsSubject.value
        let newCurrentSession = chatService.currentSessionSubject.value

        #expect(finalSessions.count == 1)
        #expect(newCurrentSession?.id != lastSession.id)
        #expect(newCurrentSession?.isTemporary == true)
        #expect(newCurrentSession?.name == "新的对话")
    }

}
