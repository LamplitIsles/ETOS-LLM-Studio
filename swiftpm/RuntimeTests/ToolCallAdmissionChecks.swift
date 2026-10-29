import Foundation

private struct Call: Equatable {
    let id: String
    let name: String
    let arguments: String
}

@main
enum ToolCallAdmissionChecks {
    static func main() {
        let expected = Call(id: "call", name: "tool", arguments: "one")
        func admitted(_ authorized: Bool, _ calls: [Call]?) -> Bool {
            ChatToolCallAdmission.permits(authorized: authorized, calls: calls) { $0 == expected }
        }
        precondition(admitted(true, [expected]))
        precondition(!admitted(false, [expected])) // token revoked
        precondition(!admitted(true, nil)) // message removed
        precondition(!admitted(true, [])) // call removed
        precondition(!admitted(true, [Call(id: "call", name: "tool", arguments: "changed")]))
        precondition(!admitted(true, [Call(id: "other", name: "tool", arguments: "one")]))

        // Model a permission wait: the call is checked again after the wait,
        // so deleting it during approval prevents the simulated side effect.
        let lock = NSLock()
        var calls: [Call]? = [expected]
        var executions = 0
        func startIfAdmitted() {
            lock.lock()
            let allowed = admitted(true, calls)
            if allowed { executions += 1 }
            lock.unlock()
        }
        precondition(admitted(true, calls))
        lock.lock()
        calls = nil
        lock.unlock()
        startIfAdmitted()
        precondition(executions == 0)
        lock.lock()
        calls = [expected]
        lock.unlock()
        startIfAdmitted()
        precondition(executions == 1)
        precondition(ChatToolRetryDecision.decide(storedResult: "   ", embeddedResult: nil) == .outcomeUnknown)
        precondition(ChatToolRetryDecision.decide(storedResult: nil, embeddedResult: nil) == .outcomeUnknown)
        precondition(ChatToolRetryDecision.decide(storedResult: " done ", embeddedResult: "old") == .reuse("done"))
        precondition(ChatToolRetryDecision.decide(storedResult: nil, embeddedResult: " saved ") == .reuse("saved"))
        let beforeUnknownRetry = executions
        if case .reuse = ChatToolRetryDecision.decide(storedResult: nil, embeddedResult: nil) {
            executions += 1
        }
        precondition(executions == beforeUnknownRetry)
        print("tool call admission checks passed")
    }
}
