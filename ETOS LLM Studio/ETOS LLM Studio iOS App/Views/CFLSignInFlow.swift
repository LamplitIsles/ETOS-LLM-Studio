import Foundation

@MainActor
enum CFLSignInFlow {
    enum Result {
        case completed, cancelled, superseded
        case failed(Error)
    }

    static func run<Attempt>(
        begin: () async throws -> Attempt,
        authenticate: (Attempt) async throws -> URL,
        complete: (Attempt, URL) async throws -> Void,
        isCurrent: () -> Bool,
        isCancellation: (Error) -> Bool,
        isSuperseded: (Error) -> Bool
    ) async -> Result {
        do {
            let attempt = try await begin()
            let callback = try await authenticate(attempt)
            guard isCurrent() else { return .superseded }
            try await complete(attempt, callback)
            return isCurrent() ? .completed : .superseded
        } catch {
            guard isCurrent(), !isSuperseded(error) else { return .superseded }
            return isCancellation(error) ? .cancelled : .failed(error)
        }
    }
}
