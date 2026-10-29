import Foundation

/// A request task cannot enter execution until its owner has registered it.
final class ChatRequestStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilRegistered() async throws {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if isOpen { return true }
                precondition(waiter == nil, "request start gate has multiple waiters")
                waiter = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}
