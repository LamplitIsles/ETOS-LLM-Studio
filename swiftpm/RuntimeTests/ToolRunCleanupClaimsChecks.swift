import Foundation

enum LocalAgentRunState { case completed, failed, cancelled }

@main
struct ToolRunCleanupClaimsChecks {
    static func main() {
        var claims = ChatToolRunCleanupClaims()
        let cancelledBeforeCommit = UUID()
        precondition(claims.claim(runID: cancelledBeforeCommit, state: .completed) == .claimed)
        precondition(claims.claim(runID: cancelledBeforeCommit, state: .cancelled) == .updated)
        precondition(claims.commit(runID: cancelledBeforeCommit, fallback: .completed) == .cancelled)
        precondition(claims.claim(runID: cancelledBeforeCommit, state: .completed) == .existing)

        let cancelledAfterCommit = UUID()
        precondition(claims.claim(runID: cancelledAfterCommit, state: .completed) == .claimed)
        precondition(claims.commit(runID: cancelledAfterCommit, fallback: .cancelled) == .completed)
        precondition(claims.claim(runID: cancelledAfterCommit, state: .cancelled) == .existing)
        precondition(claims.commit(runID: cancelledAfterCommit, fallback: .cancelled) == .completed)

        let failed = UUID()
        precondition(claims.claim(runID: failed, state: .failed) == .claimed)
        precondition(claims.claim(runID: failed, state: .completed) == .existing)
        precondition(claims.commit(runID: failed, fallback: .completed) == .failed)
        claims.markComplete(runID: failed)
        claims.forgetIfComplete(runID: failed, isReferenced: true)
        precondition(claims.claim(runID: failed, state: .completed) == .existing)
        claims.forgetIfComplete(runID: failed, isReferenced: false)
        precondition(claims.claim(runID: failed, state: .completed) == .claimed)
        print("tool run cleanup claim checks passed")
    }
}
