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
    public init(request: URLRequest, session: URLSession = CFLImageURLSession.socketSession) {
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
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: CFLImageRedirectDelegate(), delegateQueue: nil)
    }
    public static let socketSession = makeSession()
    public init() { session = Self.makeSession() }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// Authorizes each media request independently; never replays an upload after a failure.
public struct CFLAuthorizedHTTP: CFLImageHTTP {
    private let authorization: CFLAuthorization
    private let http: any CFLImageHTTP
    public init(authorization: CFLAuthorization, http: any CFLImageHTTP = CFLImageURLSession.shared) {
        self.authorization = authorization; self.http = http
    }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let authorized: URLRequest
        do { authorized = try await authorization.authenticatedRequest(request) }
        catch CFLAuthorizationError.authorizationRequired { throw CFLFailure.accessDenied }
        catch CFLAuthorizationError.storage { throw CFLFailure.storage }
        catch { throw CFLFailure.offline }
        let result = try await http.data(for: authorized)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            do { try await authorization.checkAfterTransportFailure() }
            catch CFLAuthorizationError.authorizationRequired { throw CFLFailure.accessDenied }
            catch CFLAuthorizationError.storage { throw CFLFailure.storage }
            catch { throw CFLFailure.offline }
            throw CFLFailure.offline
        }
        return result
    }
}

/// Wraps the socket so HTTP upgrade failures are checked against the auth status endpoint.
public final class CFLAuthorizedSocket: CFLChatTransport, @unchecked Sendable {
    private let socket: any CFLChatTransport
    private let authorization: CFLAuthorization
    public init(socket: any CFLChatTransport, authorization: CFLAuthorization) {
        self.socket = socket; self.authorization = authorization
    }
    private func classify(_ error: Error) async -> Error {
        if Task.isCancelled { return CFLFailure.offline }
        if let failure = error as? CFLFailure, failure == .protocolError { return failure }
        do { try await authorization.checkAfterTransportFailure(); return CFLFailure.offline }
        catch CFLAuthorizationError.authorizationRequired { return CFLFailure.accessDenied }
        catch CFLAuthorizationError.storage { return CFLFailure.storage }
        catch { return CFLFailure.offline }
    }
    public func send(_ text: String) async throws {
        do { try await socket.send(text) } catch { throw await classify(error) }
    }
    public func receive() async throws -> String {
        do { return try await socket.receive() } catch { throw await classify(error) }
    }
    public func close() async { await socket.close() }
}
