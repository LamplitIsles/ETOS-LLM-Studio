import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public enum CFLAuthorizationError: Error, Equatable, Sendable {
    case invalidOrigin, invalidCallback, cancelled, authorizationRequired, unavailable, storage, superseded
}

public struct CFLCredentials: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    // Persist before dispatch: after a crash the old rotating refresh token is never replayed.
    public var refreshPending: Bool
    public init(accessToken: String, refreshToken: String, expiresAt: Date, refreshPending: Bool = false) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.refreshPending = refreshPending
    }
}

public protocol CFLCredentialStore: Sendable {
    func load(origin: String) throws -> CFLCredentials?
    func save(_ credentials: CFLCredentials, origin: String) throws
}

#if canImport(Security)
public struct CFLKeychainCredentialStore: CFLCredentialStore {
    public init() {}
    private func query(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ETOS.CFL.OAuth", kSecAttrAccount as String: origin]
    }
    public func load(origin: String) throws -> CFLCredentials? {
        var q = query(origin)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credentials = try? JSONDecoder().decode(CFLCredentials.self, from: data) else { throw CFLAuthorizationError.storage }
        return credentials
    }
    public func save(_ credentials: CFLCredentials, origin: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let q = query(origin)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, changes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CFLAuthorizationError.storage }
        var item = q; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CFLAuthorizationError.storage }
    }
}
#endif

public struct CFLAuthorizationAttempt: Sendable {
    public let url: URL
    fileprivate let origin: String
    fileprivate let generation: Int
    fileprivate let state: String
    fileprivate let verifier: String
    fileprivate let id: UUID
}

