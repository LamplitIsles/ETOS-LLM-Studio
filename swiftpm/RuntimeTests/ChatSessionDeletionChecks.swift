import Foundation

private struct Context {
    let token: UUID
    var cancelled = false
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: Set<UUID>
    private var contexts: [UUID: Context] = [:]

    init(_ sessions: Set<UUID>) { self.sessions = sessions }

    func begin(_ session: UUID, token: UUID) -> ChatRequestSlot.Outcome {
        lock.withLock {
            ChatRequestSlot.acquire(sessionID: session, sessionExists: sessions.contains(session),
                                    contexts: &contexts) { Context(token: token) }
        }
    }

    func stop(_ session: UUID, token: UUID) -> Bool {
        lock.withLock {
            guard var context = contexts[session], context.token == token, !context.cancelled else { return false }
            context.cancelled = true
            contexts[session] = context
            return true
        }
    }

    func senderFinished(_ session: UUID, token: UUID) {
        lock.withLock {
            guard let context = contexts[session], context.token == token, !context.cancelled else { return }
            contexts.removeValue(forKey: session)
        }
    }

    func stopFinished(_ session: UUID, token: UUID) {
        lock.withLock {
            guard let context = contexts[session], context.token == token, context.cancelled else { return }
            contexts.removeValue(forKey: session)
        }
    }

    func delete(_ targets: Set<UUID>) -> Set<UUID> {
        lock.withLock {
            let busy = ChatRequestSlot.busySessionIDs(in: targets, contexts: contexts)
            if busy.isEmpty { sessions.subtract(targets) }
            return busy
        }
    }
}

@main struct ChatSessionDeletionChecks {
    static func main() {
        let first = UUID(), second = UUID(), token = UUID()
        let state = State([first, second])
        precondition(state.begin(first, token: token) == .acquired)
        precondition(state.delete([first, second]) == [first])
        precondition(state.begin(second, token: UUID()) == .acquired, "busy batch deleted another session")
        precondition(state.stop(first, token: token))
        precondition(!state.stop(first, token: token), "two stop owners")
        state.senderFinished(first, token: token)
        precondition(state.delete([first]) == [first], "sender cleared stopping session")
        state.stopFinished(first, token: UUID())
        precondition(state.delete([first]) == [first], "stale token cleared stopping session")
        state.stopFinished(first, token: token)
        precondition(state.delete([first]).isEmpty)
        precondition(state.begin(first, token: UUID()) == .sessionMissing)

        let deletedFirst = UUID()
        let deletedState = State([deletedFirst])
        precondition(deletedState.delete([deletedFirst]).isEmpty)
        precondition(deletedState.begin(deletedFirst, token: UUID()) == .sessionMissing)

        // If admission wins, deletion must reject; if deletion wins, admission
        // must see a missing session. The state lock covers check and mutation.
        for _ in 0..<100 {
            let session = UUID(), competing = State([session])
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                _ = competing.begin(session, token: UUID())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                _ = competing.delete([session])
                group.leave()
            }
            precondition(group.wait(timeout: .now() + 3) == .success)
            let busy = competing.delete([session])
            let outcome = competing.begin(session, token: UUID())
            precondition((busy == [session] && outcome == .busy)
                         || (busy.isEmpty && outcome == .sessionMissing))
        }
        print("session deletion admission checks passed")
    }
}
