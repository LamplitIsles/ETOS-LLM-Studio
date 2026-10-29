import Foundation

struct ChatMessage: Equatable { let value: String }

private final class State: @unchecked Sendable {
    let selectionLock = NSRecursiveLock()
    var current: UUID?
    private var messages: [ChatMessage]?
    private var outputs: [[ChatMessage]] = []

    init(sessionID: UUID) { current = sessionID; messages = [.init(value: "a")] }
    func setMessages(_ messages: [ChatMessage]?) { selectionLock.withLock { self.messages = messages } }
    func snapshot() -> [ChatMessage]? { selectionLock.withLock { messages } }
    func record(_ value: [ChatMessage]) { selectionLock.withLock { outputs.append(value) } }
    func recorded() -> [[ChatMessage]] { selectionLock.withLock { outputs } }
    func publish(sessionID: UUID, beforeEmit: () -> Void = {}) {
        ChatMessagePublication.publish(
            sessionID: sessionID, selectionLock: selectionLock,
            currentSessionID: { current }, snapshot: { _ in snapshot() },
            emit: { messages in beforeEmit(); record(messages) }
        )
    }
}

@main
struct ChatMessagePublicationChecks {
    static func main() {
        let sessionID = UUID()
        let state = State(sessionID: sessionID)
        let a = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            state.publish(sessionID: sessionID) {
                precondition(state.snapshot() == [.init(value: "a")]) // synchronous reentry
                a.signal()
                precondition(release.wait(timeout: .now() + 3) == .success)
            }
            firstDone.signal()
        }
        precondition(a.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async {
            state.setMessages([.init(value: "a"), .init(value: "b")])
            state.publish(sessionID: sessionID)
            secondDone.signal()
        }
        release.signal()
        precondition(firstDone.wait(timeout: .now() + 3) == .success)
        precondition(secondDone.wait(timeout: .now() + 3) == .success)
        precondition(state.recorded() == [[.init(value: "a")], [.init(value: "a"), .init(value: "b")]])

        state.selectionLock.withLock { state.current = nil; state.setMessages(nil) }
        state.publish(sessionID: sessionID)
        precondition(state.recorded().count == 2)
        print("chat message publication checks passed")
    }
}
