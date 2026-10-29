import Foundation

/// The legacy provider receives a single request; an error is not proof that
/// it was not executed and therefore cannot trigger an automatic replay.
enum ChatSingleProviderRequest {
    static func run<Request, Context>(
        request: Request, loadingID: UUID, context: Context,
        operation: (Request, UUID, Context, @escaping (Error) async -> Bool) async -> Void
    ) async {
        await operation(request, loadingID, context) { _ in false }
    }
}