/// One owner per active connection. Switching origins invalidates every outstanding callback and request.
public actor CFLAuthorization {
    public static let callback = "etosllmstudio://auth/callback"
    private let store: any CFLCredentialStore
    private let http: any CFLImageHTTP
    private var origin: String?
    private var generation = 0
    private var attempts: Set<UUID> = []
    private var latestAttempt: UUID?
    private var refresh: (id: UUID, generation: Int, task: Task<String, Error>)?
    // Opaque process-local cache identity. Never use credentials as a cache key.
    private var thumbnailScope = UUID()
    private var thumbnailCredential: String?
    private var thumbnailRefreshCredential: String?
    private var thumbnailRevoked = false
    private func invalidateThumbnailScope() {
        thumbnailScope = UUID(); thumbnailCredential = nil; thumbnailRefreshCredential = nil; thumbnailRevoked = false
    }
    func stickerThumbnailScope() throws -> UUID {
        guard let origin else { throw CFLAuthorizationError.authorizationRequired }
        let credentials: CFLCredentials
        do {
            guard let stored = try store.load(origin: origin) else {
                invalidateThumbnailScope(); throw CFLAuthorizationError.authorizationRequired
            }
            credentials = stored
        } catch let error as CFLAuthorizationError { throw error }
        catch { throw CFLAuthorizationError.storage }
        if thumbnailCredential != credentials.accessToken || thumbnailRefreshCredential != credentials.refreshToken {
            thumbnailScope = UUID(); thumbnailCredential = credentials.accessToken
            thumbnailRefreshCredential = credentials.refreshToken; thumbnailRevoked = false
        }
        if thumbnailRevoked { throw CFLAuthorizationError.authorizationRequired }
        // An uncertain refresh leaves this process-local identity unchanged;
        // stale cache can remain visible while authorization is investigated.
        return thumbnailScope
    }
    func stickerThumbnailAuthorizationUncertain() -> Bool {
        guard !thumbnailRevoked, let origin, let credentials = try? store.load(origin: origin) else { return false }
        return credentials.refreshPending
    }


    public init(store: any CFLCredentialStore, http: any CFLImageHTTP = CFLImageURLSession.shared) {
        self.store = store; self.http = http
    }
    public func select(origin value: String) throws {
        guard let normalized = CFLHTTPSOrigin.normalized(value), !normalized.isEmpty else { throw CFLAuthorizationError.invalidOrigin }
        invalidateThumbnailScope()
        origin = normalized; generation += 1; attempts.removeAll(); latestAttempt = nil; refresh = nil
    }
    public func begin() throws -> CFLAuthorizationAttempt {
        guard let origin else { throw CFLAuthorizationError.invalidOrigin }
        #if canImport(CryptoKit) && canImport(Security)
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CFLAuthorizationError.unavailable }
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let state = try random(), verifier = try random()
        let hash = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return makeAttempt(origin: origin, state: state, verifier: verifier, challenge: hash)
        #else
        throw CFLAuthorizationError.unavailable
        #endif
    }
    // Internal seam also lets the Foundation-only behavior checks supply synthetic PKCE values.
    func makeAttempt(origin: String, state: String, verifier: String, challenge: String) -> CFLAuthorizationAttempt {
        attempts.removeAll()
        var url = URLComponents(string: origin + "/api/auth/oauth2/authorize")!
        url.queryItems = ["client_id": "etos", "redirect_uri": Self.callback, "response_type": "code", "scope": "cfl offline_access", "resource": origin, "state": state, "code_challenge_method": "S256", "code_challenge": challenge].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let id = UUID(); attempts.insert(id); latestAttempt = id
        return CFLAuthorizationAttempt(url: url.url!, origin: origin, generation: generation, state: state, verifier: verifier, id: id)
    }
    public func complete(_ attempt: CFLAuthorizationAttempt, callback: URL) async throws {
        guard attempts.remove(attempt.id) != nil, origin == attempt.origin, generation == attempt.generation else { throw CFLAuthorizationError.superseded }
        guard let c = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              c.scheme == "etosllmstudio", c.host == "auth", c.port == nil, c.user == nil, c.password == nil,
              c.percentEncodedPath == "/callback", c.fragment == nil, let items = c.queryItems else { throw CFLAuthorizationError.invalidCallback }
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("state") == attempt.state, single("iss") == attempt.origin + "/api/auth" else { throw CFLAuthorizationError.invalidCallback }
        guard !items.contains(where: { $0.name == "error" }), let code = single("code"), !code.isEmpty else { throw CFLAuthorizationError.invalidCallback }
        // Once dispatched, a code may have been consumed even if its response is lost.
        // Preserve any old grant but prevent it from being silently used after uncertainty.
        do {
            if var existing = try store.load(origin: attempt.origin) {
                existing.refreshPending = true
                try store.save(existing, origin: attempt.origin)
            }
        } catch { throw CFLAuthorizationError.storage }
        // A valid code is now being dispatched: prevent a previous refresh from
        // overwriting this grant, while letting cancelled browser attempts leave it alone.
        invalidateThumbnailScope()
        generation += 1; refresh = nil
        let exchangeGeneration = generation
        let result = try await exchange(origin: attempt.origin, fields: ["grant_type": "authorization_code", "client_id": "etos", "redirect_uri": Self.callback, "code": code, "code_verifier": attempt.verifier, "resource": attempt.origin])
        guard origin == attempt.origin, generation == exchangeGeneration, latestAttempt == attempt.id else { throw CFLAuthorizationError.superseded }
        do { try store.save(result, origin: attempt.origin) } catch { throw CFLAuthorizationError.storage }
    }
    private func exchange(origin: String, fields: [String: String]) async throws -> CFLCredentials {
        var request = URLRequest(url: URL(string: origin + "/api/auth/oauth2/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        var form = URLComponents(); form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data: Data; let response: URLResponse
        do { (data, response) = try await http.data(for: request) } catch { throw CFLAuthorizationError.unavailable }
        guard let result = response as? HTTPURLResponse, result.url == request.url else { throw CFLAuthorizationError.unavailable }
        guard result.statusCode == 200 else {
            if [400, 401, 403].contains(result.statusCode) { throw CFLAuthorizationError.authorizationRequired }
            throw CFLAuthorizationError.unavailable
        }
        struct Tokens: Decodable { let access_token: String; let refresh_token: String; let expires_in: Double; let token_type: String }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data), !tokens.access_token.isEmpty,
              !tokens.refresh_token.isEmpty, tokens.expires_in > 0, tokens.token_type.lowercased() == "bearer" else { throw CFLAuthorizationError.unavailable }
        return CFLCredentials(accessToken: tokens.access_token, refreshToken: tokens.refresh_token, expiresAt: Date().addingTimeInterval(tokens.expires_in))
    }
    /// Returns a current token; a refresh is persisted as pending before dispatch and shared by concurrent callers.
    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let origin else { throw CFLAuthorizationError.invalidOrigin }
        let current = generation
        if let running = refresh, running.generation == current {
            let token = try await running.task.value
            guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
            return token
        }
        let stored: CFLCredentials
        do { guard let value = try store.load(origin: origin) else { throw CFLAuthorizationError.authorizationRequired }; stored = value }
        catch let error as CFLAuthorizationError { throw error } catch { throw CFLAuthorizationError.storage }
        guard !stored.refreshPending else { throw CFLAuthorizationError.authorizationRequired }
        if !forceRefresh && stored.expiresAt > Date().addingTimeInterval(30) { return stored.accessToken }
        var pending = stored; pending.refreshPending = true
        do { try store.save(pending, origin: origin) } catch { throw CFLAuthorizationError.storage }
        let id = UUID()
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CFLAuthorizationError.superseded }
            return try await self.finishRefresh(origin: origin, generation: current, token: stored.refreshToken)
        }
        refresh = (id, current, task)
        do {
            let token = try await task.value
            if refresh?.id == id { refresh = nil }
            guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
            return token
        } catch {
            if refresh?.id == id { refresh = nil }
            throw error
        }
    }
    private func finishRefresh(origin: String, generation current: Int, token: String) async throws -> String {
        let result: CFLCredentials
        do { result = try await exchange(origin: origin, fields: ["grant_type": "refresh_token", "client_id": "etos", "refresh_token": token, "resource": origin]) }
        catch CFLAuthorizationError.authorizationRequired {
            guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
            thumbnailRevoked = true
            throw CFLAuthorizationError.authorizationRequired
        }
        guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
        do { try store.save(result, origin: origin) } catch { throw CFLAuthorizationError.storage }
        return result.accessToken
    }
    public func authenticatedRequest(_ request: URLRequest) async throws -> URLRequest {
        guard let origin, let url = request.url,
              let requestOrigin = URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap({ parts -> String? in
                  var p = URLComponents(); p.scheme = parts.scheme == "wss" ? "https" : parts.scheme; p.host = parts.host; p.port = parts.port
                  return p.string.flatMap(CFLHTTPSOrigin.normalized)
              }), requestOrigin == origin else { throw CFLAuthorizationError.invalidOrigin }
        let current = generation
        let token = try await accessToken()
        guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
        var result = request; result.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        result.setValue(origin, forHTTPHeaderField: "Origin")
        return result
    }
    /// Check a failed socket or HTTP request without treating a network outage as revocation.
    public func checkAfterTransportFailure() async throws {
        guard let origin else { throw CFLAuthorizationError.invalidOrigin }
        let current = generation
        let token = try await accessToken()
        guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
        var request = URLRequest(url: URL(string: origin + "/api/auth/status")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let data: Data; let response: URLResponse
        do { (data, response) = try await http.data(for: request) } catch { throw CFLAuthorizationError.unavailable }
        guard self.origin == origin, generation == current else { throw CFLAuthorizationError.superseded }
        guard let http = response as? HTTPURLResponse, http.url == request.url, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String else { throw CFLAuthorizationError.unavailable }
        if state == "signed_in" { return }
        if state == "setup" { thumbnailRevoked = true; throw CFLAuthorizationError.authorizationRequired }
        guard state == "signed_out" else { throw CFLAuthorizationError.unavailable }
        let latest = try await accessToken()
        if latest != token { return }
        _ = try await accessToken(forceRefresh: true)
    }

}
