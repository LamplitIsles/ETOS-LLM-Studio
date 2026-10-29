import Foundation

private actor SideEffects {
    private(set) var count = 0
    func perform() { count += 1 }
}

@main
struct RequestStartGateChecks {
    static func main() async throws {
        let effects = SideEffects()

        // The owner cancels an invalid task before opening its gate.
        do {
            let gate = ChatRequestStartGate()
            let task = Task {
                try await gate.waitUntilRegistered()
                await effects.perform()
            }
            task.cancel()
            gate.open()
            do {
                try await task.value
                preconditionFailure("cancelled request passed the gate")
            } catch is CancellationError {
                // Expected.
            }
            let count = await effects.count
            precondition(count == 0, "cancelled request performed work")
        }

        let gate = ChatRequestStartGate()
        let task = Task {
            try await gate.waitUntilRegistered()
            await effects.perform()
        }
        gate.open()
        try await task.value
        let count = await effects.count
        precondition(count == 1, "registered request did not execute once")
        print("request start gate checks passed")
    }
}
