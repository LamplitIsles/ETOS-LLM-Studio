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
    private let lock = NSLock()
    private var redirectPolicy: CFLExternalImageCachePolicy = .lastAccess
    func cachedCopyPolicy() -> CFLExternalImageCachePolicy { lock.lock(); defer { lock.unlock() }; return redirectPolicy }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let hop = CFLExternalImageLoader.cachePolicy(response, redirectPolicy: .lastAccess)
        redirectPolicy = CFLExternalImageLoader.combinePolicies(redirectPolicy, hop)
        lock.unlock()
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

enum CFLExternalImageCachePolicy: Sendable, Equatable {
    case prohibited
    case lastAccess
    case until(Date)
}

/// A separate, credential-free HTTPS pipeline for external Markdown images.
/// The caller owns task cancellation and discards results after its view or context changes.
public struct CFLExternalImageLoader: Sendable {
    private let http: (any CFLImageHTTP)?
    public init() { http = nil }
    // Internal seam for test-owned fake responses; production always uses the isolated session.
    init(http: any CFLImageHTTP) { self.http = http }

    public func data(for source: String) async throws -> Data {
        try await response(for: source).data
    }
    /// Every redirect is inspected; explicit storage prohibitions are honored.
    /// A response without freshness headers uses the ordinary seven-day cache.
    func response(for source: String) async throws -> (data: Data, policy: CFLExternalImageCachePolicy) {
        guard let url = URL(string: source), let request = CFLExternalImageRequest.make(url) else { throw CFLFailure.invalidInput }
        try Task.checkCancellation()
        let result: (Data, URLResponse), redirectPolicy: CFLExternalImageCachePolicy
        if let http {
            result = try await http.data(for: request)
            // The fake seam supplies only the final response, so it cannot
            // establish the headers of any redirects it reports.
            redirectPolicy = result.1.url == request.url ? .lastAccess : .prohibited
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            let delegate = CFLExternalImageDelegate()
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            result = try await session.data(for: request)
            redirectPolicy = delegate.cachedCopyPolicy()
        }
        let (data, response) = result
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let finalURL = response.url,
              CFLExternalImageRequest.make(finalURL) != nil else { throw CFLFailure.protocolError }
        guard (200...299).contains(response.statusCode) else { throw CFLFailure.requestFailed }
        return (data, Self.cachePolicy(response, redirectPolicy: redirectPolicy))
    }
    static func permitsStorage(_ response: HTTPURLResponse) -> Bool {
        guard response.value(forHTTPHeaderField: "Vary") == nil,
              response.value(forHTTPHeaderField: "Pragma")?.lowercased().contains("no-cache") != true else { return false }
        let header = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        return !header.split(separator: ",").contains(where: { directive in
            let name = directive.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            return name == "no-store" || name == "no-cache"
        })
    }
    static func combinePolicies(_ first: CFLExternalImageCachePolicy, _ second: CFLExternalImageCachePolicy) -> CFLExternalImageCachePolicy {
        switch (first, second) {
        case (.prohibited, _), (_, .prohibited): return .prohibited
        case (.lastAccess, let other), (let other, .lastAccess): return other
        case (.until(let first), .until(let second)): return .until(min(first, second))
        }
    }
    static func cachePolicy(_ response: HTTPURLResponse, redirectPolicy: CFLExternalImageCachePolicy) -> CFLExternalImageCachePolicy {
        combinePolicies(redirectPolicy, responsePolicy(response))
    }
    private static func responsePolicy(_ response: HTTPURLResponse) -> CFLExternalImageCachePolicy {
        guard permitsStorage(response) else { return .prohibited }
        let header = response.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
        let directives = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ages = directives.filter { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == "max-age" }
        let expires = response.value(forHTTPHeaderField: "Expires")
        if ages.isEmpty && expires == nil { return .lastAccess }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let now = Date()
        let date: Date
        if let raw = response.value(forHTTPHeaderField: "Date") {
            guard let parsed = formatter.date(from: raw) else { return .prohibited }
            date = parsed
        } else { date = now }
        guard let age = TimeInterval(response.value(forHTTPHeaderField: "Age") ?? "0"), age >= 0, age.isFinite else { return .prohibited }
        let lifetime: TimeInterval
        if !ages.isEmpty {
            let parts = ages[0].split(separator: "=", maxSplits: 1)
            guard ages.count == 1, parts.count == 2,
                  let seconds = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)), seconds > 0, seconds.isFinite else { return .prohibited }
            lifetime = seconds
        } else {
            guard let expires, let expiry = formatter.date(from: expires) else { return .prohibited }
            lifetime = expiry.timeIntervalSince(date)
        }
        let remaining = min(lifetime - max(age, now.timeIntervalSince(date)), 7 * 24 * 60 * 60)
        guard remaining > 0, remaining.isFinite else { return .prohibited }
        return .until(now.addingTimeInterval(remaining))
    }
}

/// Optional cache identity provider; an opaque scope changes when login identity or origin changes.
/// A transport without this capability never serves or retains thumbnail cache entries.
public protocol CFLStickerCacheAuthority: Sendable {
    func stickerThumbnailScope() async throws -> UUID
}

/// A private, reconstructible application copy, never the pending-send store.
/// Implementations serialize operations and apply a shared capacity budget.
public protocol CFLMediaCache: Sendable {
    func read(key: String) async throws -> Data?
    func write(_ data: Data, key: String, withoutExpiry: Bool) async throws
    /// Atomically transform a small metadata value within the same cache store.
    func update(key: String, withoutExpiry: Bool,
                transform: @Sendable (Data?) -> Data?) async throws
    func remove(key: String) async throws
}

/// Authorizes each media request independently; never replays an upload after a failure.
public struct CFLAuthorizedHTTP: CFLImageHTTP, CFLStickerCacheAuthority {
    private let authorization: CFLAuthorization
    private let http: any CFLImageHTTP
    public init(authorization: CFLAuthorization, http: any CFLImageHTTP = CFLImageURLSession.shared) {
        self.authorization = authorization; self.http = http
    }
    public func stickerThumbnailScope() async throws -> UUID {
        do { return try await authorization.stickerThumbnailScope() }
        catch CFLAuthorizationError.authorizationRequired { throw CFLFailure.accessDenied }
        catch CFLAuthorizationError.storage { throw CFLFailure.storage }
        catch { throw CFLFailure.offline }
    }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let authorized: URLRequest
        do { authorized = try await authorization.authenticatedRequest(request) }
        catch CFLAuthorizationError.authorizationRequired {
            if request.url?.path.hasPrefix("/api/stickers/media/") == true,
               request.url?.path.hasSuffix("/thumbnail") == true,
               await authorization.stickerThumbnailAuthorizationUncertain() { throw CFLFailure.offline }
            throw CFLFailure.accessDenied
        }
        catch CFLAuthorizationError.storage { throw CFLFailure.storage }
        catch { throw CFLFailure.offline }
        let result = try await http.data(for: authorized)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            // A thumbnail-specific 403 is a resource read failure; preserve it
            // for the caller without treating it as confirmed login loss.
            if response.statusCode == 403, request.url?.path.hasPrefix("/api/stickers/media/") == true,
               request.url?.path.hasSuffix("/thumbnail") == true { return result }
            do { try await authorization.checkAfterTransportFailure() }
            catch CFLAuthorizationError.authorizationRequired {
                if request.url?.path.hasPrefix("/api/stickers/media/") == true,
                   request.url?.path.hasSuffix("/thumbnail") == true,
                   await authorization.stickerThumbnailAuthorizationUncertain() { throw CFLFailure.offline }
                throw CFLFailure.accessDenied
            }
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
