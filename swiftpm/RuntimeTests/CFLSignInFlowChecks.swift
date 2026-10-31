import Foundation

private enum FakeFailure: Error { case cancelled, superseded, invalidCallback }

@main
struct CFLSignInFlowChecks {
    @MainActor
    static func main() async {
        let callback = URL(string: "etosllmstudio://auth/callback?code=synthetic")!
        var began = 0
        var authenticated = 0
        var completed = 0
        var current = true

        func run(_ failure: FakeFailure? = nil, invalidate: Bool = false) async -> CFLSignInFlow.Result {
            await CFLSignInFlow.run(
                begin: { began += 1; return "attempt" },
                authenticate: { attempt in
                    precondition(attempt == "attempt")
                    authenticated += 1
                    if let failure, failure != .invalidCallback { throw failure }
                    if invalidate { current = false }
                    return callback
                },
                complete: { attempt, received in
                    precondition(attempt == "attempt" && received == callback)
                    completed += 1
                    if let failure { throw failure }
                },
                isCurrent: { current },
                isCancellation: { ($0 as? FakeFailure) == .cancelled },
                isSuperseded: { ($0 as? FakeFailure) == .superseded }
            )
        }

        guard case .completed = await run() else { fatalError("Sign-in should complete") }
        precondition(began == 1 && authenticated == 1 && completed == 1)
        guard case .cancelled = await run(.cancelled) else { fatalError("System cancellation should remain cancellation") }
        precondition(completed == 1)
        guard case .failed(let error) = await run(.invalidCallback),
              (error as? FakeFailure) == .invalidCallback else { fatalError("Invalid callback should be presented as failure") }
        precondition(completed == 2)
        guard case .superseded = await run(invalidate: true) else { fatalError("Stale sign-in must not complete") }
        precondition(completed == 2)
        print("CFL sign-in flow checks passed")
    }
}
