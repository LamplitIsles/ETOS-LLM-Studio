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

/// HTTP requests are built by the client with fixed same-origin paths. Implementations
/// must not follow redirects; tests can inject an in-memory implementation.
public protocol CFLImageHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class CFLImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class CFLImageURLSession: CFLImageHTTP, @unchecked Sendable {
    public static let shared = CFLImageURLSession()
    private let session: URLSession
    public init() {
        session = URLSession(configuration: .default, delegate: CFLImageRedirectDelegate(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
