import Foundation

extension AppToolManager {
    static func runSandboxFileOperationOffMainThread<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        let undoContext = SandboxFileToolSupport.undoContext
        let fileSpace = SandboxFileToolSupport.fileSpace
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // A trusted mutation admitted here is drained by its run's
                    // operation lock before the run's resources are cleaned up.
                    if let undoContext {
                        guard let validate = undoContext.validateAdmission else { throw CancellationError() }
                        try validate()
                    }
                    let result = try SandboxFileToolSupport.$fileSpace.withValue(fileSpace) {
                        try SandboxFileToolSupport.$undoContext.withValue(undoContext) {
                            try operation()
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
