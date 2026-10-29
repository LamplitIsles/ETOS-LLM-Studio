import Foundation

// Only the value types required by the production state are supplied here.
struct ConversationRunRequestConfiguration { let marker: UUID }
enum LocalAgentRunState { case completed, failed, cancelled }

private actor SuspendedOperation {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@main
struct BackgroundToolRequestChecks {
    static func main() async {
        var requests = ChatBackgroundToolRequests()
        let session = UUID(), token = UUID(), run = UUID(), marker = UUID()
        let first = requests.reserve(sessionID: session, token: token, runID: run, configuration: .init(marker: marker))
        let second = requests.reserve(sessionID: session, token: token, runID: run, configuration: .init(marker: marker))
        precondition(requests.configuration(sessionID: session, token: token, runID: run)?.marker == marker)
        precondition(requests.configuration(sessionID: session, token: UUID(), runID: run) == nil)
        precondition(requests.contains(sessionID: session, runID: run, token: token))
        precondition(!requests.contains(sessionID: session, runID: run, token: UUID()))
        precondition(requests.deferCleanup(sessionID: session, runID: run, state: .completed))
        precondition(requests.finish(id: first) == nil)
        let final = requests.finish(id: second)
        precondition(final?.0 == run && final?.1 == .completed)

        let operation = SuspendedOperation()
        let active = requests.reserve(sessionID: session, token: token, runID: run, configuration: .init(marker: marker))
        let gate = ChatRequestStartGate()
        let task = Task {
            do { try await gate.waitUntilRegistered() } catch { return }
            await operation.run()
        }
        requests.register(task, id: active, startGate: gate)
        await operation.waitUntilStarted()
        precondition(requests.cancel(sessionID: session, token: token) == [run])
        precondition(!requests.contains(sessionID: session, runID: run, token: token))
        precondition(requests.deferCleanup(sessionID: session, runID: run, state: .cancelled))
        precondition(requests.hasPending(runID: run))
        await operation.release()
        await task.value
        let cancelled = requests.finish(id: active)
        precondition(cancelled?.0 == run && cancelled?.1 == .cancelled)
        precondition(!requests.hasPending(runID: run))
        print("background tool request checks passed")
    }
}
