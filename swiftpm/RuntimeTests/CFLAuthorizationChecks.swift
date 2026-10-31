import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MemoryCredentials: CFLCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CFLCredentials] = [:]
    func load(origin: String) throws -> CFLCredentials? { lock.lock(); defer { lock.unlock() }; return values[origin] }
    func save(_ credentials: CFLCredentials, origin: String) throws { lock.lock(); defer { lock.unlock() }; values[origin] = credentials }
}
actor AuthHTTP: CFLImageHTTP {
    enum Mode { case tokens, network, signedOut, signedIn, hold, revoked, codeTokens, denied401, denied403, deniedOffline, redirect, setup, setupMedia }
    var mode: Mode = .tokens
    var requests: [URLRequest] = []
    var held: CheckedContinuation<Void, Never>?
    func set(_ value: Mode) { mode = value }
    func release() { held?.resume(); held = nil }
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
    func paths(from index: Int) -> [String] { requests.dropFirst(index).compactMap { $0.url?.path } }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let selected = mode
        if selected == .hold { await withCheckedContinuation { held = $0 } }
        if selected == .network || (selected == .deniedOffline && request.url!.path == "/api/auth/status") { throw URLError(.timedOut) }
        if [Mode.denied401, .denied403, .deniedOffline, .setupMedia].contains(selected), request.url!.path == "/api/chat/images" {
            let status = selected == .denied403 ? 403 : 401
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if selected == .redirect && request.url!.path == "/api/auth/oauth2/token" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.test/token"])!)
        }
        if [Mode.revoked, .denied401, .denied403].contains(selected) && request.url!.path == "/api/auth/oauth2/token" {
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let body: String
        switch selected {
        case .signedOut where request.url!.path == "/api/auth/status", .revoked where request.url!.path == "/api/auth/status", .denied401 where request.url!.path == "/api/auth/status", .denied403 where request.url!.path == "/api/auth/status": body = "{\"state\":\"signed_out\"}"
        case .setup where request.url!.path == "/api/auth/status", .setupMedia where request.url!.path == "/api/auth/status": body = "{\"state\":\"setup\"}"
        case .signedIn: body = "{\"state\":\"signed_in\"}"
        case .codeTokens: body = "{\"access_token\":\"code-access\",\"refresh_token\":\"code-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
        default: body = "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
struct BrokenSocket: CFLChatTransport {
    func send(_ text: String) async throws { throw CFLFailure.offline }
    func receive() async throws -> String { throw CFLFailure.offline }
    func close() async {}
}
actor SetupPendingStore: CFLPendingStore {
    var entries: [CFLPending]
    init(_ entries: [CFLPending]) { self.entries = entries }
    func load() -> [CFLPending] { entries }
    func save(_ value: [CFLPending]) { entries = value }
}
actor SetupSocket: CFLChatTransport {
    private var sent: [String] = []
    private var waiting: CheckedContinuation<String, Error>?
    private var closed = false
    func send(_ text: String) async throws { sent.append(text); throw CFLFailure.offline }
    func receive() async throws -> String {
        if closed { throw CFLFailure.offline }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() async { closed = true; waiting?.resume(throwing: CFLFailure.offline); waiting = nil }
    func sentFrames() -> [String] { sent }
}
@main struct CFLAuthorizationChecks {
    static func main() async throws {
        let origin = "https://example.test"
        let store = MemoryCredentials(), http = AuthHTTP()
        try store.save(CFLCredentials(accessToken: "old", refreshToken: "rotate", expiresAt: .distantPast), origin: origin)
        let auth = CFLAuthorization(store: store, http: http)
        try await auth.select(origin: "https://EXAMPLE.test:443/")
        await http.set(.hold)
        let first = Task { try await auth.accessToken() }
        while await http.count() == 0 { await Task.yield() }
        let marked = try store.load(origin: origin)?.refreshPending; precondition(marked == true)
        let second = Task { try await auth.accessToken() }
        await http.release()
        let a = try await first.value, b = try await second.value
        precondition(a == "new-access" && b == a)
        let concurrentCount = await http.count(); precondition(concurrentCount == 1)
        let refreshed = try store.load(origin: origin)!
        precondition(refreshed.refreshToken == "new-refresh" && !refreshed.refreshPending)
        let refreshRequest = await http.last()!
        precondition(refreshRequest.url?.absoluteString == origin + "/api/auth/oauth2/token")
        let body = String(data: refreshRequest.httpBody!, encoding: .utf8)!
        precondition(body.contains("grant_type=refresh_token") && body.contains("refresh_token=rotate"))
        let request = URLRequest(url: URL(string: origin + "/api/chat/media/id/original")!)
        let signed = try await auth.authenticatedRequest(request)
        precondition(signed.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        precondition(signed.value(forHTTPHeaderField: "Origin") == origin)
        do { _ = try await auth.authenticatedRequest(URLRequest(url: URL(string: "https://evil.test/api")!)); preconditionFailure() }
        catch CFLAuthorizationError.invalidOrigin { }
        await http.set(.network)
        do { try await auth.checkAfterTransportFailure(); preconditionFailure() } catch CFLAuthorizationError.unavailable { }
        let intact = try store.load(origin: origin)?.refreshPending; precondition(intact == false)
        do { _ = try await auth.accessToken(forceRefresh: true); preconditionFailure() } catch CFLAuthorizationError.authorizationRequired { }
        let uncertain = try store.load(origin: origin)?.refreshPending; precondition(uncertain == true)
        let prior = await http.count()
        do { _ = try await auth.accessToken(); preconditionFailure() } catch CFLAuthorizationError.authorizationRequired { }
        let afterRetry = await http.count(); precondition(afterRetry == prior)
        try store.save(CFLCredentials(accessToken: "old", refreshToken: "once", expiresAt: .distantPast), origin: origin)
        await http.set(.hold)
        let late = Task { try await auth.accessToken() }
        while await http.count() == prior { await Task.yield() }
        try await auth.select(origin: "https://other.test")
        try await auth.select(origin: origin)
        await http.release()
        do { _ = try await late.value; preconditionFailure() } catch CFLAuthorizationError.superseded { }
        let stale = try store.load(origin: origin)?.refreshPending; precondition(stale == true)
        // Beginning and then cancelling browser login must not invalidate a refresh already in flight.
        try store.save(CFLCredentials(accessToken: "old", refreshToken: "cancel-refresh", expiresAt: .distantPast), origin: origin)
        await http.set(.hold)
        let beforeCancellation = await http.count()
        let refreshingDuringLogin = Task { try await auth.accessToken() }
        while await http.count() == beforeCancellation { await Task.yield() }
        _ = await auth.makeAttempt(origin: origin, state: "cancelled", verifier: "v", challenge: "c")
        // The UI's cancellation path never calls complete.
        await http.release()
        let retainedToken = try await refreshingDuringLogin.value
        precondition(retainedToken == "new-access")
        let retainedGrant = try store.load(origin: origin)!
        precondition(retainedGrant.refreshToken == "new-refresh" && !retainedGrant.refreshPending)
        // A valid callback replaces an older in-flight refresh without permitting its late reply to overwrite the new grant.
        try store.save(CFLCredentials(accessToken: "old", refreshToken: "race-refresh", expiresAt: .distantPast), origin: origin)
        await http.set(.hold)
        let beforeRace = await http.count()
        let oldRefresh = Task { try await auth.accessToken() }
        while await http.count() == beforeRace { await Task.yield() }
        let replacement = await auth.makeAttempt(origin: origin, state: "race", verifier: "v", challenge: "c")
        await http.set(.codeTokens)
        try await auth.complete(replacement, callback: URL(string: "etosllmstudio://auth/callback?state=race&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!)
        await http.release()
        do { _ = try await oldRefresh.value; preconditionFailure() } catch CFLAuthorizationError.superseded { }
        let replacementGrant = try store.load(origin: origin)!
        precondition(replacementGrant.accessToken == "code-access" && replacementGrant.refreshToken == "code-refresh" && !replacementGrant.refreshPending)
        // Callback parameters are checked before exchanging, and an attempt is single-use.
        try await auth.select(origin: origin)
        await http.set(.tokens)
        let invalid = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
        let params = URLComponents(url: invalid.url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(params.contains(URLQueryItem(name: "scope", value: "cfl offline_access")))
        precondition(params.contains(URLQueryItem(name: "resource", value: origin)))
        precondition(params.contains(URLQueryItem(name: "code_challenge_method", value: "S256")))
        let beforeInvalid = await http.count()
        do { try await auth.complete(invalid, callback: URL(string: "etosllmstudio://auth/callback?state=wrong&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!); preconditionFailure() } catch CFLAuthorizationError.invalidCallback { }
        do { try await auth.complete(invalid, callback: URL(string: "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!); preconditionFailure() } catch CFLAuthorizationError.superseded { }
        let invalidCount = await http.count(); precondition(beforeInvalid == invalidCount)
        for bad in ["etosllmstudio://auth/wrong?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one", "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fevil.test%2Fapi%2Fauth&code=one", "etosllmstudio://auth/callback?state=expected&state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one"] {
            let attempt = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
            do { try await auth.complete(attempt, callback: URL(string: bad)!); preconditionFailure() } catch CFLAuthorizationError.invalidCallback { }
        }
        // OAuth error callbacks and malformed code parameters are failures, not system-sheet cancellation.
        let original = CFLCredentials(accessToken: "preserved-access", refreshToken: "preserved-refresh", expiresAt: .distantFuture)
        try store.save(original, origin: origin)
        let beforeBadCodes = await http.count()
        let callbackBase = "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth"
        for suffix in ["&error=access_denied&error_description=private-server-detail", "", "&code=", "&code=one&code=two", "&code=one&error=access_denied"] {
            let attempt = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
            do { try await auth.complete(attempt, callback: URL(string: callbackBase + suffix)!); preconditionFailure("invalid callback accepted") }
            catch CFLAuthorizationError.invalidCallback { }
            let kept = try store.load(origin: origin)!
            precondition(kept.accessToken == original.accessToken && kept.refreshToken == original.refreshToken && kept.expiresAt == original.expiresAt && kept.refreshPending == original.refreshPending)
            let token = try await auth.accessToken(); precondition(token == original.accessToken)
        }
        let afterBadCodes = await http.count(); precondition(beforeBadCodes == afterBadCodes)
        let staleAttempt = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
        try await auth.select(origin: "https://other.test")
        try await auth.select(origin: origin)
        do { try await auth.complete(staleAttempt, callback: URL(string: "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!); preconditionFailure() } catch CFLAuthorizationError.superseded { }
        let unknownAttempt = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
        await http.set(.network)
        let callback = URL(string: "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!
        do { try await auth.complete(unknownAttempt, callback: callback); preconditionFailure() } catch CFLAuthorizationError.authorizationRequired { }
        let consumedCount = await http.count()
        do { try await auth.complete(unknownAttempt, callback: callback); preconditionFailure() } catch CFLAuthorizationError.superseded { }
        let afterConsumed = await http.count(); precondition(consumedCount == afterConsumed)
        let blockedGrant = try store.load(origin: origin)!; precondition(blockedGrant.refreshPending)
        await http.set(.tokens)
        let attempt = await auth.makeAttempt(origin: origin, state: "expected", verifier: "synthetic-verifier", challenge: "synthetic-challenge")
        try await auth.complete(attempt, callback: URL(string: "etosllmstudio://auth/callback?state=expected&iss=https%3A%2F%2Fexample.test%2Fapi%2Fauth&code=one")!)
        let codeRequest = await http.last()!
        let codeBody = String(data: codeRequest.httpBody!, encoding: .utf8)!
        precondition(codeBody.contains("code_verifier=synthetic-verifier") && codeBody.contains("grant_type=authorization_code"))
        await http.set(.signedOut)
        try await auth.checkAfterTransportFailure()
        let latest = try store.load(origin: origin)!; precondition(latest.accessToken == "new-access" && !latest.refreshPending)
        let wrappedHTTP = CFLAuthorizedHTTP(authorization: auth, http: http)
        await http.set(.tokens)
        _ = try await wrappedHTTP.data(for: request)
        let mediaRequest = await http.last()!
        precondition(mediaRequest.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        precondition(mediaRequest.value(forHTTPHeaderField: "Origin") == origin)
        let socket = CFLAuthorizedSocket(socket: BrokenSocket(), authorization: auth)
        await http.set(.network)
        do { _ = try await socket.receive(); preconditionFailure() } catch CFLFailure.offline { }
        // CFL setup means no owner passkey, so a previously issued grant cannot authorize.
        try store.save(CFLCredentials(accessToken: "old-grant", refreshToken: "do-not-replay", expiresAt: .distantFuture), origin: origin)
        await http.set(.setup)
        let beforeSetup = await http.count()
        do { _ = try await socket.receive(); preconditionFailure() } catch CFLFailure.accessDenied { }
        let afterSetup = await http.count(); precondition(afterSetup == beforeSetup + 1)
        let setupGrant = try store.load(origin: origin)!
        precondition(setupGrant.accessToken == "old-grant" && setupGrant.refreshToken == "do-not-replay" && !setupGrant.refreshPending)
        let pending = CFLPending(target: origin, sessionId: "session", operationId: "unknown", text: "preserve", createdAt: Date(), dispatched: true, status: .unknown)
        let pendingStore = SetupPendingStore([pending]); let failedSocket = SetupSocket()
        let client = CFLChatClient(target: origin, store: pendingStore, transport: { CFLAuthorizedSocket(socket: failedSocket, authorization: auth) })
        let beforeConnect = await http.count()
        await client.connect()
        let chatState = await client.currentState()
        let retainedPending = await pendingStore.load()
        let frames = await failedSocket.sentFrames()
        let methods = frames.compactMap { frame in
            (try? JSONDecoder().decode(ChordJSON.self, from: Data(frame.utf8)))?.object?["call"]?.object?["member"]?.string
        }
        precondition(chatState.connection == .accessDenied && retainedPending == [pending])
        precondition(!methods.contains("submit"))
        await client.disconnect()
        let setupPaths = await http.paths(from: beforeConnect)
        precondition(!setupPaths.isEmpty && setupPaths.allSatisfy { $0 == "/api/auth/status" })
        var setupUpload = URLRequest(url: URL(string: origin + "/api/chat/images")!)
        setupUpload.httpMethod = "POST"; setupUpload.httpBody = Data("synthetic".utf8)
        await http.set(.setupMedia)
        let beforeUpload = await http.count()
        do { _ = try await wrappedHTTP.data(for: setupUpload); preconditionFailure() } catch CFLFailure.accessDenied { }
        let uploadPaths = await http.paths(from: beforeUpload)
        precondition(uploadPaths == ["/api/chat/images", "/api/auth/status"])
        let retainedSetupGrant = try store.load(origin: origin)!
        precondition(retainedSetupGrant.refreshToken == "do-not-replay" && !retainedSetupGrant.refreshPending)
        await http.set(.revoked)
        do { _ = try await socket.receive(); preconditionFailure() } catch CFLFailure.accessDenied { }
        let revoked = try store.load(origin: origin)!; precondition(revoked.refreshPending)
        // A rejected upload is never resent, even when auth must be investigated.
        var upload = URLRequest(url: URL(string: origin + "/api/chat/images")!)
        upload.httpMethod = "POST"; upload.httpBody = Data("synthetic".utf8)
        for mode in [AuthHTTP.Mode.denied401, .denied403, .deniedOffline] {
            try store.save(CFLCredentials(accessToken: "media-token", refreshToken: "media-refresh", expiresAt: .distantFuture), origin: origin)
            await http.set(mode)
            let before = await http.count()
            do { _ = try await wrappedHTTP.data(for: upload); preconditionFailure() }
            catch CFLFailure.accessDenied where mode != .deniedOffline { }
            catch CFLFailure.offline where mode == .deniedOffline { }
            let after = await http.count()
            precondition(after - before == (mode == .deniedOffline ? 2 : 3))
            let saved = try store.load(origin: origin)!
            precondition(saved.refreshPending == (mode != .deniedOffline))
        }
        // A token redirect is an unknown result: do not follow or resend the rotating token.
        try store.save(CFLCredentials(accessToken: "old", refreshToken: "redirect-refresh", expiresAt: .distantPast), origin: origin)
        await http.set(.redirect)
        let beforeRedirect = await http.count()
        do { _ = try await auth.accessToken(); preconditionFailure() } catch CFLAuthorizationError.authorizationRequired { }
        do { _ = try await auth.accessToken(); preconditionFailure() } catch CFLAuthorizationError.authorizationRequired { }
        let afterRedirect = await http.count(); precondition(afterRedirect == beforeRedirect + 1)
        print("CFL authorization refresh, callback, transport and origin checks passed")
    }
}
