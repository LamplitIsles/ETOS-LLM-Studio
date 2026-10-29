import Foundation

enum ChatUnsentGroup {
    /// The caller holds the request/session lock and has checked the lease and
    /// that the request task has not been registered.
    static func remove<Message: Equatable, ID: Hashable>(
        expected: [Message], messages: inout [Message], sourceRetained: Bool,
        requestCancelled: Bool, leaseMatches: Bool, requestStarted: Bool,
        id: (Message) -> ID
    ) -> Bool {
        guard sourceRetained, requestCancelled, leaseMatches, !requestStarted else { return false }
        guard !expected.isEmpty, Set(expected.map(id)).count == expected.count else { return false }
        for item in expected {
            let matches = messages.filter { id($0) == id(item) }
            guard matches.count == 1, matches[0] == item else { return false }
        }
        let ids = Set(expected.map(id))
        messages.removeAll { ids.contains(id($0)) }
        return true
    }
}
