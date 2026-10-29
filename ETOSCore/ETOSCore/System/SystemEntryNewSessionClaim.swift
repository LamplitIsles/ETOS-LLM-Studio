import Foundation

/// Only the requestID claimant may create a new session.
@MainActor enum SystemEntryNewSessionClaim {
    static func createIfClaimed<Session>(
        claim: () async -> Bool,
        create: @MainActor () -> Session
    ) async -> Session? {
        guard !Task.isCancelled, await claim(), !Task.isCancelled else { return nil }
        return create()
    }
}
