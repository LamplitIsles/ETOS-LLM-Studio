import Foundation

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [UUID: UUID] = [:]
    private(set) var successfulPreparations = 0

    func begin(_ session: UUID, exists: Bool = true, token: UUID) -> ChatRequestSlot.Outcome {
        lock.lock()
        defer { lock.unlock() }
        return ChatRequestSlot.acquire(sessionID: session, sessionExists: exists, contexts: &contexts) {
            successfulPreparations += 1
            return token
        }
    }

    func release(_ session: UUID, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if contexts[session] == token { contexts.removeValue(forKey: session) }
    }
}

@main
struct ChatRequestSlotChecks {
    static func main() {
        let state = State()
        let session = UUID(), other = UUID(), first = UUID(), stale = UUID()
        precondition(state.begin(session, exists: false, token: first) == .sessionMissing)
        precondition(state.begin(session, token: first) == .acquired)
        precondition(state.begin(session, token: stale) == .busy)
        precondition(state.begin(other, token: UUID()) == .acquired)
        state.release(session, token: stale)
        precondition(state.begin(session, token: stale) == .busy)
        state.release(session, token: first)
        precondition(state.begin(session, token: stale) == .acquired)

        let competing = State(), target = UUID()
        let group = DispatchGroup()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                _ = competing.begin(target, token: UUID())
                group.leave()
            }
        }
        precondition(group.wait(timeout: .now() + 3) == .success)
        precondition(competing.successfulPreparations == 1)
        print("request slot checks passed")
    }
}
