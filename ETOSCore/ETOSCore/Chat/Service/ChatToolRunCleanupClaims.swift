import Foundation

/// The caller serializes access with the request state lock.
struct ChatToolRunCleanupClaims {
    enum ClaimResult { case claimed, updated, existing }
    private struct Claim {
        var state: LocalAgentRunState
        var committed = false
        var complete = false
    }
    private var claims: [UUID: Claim] = [:]

    mutating func claim(runID: UUID, state: LocalAgentRunState) -> ClaimResult {
        if var existing = claims[runID] {
            if state == .cancelled && existing.state == .completed && !existing.committed {
                existing.state = .cancelled
                claims[runID] = existing
                return .updated
            }
            return .existing
        }
        claims[runID] = Claim(state: state)
        return .claimed
    }

    /// This is the terminal-state commit point; later cancellation cannot change it.
    mutating func commit(runID: UUID, fallback: LocalAgentRunState) -> LocalAgentRunState {
        guard var claim = claims[runID] else { return fallback }
        claim.committed = true
        claims[runID] = claim
        return claim.state
    }

    mutating func markComplete(runID: UUID) { claims[runID]?.complete = true }

    mutating func forgetIfComplete(runID: UUID, isReferenced: Bool) {
        if !isReferenced && claims[runID]?.complete == true { claims.removeValue(forKey: runID) }
    }
}
