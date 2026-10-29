import Combine
import Foundation

extension ChatService {
    /// 用户切换会话时先在后台读取历史；连续点选只提交最后一次选择。
    @MainActor
    public func selectSession(_ session: ChatSession?, isSelectionAllowed: @MainActor () -> Bool = { true }) async {
        guard isSelectionAllowed() else { return }
        let token = UUID()
        let sourceSessionID = currentSessionSubject.value?.id
        sessionSelectionLock.withLock { sessionSelectionToken = token }
        if currentSessionSubject.value?.id == session?.id {
            setCurrentSession(session)
            return
        }

        let messages = await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, let session else { return [ChatMessage]() }
            return self.messagesForSessionActivation(session.id)
        }.value
        // 后台读盘期间窗口可能锁定；调用方在实际发布前再次核对生命周期。
        guard !Task.isCancelled, isSelectionAllowed() else { return }
        sessionSelectionLock.withLock {
            guard sessionSelectionToken == token,
                  currentSessionSubject.value?.id == sourceSessionID else { return }
            let currentTarget = session.flatMap { requested in
                chatSessionsSubject.value.first(where: { $0.id == requested.id })
            }
            guard session == nil || currentTarget != nil else { return }
            // 用户等待选择时，任意输入或流式更新都可能修改该会话。
            let latestMessages = currentTarget.flatMap { runtimeMessagesSnapshot(for: $0.id) } ?? messages
            applyCurrentSession(currentTarget, preparedMessages: latestMessages)
        }
    }
}
