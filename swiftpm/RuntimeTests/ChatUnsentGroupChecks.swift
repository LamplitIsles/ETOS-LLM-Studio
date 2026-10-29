import Foundation

private struct Message: Equatable {
    let id: UUID
    var text: String
}

@main struct ChatUnsentGroupChecks {
    static func main() {
        let first = Message(id: UUID(), text: "one")
        let second = Message(id: UUID(), text: "two")
        let other = Message(id: UUID(), text: "other")
        let group = [first, second]

        func check(retained: Bool, cancelled: Bool = true, matches: Bool = true, started: Bool = false,
                   messages: inout [Message]) -> Bool {
            ChatUnsentGroup.remove(expected: group, messages: &messages, sourceRetained: retained,
                                   requestCancelled: cancelled, leaseMatches: matches, requestStarted: started,
                                   id: { $0.id })
        }
        var kept = group + [other]
        precondition(!check(retained: false, messages: &kept) && kept == group + [other])
        precondition(!check(retained: true, cancelled: false, messages: &kept))
        precondition(!check(retained: true, matches: false, messages: &kept))
        precondition(!check(retained: true, started: true, messages: &kept))
        precondition(kept == group + [other])
        precondition(check(retained: true, messages: &kept) && kept == [other])

        var edited = [first, Message(id: second.id, text: "changed"), other]
        let snapshot = edited
        precondition(!check(retained: true, messages: &edited) && edited == snapshot)
        var deleted = [first, other]
        precondition(!check(retained: true, messages: &deleted) && deleted == [first, other])
        print("unsent group checks passed")
    }
}
