import Foundation

enum ChatMessagePublication {
    static func publish(
        sessionID: UUID,
        selectionLock: NSRecursiveLock,
        currentSessionID: () -> UUID?,
        snapshot: (UUID) -> [ChatMessage]?,
        emit: ([ChatMessage]) -> Void
    ) {
        selectionLock.withLock {
            guard currentSessionID() == sessionID, let messages = snapshot(sessionID) else { return }
            emit(messages)
        }
    }
}
