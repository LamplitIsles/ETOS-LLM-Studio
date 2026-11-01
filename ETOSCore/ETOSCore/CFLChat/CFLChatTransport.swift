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

/// HTTP transport seam. For authenticated CFL requests, implementations must not
/// follow redirects; tests can inject an in-memory implementation.
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

/// Builds a fresh GET for the initial destination and every redirect. Never copy
/// headers from the proposed redirect request, which can contain credentials.
enum CFLExternalImageRequest {
    static func make(_ url: URL) -> URLRequest? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

final class CFLExternalImageDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap(CFLExternalImageRequest.make))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Let the system validate TLS normally; do not answer HTTP or proxy auth challenges.
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private final class CFLExternalImageURLSession: CFLImageHTTP, @unchecked Sendable {
    static let shared = CFLExternalImageURLSession()
    private let session: URLSession
    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: CFLExternalImageDelegate(), delegateQueue: nil)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// A separate, credential-free HTTPS pipeline for external Markdown images.
/// The caller owns task cancellation and discards results after its view or context changes.
public struct CFLExternalImageLoader: Sendable {
    private let http: any CFLImageHTTP
    public init() { http = CFLExternalImageURLSession.shared }
    // Internal seam for test-owned fake responses; production always uses the isolated session.
    init(http: any CFLImageHTTP) { self.http = http }

    public func data(for source: String) async throws -> Data {
        guard let url = URL(string: source), let request = CFLExternalImageRequest.make(url) else { throw CFLFailure.invalidInput }
        try Task.checkCancellation()
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let finalURL = response.url,
              CFLExternalImageRequest.make(finalURL) != nil else { throw CFLFailure.protocolError }
        guard (200...299).contains(response.statusCode) else { throw CFLFailure.requestFailed }
        return data
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
