import Foundation

final class AppToolManager {}
enum SandboxFileToolSupport {
    struct SandboxUndoContext: Sendable { var validateAdmission: (@Sendable () throws -> Void)? }
    @TaskLocal static var undoContext: SandboxUndoContext?
    @TaskLocal static var fileSpace: UUID?
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var effects = 0
    func revoke() { lock.withLock { allowed = false } }
    func validate() throws { try lock.withLock { if !allowed { throw CancellationError() } } }
    func perform() { lock.withLock { effects += 1 } }
    func effectCount() -> Int { lock.withLock { effects } }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}

@main
struct SandboxOperationAdmissionChecks {
    static func main() async throws {
        let state = State()
        let atAdmission = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let context = SandboxFileToolSupport.SandboxUndoContext(validateAdmission: {
            atAdmission.signal()
            guard proceed.wait(timeout: .now() + 3) == .success else { throw CancellationError() }
            try state.validate()
        })
        let rejected = Task {
            try await SandboxFileToolSupport.$undoContext.withValue(context) {
                try await AppToolManager.runSandboxFileOperationOffMainThread { state.perform() }
            }
        }
        let admissionReached = await waitForSignal(atAdmission)
        precondition(admissionReached)
        state.revoke()
        proceed.signal()
        do { try await rejected.value; preconditionFailure("revoked operation started") }
        catch is CancellationError {}
        precondition(state.effectCount() == 0)

        let admittedState = State()
        let operationStarted = DispatchSemaphore(value: 0)
        let finishOperation = DispatchSemaphore(value: 0)
        let admittedContext = SandboxFileToolSupport.SandboxUndoContext(validateAdmission: { try admittedState.validate() })
        let admitted = Task {
            try await SandboxFileToolSupport.$undoContext.withValue(admittedContext) {
                try await AppToolManager.runSandboxFileOperationOffMainThread {
                    operationStarted.signal()
                    guard finishOperation.wait(timeout: .now() + 3) == .success else { throw CancellationError() }
                    admittedState.perform()
                }
            }
        }
        let operationReached = await waitForSignal(operationStarted)
        precondition(operationReached)
        admittedState.revoke()
        finishOperation.signal()
        try await admitted.value
        precondition(admittedState.effectCount() == 1)

        let ordinary = State()
        try await AppToolManager.runSandboxFileOperationOffMainThread { ordinary.perform() }
        precondition(ordinary.effectCount() == 1)
        let missingValidator = SandboxFileToolSupport.SandboxUndoContext(validateAdmission: nil)
        do {
            try await SandboxFileToolSupport.$undoContext.withValue(missingValidator) {
                try await AppToolManager.runSandboxFileOperationOffMainThread { ordinary.perform() }
            }
            preconditionFailure("trusted mutation without a validator started")
        } catch is CancellationError {}
        precondition(ordinary.effectCount() == 1)
        print("sandbox operation admission checks passed")
    }
}
