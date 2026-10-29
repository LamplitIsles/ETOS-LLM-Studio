import Foundation

/// Call while holding the same lock that protects the request contexts and sessions.
enum ChatRequestSlot {
    enum Outcome: Equatable {
        case acquired
        case busy
        case sessionMissing
    }

    /// Check and delete while holding the same lock used by request admission.
    static func busySessionIDs<Context>(
        in sessionIDs: Set<UUID>, contexts: [UUID: Context]
    ) -> Set<UUID> {
        Set(sessionIDs.filter { contexts[$0] != nil })
    }

    static func acquire<Context>(
        sessionID: UUID, sessionExists: Bool, contexts: inout [UUID: Context],
        makeContext: () -> Context
    ) -> Outcome {
        guard sessionExists else { return .sessionMissing }
        guard contexts[sessionID] == nil else { return .busy }
        contexts[sessionID] = makeContext()
        return .acquired
    }
}
