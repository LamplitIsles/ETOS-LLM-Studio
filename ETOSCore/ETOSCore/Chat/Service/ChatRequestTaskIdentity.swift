import Foundation

enum ChatRequestTaskIdentity {
    struct Value: Sendable {
        let sessionID: UUID
        let token: UUID
    }
    @TaskLocal static var current: Value?

    static func permits(sessionID: UUID, token: UUID) -> Bool {
        current.map { $0.sessionID == sessionID && $0.token == token } ?? true
    }
}
