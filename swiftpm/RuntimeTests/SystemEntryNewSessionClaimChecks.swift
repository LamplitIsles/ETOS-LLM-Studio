import Foundation

private actor Claims {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

@MainActor private final class Sessions {
    var count = 0
    func create() -> UUID { count += 1; return UUID() }
}

@main struct SystemEntryNewSessionClaimChecks {
    @MainActor static func main() async {
        let claims = Claims(), sessions = Sessions()
        async let first = SystemEntryNewSessionClaim.createIfClaimed {
            await claims.claim()
        } create: { sessions.create() }
        async let second = SystemEntryNewSessionClaim.createIfClaimed {
            await claims.claim()
        } create: { sessions.create() }
        let results = await [first, second]
        precondition(results.compactMap { $0 }.count == 1 && sessions.count == 1)

        let cancelledSessions = Sessions()
        let task = Task { @MainActor in
            await SystemEntryNewSessionClaim.createIfClaimed {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            } create: { cancelledSessions.create() }
        }
        let cancelledResult = await task.value
        precondition(cancelledResult == nil && cancelledSessions.count == 0)
        print("system entry new session claim checks passed")
    }
}
