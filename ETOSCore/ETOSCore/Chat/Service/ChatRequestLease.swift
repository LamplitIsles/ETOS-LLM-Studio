import Foundation

/// A process-local right to start one request in one session. It is not a delivery receipt.
public final class ChatRequestLease: @unchecked Sendable {
    public let sessionID: UUID
    let token: UUID
    private weak var service: ChatService?
    private let lock = NSLock()
    private var claimed = false
    private var inputAccepted = false

    init(sessionID: UUID, token: UUID, service: ChatService) {
        self.sessionID = sessionID
        self.token = token
        self.service = service
    }

    func claim(for service: ChatService) -> Bool {
        lock.withLock {
            guard self.service === service, !claimed else { return false }
            claimed = true
            return true
        }
    }

    /// A local message-group result only; it says nothing about server delivery.
    public var wasInputAccepted: Bool { lock.withLock { inputAccepted } }
    func setInputAccepted(_ value: Bool) { lock.withLock { inputAccepted = value } }

    /// Release a reservation that has not been handed to a request. Once handed
    /// off, cancel through ChatService so the owner can finish its cleanup.
    public func release() {
        let unused = lock.withLock { () -> Bool in
            guard !claimed else { return false }
            claimed = true
            return true
        }
        if unused { service?.releaseUnstartedRequest(sessionID: sessionID, token: token) }
    }

    func finishPreparation() { service?.releaseUnstartedRequest(sessionID: sessionID, token: token) }

    deinit { release() }
}

public enum ChatRequestAdmissionError: Error, Sendable {
    case busy
    case sessionMissing
}
