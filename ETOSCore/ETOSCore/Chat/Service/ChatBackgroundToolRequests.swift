import Foundation

/// Access is serialized by ChatService's request state lock.
struct ChatBackgroundToolRequests {
    private struct Request {
        let sessionID: UUID
        let token: UUID
        let runID: UUID?
        let configuration: ConversationRunRequestConfiguration?
        var task: Task<Void, Never>?
        var isRevoked = false
        var cleanupState: LocalAgentRunState?
    }

    private var requests: [UUID: Request] = [:]

    mutating func reserve(sessionID: UUID, token: UUID, runID: UUID?, configuration: ConversationRunRequestConfiguration?) -> UUID {
        let id = UUID()
        requests[id] = Request(sessionID: sessionID, token: token, runID: runID, configuration: configuration)
        return id
    }

    func configuration(sessionID: UUID, token: UUID, runID: UUID?) -> ConversationRunRequestConfiguration? {
        requests.values.first {
            !$0.isRevoked && $0.sessionID == sessionID && $0.token == token && (runID == nil || $0.runID == runID)
        }?.configuration
    }

    func contains(sessionID: UUID, runID: UUID, token: UUID) -> Bool {
        requests.values.contains { !$0.isRevoked && $0.sessionID == sessionID && $0.runID == runID && $0.token == token }
    }

    func contains(sessionID: UUID, token: UUID) -> Bool {
        requests.values.contains { !$0.isRevoked && $0.sessionID == sessionID && $0.token == token }
    }

    func hasPending(runID: UUID) -> Bool {
        requests.values.contains { $0.runID == runID }
    }

    mutating func register(_ task: Task<Void, Never>, id: UUID, startGate: ChatRequestStartGate) {
        if var request = requests[id] {
            request.task = task
            requests[id] = request
        } else {
            task.cancel()
        }
        startGate.open()
    }

    /// The last background task finishes run resources after the response ends.
    mutating func deferCleanup(sessionID: UUID, runID: UUID, state: LocalAgentRunState) -> Bool {
        let ids = requests.compactMap { id, request in
            request.sessionID == sessionID && request.runID == runID ? id : nil
        }
        ids.forEach { requests[$0]?.cleanupState = state }
        return !ids.isEmpty
    }

    mutating func finish(id: UUID) -> (UUID, LocalAgentRunState)? {
        guard let request = requests.removeValue(forKey: id), let state = request.cleanupState,
              let runID = request.runID,
              !requests.values.contains(where: { $0.runID == runID }) else { return nil }
        return (runID, state)
    }

    mutating func cancel(sessionID: UUID, token: UUID? = nil) -> [UUID] {
        let ids = requests.compactMap { id, request in
            request.sessionID == sessionID && (token == nil || request.token == token) ? id : nil
        }
        return ids.compactMap { id in
            guard var request = requests[id] else { return nil }
            request.isRevoked = true
            requests[id] = request
            request.task?.cancel()
            return request.runID
        }
    }
}
