import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol CFLChatTransport: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

/// The caller supplies an authenticated request and its same-origin header when required.
public final class CFLWebSocketTransport: CFLChatTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    public init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        task.resume()
    }
    public func send(_ text: String) async throws { try await task.send(.string(text)) }
    public func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            default: throw CFLFailure.protocolError
            }
        } catch {
            if task.closeCode == .policyViolation { throw CFLFailure.accessDenied }
            if let failure = error as? CFLFailure { throw failure }
            throw CFLFailure.offline
        }
    }
    public func close() async { task.cancel(with: .goingAway, reason: nil) }
}
