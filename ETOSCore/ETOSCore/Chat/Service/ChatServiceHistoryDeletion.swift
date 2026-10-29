import Foundation

public enum MessageHistoryDeletionKind: String, Sendable {
    case message, currentVersion, allVersions
}

extension ChatService {
    /// 确认期间目标发生变化或请求开始时，拒绝整个操作。
    @discardableResult
    public func deleteHistoryMessage(_ original: ChatMessage, sessionID: UUID, kind: MessageHistoryDeletionKind) -> Bool {
        var deleted: [ChatMessage] = []
        guard let updated = mutateRuntimeMessages(for: sessionID, requireIdle: true, { messages in
            guard let position = messages.firstIndex(where: { $0.id == original.id }),
                  ChatMessageEdits.matches(messages[position], expected: original) else { return false }
            let target = messages[position]
            let groupID = target.responseGroupID ?? (messages.contains(where: { $0.responseGroupID == target.id }) ? target.id : nil)
            if kind != .message, let groupID, let attempt = target.responseAttemptID,
               ChatResponseAttemptSupport.selectedAttemptID(for: groupID, in: messages) != attempt { return false }
            let previous = messages
            switch kind {
            case .message:
                reanchorResponseGroupsAfterDeletingUsers(in: &messages, deletingMessageIDs: [target.id])
                messages.remove(at: position)
                repairSelectedResponseAttempts(in: &messages, affectedBy: [target])
            case .allVersions:
                if let groupID {
                    guard messages.contains(where: { $0.responseGroupID == groupID }) else { return false }
                    messages.removeAll { $0.responseGroupID == groupID }
                    if let anchor = messages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
                        messages[anchor].selectedResponseAttemptID = nil
                    }
                } else {
                    reanchorResponseGroupsAfterDeletingUsers(in: &messages, deletingMessageIDs: [target.id])
                    messages.remove(at: position)
                    repairSelectedResponseAttempts(in: &messages, affectedBy: [target])
                }
            case .currentVersion:
                if let groupID {
                    let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)
                    guard let selected = ChatResponseAttemptSupport.selectedAttemptID(for: groupID, in: messages),
                          let index = attempts.firstIndex(of: selected),
                          let result = ChatResponseAttemptSupport.deleteAttempt(at: index, groupID: groupID, in: messages) else { return false }
                    messages = result
                } else if target.hasMultipleVersions {
                    guard messages[position].removeVersionAndReturnCurrentIndex(at: target.getCurrentVersionIndex()) != nil else { return false }
                } else {
                    reanchorResponseGroupsAfterDeletingUsers(in: &messages, deletingMessageIDs: [target.id])
                    messages.remove(at: position)
                    repairSelectedResponseAttempts(in: &messages, affectedBy: [target])
                }
            }
            let retainedIDs = Set(messages.map(\.id))
            deleted = previous.filter { !retainedIDs.contains($0.id) }
            return true
        }) else { return false }
        deleted.forEach { invalidateAttachmentCache(for: $0) }
        publishMessagesIfCurrentSession(updated, for: sessionID)
        return true
    }
}
