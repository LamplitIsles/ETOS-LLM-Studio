import Foundation

final class ChatService: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var releases = 0
    func releaseUnstartedRequest(sessionID: UUID, token: UUID) {
        lock.withLock { releases += 1 }
    }
}

@main struct ChatRequestLeaseChecks {
    static func main() {
        let service = ChatService()
        let first = ChatRequestLease(sessionID: UUID(), token: UUID(), service: service)
        precondition(first.claim(for: service))
        precondition(!first.claim(for: service))
        first.release()
        precondition(service.releases == 0, "caller released a handed-off request")
        first.finishPreparation()
        precondition(service.releases == 1)

        let second = ChatRequestLease(sessionID: UUID(), token: UUID(), service: service)
        second.release()
        precondition(!second.claim(for: service))
        precondition(service.releases == 2)
        print("request lease checks passed")
    }
}
