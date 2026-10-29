import Foundation

@main
enum UnknownToolOutcomesChecks {
    static func main() {
        let session = UUID(), other = UUID()
        let first = ChatUnknownToolOutcome(id: UUID(), sessionID: session, messageID: UUID(), toolCallID: "a", toolName: "shortcut")
        let second = ChatUnknownToolOutcome(id: UUID(), sessionID: session, messageID: UUID(), toolCallID: "b", toolName: "shortcut")
        let otherRecord = ChatUnknownToolOutcome(id: UUID(), sessionID: other, messageID: UUID(), toolCallID: "a", toolName: "shortcut")
        var state = ChatUnknownToolOutcomes()
        state.record(first, sessionExists: true)
        state.record(second, sessionExists: true)
        state.record(otherRecord, sessionExists: true)
        precondition(state.snapshot()[session]?.count == 2)
        precondition(!state.acknowledge(sessionID: other, id: first.id))
        precondition(state.acknowledge(sessionID: session, id: first.id))
        precondition(state.snapshot()[session] == [second])
        state.removeSession(session)
        state.record(first, sessionExists: false) // late callback cannot revive a deleted session
        precondition(state.snapshot()[session] == nil)
        precondition(state.snapshot()[other] == [otherRecord])
        print("unknown tool outcome checks passed")
    }
}
