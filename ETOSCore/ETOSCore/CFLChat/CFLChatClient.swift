import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Parse only the canonical URLs emitted by the shared workspace helper. The
// query value is decoded exactly once: a literal "%20" filename arrives as
// "%2520" and is never decoded again before the request reaches CFL.
private struct CFLWorkspaceRendererResource {
    enum Kind { case image, audio, video }
    let path: String
    let kind: Kind
    let fileExtension: String

    private static func encodeComponent(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var output = ""
        for byte in value.utf8 {
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 95, 46, 33, 126, 42, 39, 40, 41].contains(byte) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output.append("%")
                output.append(Character(UnicodeScalar(digits[Int(byte >> 4)])))
                output.append(Character(UnicodeScalar(digits[Int(byte & 15)])))
            }
        }
        return output
    }
    static func parse(_ path: String) -> Self? {
        let prefix: String, kind: Kind
        if path.hasPrefix("/api/chat/workspace-image?path=") {
            prefix = "/api/chat/workspace-image?path="; kind = .image
        } else if path.hasPrefix("/api/chat/workspace-media?kind=audio&path=") {
            prefix = "/api/chat/workspace-media?kind=audio&path="; kind = .audio
        } else if path.hasPrefix("/api/chat/workspace-media?kind=video&path=") {
            prefix = "/api/chat/workspace-media?kind=video&path="; kind = .video
        } else { return nil }
        let encoded = String(path.dropFirst(prefix.count))
        guard encoded.utf8.count <= 12_288, let literal = encoded.removingPercentEncoding,
              !literal.isEmpty, literal == literal.trimmingCharacters(in: .whitespacesAndNewlines),
              literal.utf8.count <= 4096, encodeComponent(literal) == encoded,
              !literal.contains("//"), !literal.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              literal.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) == nil,
              literal.range(of: #"^/api(?:/|$)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !literal.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) || $0.value == 92 || $0.value == 0xfffd }) else { return nil }
        let ext = (literal as NSString).pathExtension.lowercased()
        switch kind {
        case .image: guard ["png", "jpg", "jpeg", "webp", "gif"].contains(ext) else { return nil }
        case .audio: guard ["wav", "mp3"].contains(ext) else { return nil }
        case .video: guard ext == "mp4" else { return nil }
        }
        return Self(path: path, kind: kind, fileExtension: ext)
    }
    func accepts(_ type: String) -> Bool {
        switch kind {
        case .image: return CFLImageLimits.types.contains(type)
        case .audio: return fileExtension == "mp3" ? type == "audio/mpeg" : ["audio/wav", "audio/x-wav", "audio/wave"].contains(type)
        case .video: return type == "video/mp4"
        }
    }
}

private struct CFLWorkspaceRange {
    static let segmentBytes = 2 * 1024 * 1024
    static let maximumTotal = 256 * 1024 * 1024
    let start: Int?
    let end: Int?
    var request: String {
        if let start {
            let cap = start > Int.max - Self.segmentBytes + 1 ? Int.max : start + Self.segmentBytes - 1
            let last = min(end ?? cap, cap)
            return "bytes=\(start)-\(last)"
        }
        return "bytes=-\(min(end ?? 0, Self.segmentBytes))"
    }
    static func parse(_ value: String) -> Self? {
        guard value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, !(parts[0].isEmpty && parts[1].isEmpty),
              parts.allSatisfy({ $0.isEmpty || $0.utf8.allSatisfy { (48...57).contains($0) } }),
              (parts[0].isEmpty || Int(parts[0]) != nil), (parts[1].isEmpty || Int(parts[1]) != nil) else { return nil }
        let start = Int(parts[0]), end = Int(parts[1])
        return Self(start: start, end: end)
    }
    func requested(total: Int) -> (Int, Int)? {
        guard total > 0, total <= Self.maximumTotal else { return nil }
        if let start {
            let last = min(end ?? (total - 1), total - 1)
            return start < total && start <= last ? (start, last) : nil
        }
        let length = min(end ?? 0, total)
        return length > 0 ? (total - length, total - 1) : nil
    }
    func expected(total: Int) -> (Int, Int)? {
        guard let full = requested(total: total) else { return nil }
        if start != nil { return (full.0, min(full.1, full.0 + Self.segmentBytes - 1)) }
        return (max(full.0, total - Self.segmentBytes), full.1)
    }
}

/// A single active CFL session. State and pending records retain server string identities.
public actor CFLChatClient {
    public typealias TransportFactory = @Sendable () async throws -> any CFLChatTransport
    private let target: String
    private let store: any CFLPendingStore
    private let transportFactory: TransportFactory
    private let imageHTTP: any CFLImageHTTP
    private let externalImageLoader: CFLExternalImageLoader
    private let mediaCache: (any CFLMediaCache)?
    private var cacheVersions: [String: UUID] = [:]
    private var cacheReads: [String: Set<UUID>] = [:]
    private var favoriteEpoch = 0
    private var favoriteSnapshotBusy = false
    private var favoriteSnapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private struct CatalogFlight<Page: Sendable> {
        let token: UUID, generation: Int, revision: Int, scope: UUID?
        let favoriteEpoch: Int
        let task: Task<Page, Error>
        var waiters: Int
    }
    private var stickerPageFlights: [String: CatalogFlight<CFLStickerPage>] = [:]
    private var stickerPackFlights: [String: CatalogFlight<CFLStickerPackPage>] = [:]
    private struct FavoriteArchive: Codable, Sendable {
        struct Entry: Codable, Sendable { let snapshot: CFLFavoriteSnapshot; let stored: Date }
        var pages: [String: Entry] = [:]
    }
    private struct ExternalImageCacheRecord: Codable {
        // nil delegates expiration entirely to Kingfisher's last-access rule.
        let freshUntil: Date?
    }
    private var requestTimeout: @Sendable (String) async throws -> Void = { _ in try await Task.sleep(nanoseconds: 30_000_000_000) }
    private var entries: [CFLPending] = []
    private var loaded = false
    private var writing = false
    private var disconnecting = false
    private var storeDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var retirementRequested = false
    private var retirementRunning = false
    private var state = CFLChatState()
    private var suppressPublications = false
    private var errorRevision = 0
    private var observers: [UUID: AsyncStream<CFLChatState>.Continuation] = [:]
    private var transport: (any CFLChatTransport)?
    private var generation = 0
    private var sequence = 0
    private var chord = ChordState()
    private var subscribed = false
    private var queuedUpdates: [ChordJSON] = []
    private var calls: [String: CheckedContinuation<ChordJSON, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var active = false
    private var historyLoading = false
    private var historyLoadingID: UUID?
    private var historyRevision = 0
    private var historyLoaded = false
    private struct HistoryGapWork {
        var gap: CFLHistoryGap
        var cursor: String?
        var visited: Set<String>
    }
    private var gaps: [HistoryGapWork] = []
    private var historySources: Set<String> = []
    private var unconfirmedInputs: Set<String> = []
    private var lastLiveMessages: [CFLMessage] = []
    private struct CheckKey: Hashable {
        let generation: Int
        let sessionRevision: Int
        let session: String
        let operation: String
    }
    private var sessionRevision = 0
    private var checks: Set<CheckKey> = []
    private var finalized: Set<CheckKey> = []
    private var submitting: Set<String> = []
    private var sending = false
    private var usedSendOperations: Set<UUID> = []
    private var olderMessages: [CFLMessage] = []
    private var latestMessages: [CFLMessage] = []
    private var latestBefore: String?
    private struct ThumbnailKey: Hashable {
        let session: String, id: String, version: String
    }
    private struct ThumbnailEntry {
        let data: Data, etag: String?
        var used: UInt64
    }
    private struct ThumbnailFlight {
        let token: UUID, generation: Int, revision: Int, scope: UUID?
        let task: Task<Data, Error>
        var waiters: Int
    }
    private var thumbnailScope: UUID?
    private var thumbnails: [ThumbnailKey: ThumbnailEntry] = [:]
    private var thumbnailFlights: [ThumbnailKey: ThumbnailFlight] = [:]
    private var thumbnailClock: UInt64 = 0
    private let thumbnailByteLimit = 5 * 1024 * 1024
    private let thumbnailCountLimit = 128
    private func clearThumbnails() {
        for flight in thumbnailFlights.values { flight.task.cancel() }
        thumbnails.removeAll(); thumbnailFlights.removeAll(); thumbnailScope = nil
    }
    private func cancelThumbnailFlight(_ key: ThumbnailKey) {
        thumbnailFlights.removeValue(forKey: key)?.task.cancel()
    }
    private func finishThumbnailWaiter(_ key: ThumbnailKey, token: UUID) {
        guard var flight = thumbnailFlights[key], flight.token == token else { return }
        flight.waiters -= 1
        if flight.waiters == 0 { thumbnailFlights.removeValue(forKey: key) }
        else { thumbnailFlights[key] = flight }
    }
    // Internal observation seam for deterministic fake-transport concurrency checks.
    func thumbnailWaiterCount(_ sticker: CFLSticker, session: String) -> Int {
        thumbnailFlights[ThumbnailKey(session: session, id: sticker.id, version: sticker.version)]?.waiters ?? 0
    }
    // Internal observation seam for deterministic fake-transport concurrency checks.
    func favoritePageWaiterCount(session: String, cursor: String? = nil, limit: Int = 30, query: String? = nil) -> Int {
        guard let request = try? stickerRequest(path: "favorites", session: session, cursor: cursor, limit: limit, query: query),
              let url = request.url else { return 0 }
        return stickerPageFlights[cacheKey("catalog", session: session, parts: [url.absoluteString])]?.waiters ?? 0
    }
    func stickerPackWaiterCount(session: String) -> Int {
        guard let request = try? stickerRequest(path: "packs", session: session, cursor: nil, limit: 30, query: nil),
              let url = request.url else { return 0 }
        return stickerPackFlights[cacheKey("catalog", session: session, parts: [url.absoluteString])]?.waiters ?? 0
    }


    /// target is a stable, credential-free identifier for the connection; use one active client per store.
    public init(target: String, store: any CFLPendingStore, imageHTTP: any CFLImageHTTP = CFLImageURLSession.shared, mediaCache: (any CFLMediaCache)? = nil, externalImageLoader: CFLExternalImageLoader = CFLExternalImageLoader(), transport: @escaping TransportFactory) {
        self.target = target; self.store = store; self.imageHTTP = imageHTTP; self.mediaCache = mediaCache; self.externalImageLoader = externalImageLoader; self.transportFactory = transport
    }
    init(target: String, store: any CFLPendingStore, requestTimeout: @escaping @Sendable (String) async throws -> Void, transport: @escaping TransportFactory) {
        self.target = target; self.store = store; self.imageHTTP = CFLImageURLSession.shared; self.mediaCache = nil; self.externalImageLoader = CFLExternalImageLoader(); self.transportFactory = transport; self.requestTimeout = requestTimeout
    }
    private func cacheKey(_ kind: String, session: String, parts: [String]) -> String {
        // Encoding an array avoids ambiguity between caller-supplied components.
        let bytes = (try? JSONEncoder().encode([target, session, kind] + parts)) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func supportedImageBytes(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        return bytes.starts(with: [255, 216, 255]) || bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) ||
            bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) ||
            (bytes.count >= 12 && bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8..<12]) == Array("WEBP".utf8))
    }
    private func cacheAuthority() async -> UUID? {
        guard mediaCache != nil, let authority = imageHTTP as? any CFLStickerCacheAuthority else { return nil }
        // Runtime identity checks prevent an old client from displaying a value;
        // the persistent key itself remains stable across login to this origin.
        return try? await authority.stickerThumbnailScope()
    }
    private func cacheRead(_ key: String, session: String, revision: Int, current: Int) async throws -> Data? {
        guard let cache = mediaCache, let scope = await cacheAuthority() else { return nil }
        try thumbnailContext(session, revision, generation: current)
        let version = cacheVersions[key], readID = UUID()
        cacheReads[key, default: []].insert(readID)
        defer {
            cacheReads[key]?.remove(readID)
            if cacheReads[key]?.isEmpty == true { cacheReads.removeValue(forKey: key) }
        }
        let data = try? await cache.read(key: key)
        try thumbnailContext(session, revision, generation: current)
        guard await cacheAuthority() == scope, cacheVersions[key] == version, cacheReads[key]?.contains(readID) == true else { return nil }
        try thumbnailContext(session, revision, generation: current)
        return data
    }
    @discardableResult private func cacheWrite(_ data: Data, key: String, session: String, revision: Int,
                            current: Int, version: UUID, withoutExpiry: Bool = false) async -> Bool {
        guard let cache = mediaCache, cacheVersions[key] == version,
              await cacheAuthority() != nil, cacheVersions[key] == version,
              (try? thumbnailContext(session, revision, generation: current)) != nil else { return false }
        cacheReads.removeValue(forKey: key)
        do { try await cache.write(data, key: key, withoutExpiry: withoutExpiry); return true }
        catch { return false }
    }
    private func cacheRemove(_ key: String) async {
        let version = UUID(); cacheVersions[key] = version; cacheReads.removeValue(forKey: key)
        defer { if cacheVersions[key] == version { cacheVersions.removeValue(forKey: key) } }
        guard let cache = mediaCache, await cacheAuthority() != nil else { return }
        try? await cache.remove(key: key)
    }
    private func acquireFavoriteSnapshot() async {
        if !favoriteSnapshotBusy { favoriteSnapshotBusy = true; return }
        await withCheckedContinuation { favoriteSnapshotWaiters.append($0) }
    }
    private func releaseFavoriteSnapshot() {
        if favoriteSnapshotWaiters.isEmpty { favoriteSnapshotBusy = false }
        else { favoriteSnapshotWaiters.removeFirst().resume() }
    }
    public func currentState() -> CFLChatState { state }
    public func states() -> AsyncStream<CFLChatState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish() { if !suppressPublications { for observer in observers.values { observer.yield(state) } } }
    private func setError(_ error: CFLFailure?) {
        errorRevision += 1
        state.error = error
    }
    private func clearError(since revision: Int, only error: CFLFailure? = nil) {
        guard revision == errorRevision, state.error != nil,
              error == nil || state.error == error else { return }
        setError(nil); publish()
    }
    private func showPending() {
        state.pending = entries.filter { $0.target == target }
        state.otherTargetPending = entries.filter { $0.target != target }
    }
    private func finishStoreAccess() {
        writing = false
        let waiters = storeDrainWaiters; storeDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        scheduleRetirement()
    }
    private func requestRetirement() {
        guard active, !disconnecting, loaded, state.connection == .online, state.sessionId != nil else { return }
        retirementRequested = true
        scheduleRetirement()
    }
    private func scheduleRetirement() {
        guard active, !disconnecting, retirementRequested, loaded, !writing, !retirementRunning else { return }
        retirementRunning = true
        Task { [weak self] in await self?.retireObservedSubmissions() }
    }
    private func retireObservedSubmissions() async {
        defer { retirementRunning = false; scheduleRetirement() }
        guard active, !disconnecting, retirementRequested, loaded, !writing else { return }
        guard state.connection == .online, let session = state.sessionId else {
            retirementRequested = false
            return
        }
        retirementRequested = false
        let observed = Set(state.messages.filter { $0.role == "user" }.compactMap(\.operationId))
        for message in state.messages where message.role == "user" && !historySources.contains(message.id) {
            if let operation = message.operationId, entries.contains(where: { $0.target == target && $0.sessionId == session && $0.operationId == operation }) {
                unconfirmedInputs.insert(operation)
            }
        }
        let next = entries.filter { entry in
            !(entry.target == target && entry.sessionId == session && entry.status == .submitted && observed.contains(entry.operationId))
        }
        guard next.count != entries.count else { return }
        // A failed write leaves records intact or reloads the committed snapshot.
        // A later publication, receipt, history page or recovery can retry.
        try? await persist(next)
    }
    private func load() async throws {
        guard active && !disconnecting else { throw CFLFailure.offline }
        if loaded { return }
        guard !writing else { setError(.storage); publish(); throw CFLFailure.storage }
        writing = true
        defer { finishStoreAccess() }
        do { entries = try await store.load(); loaded = true; showPending(); publish(); requestRetirement() }
        catch { setError(.storage); publish(); throw CFLFailure.storage }
    }
    // Serialize all mutations so a reentrant actor cannot overwrite a newer durable snapshot.
    private func persist(_ next: [CFLPending]) async throws {
        guard active && !disconnecting else { throw CFLFailure.offline }
        guard loaded && !writing else { setError(.storage); publish(); throw CFLFailure.storage }
        let previousError = errorRevision
        writing = true
        defer { finishStoreAccess() }
        do { try await store.save(next); entries = next; showPending(); publish(); clearError(since: previousError, only: .storage) }
        catch {
            // A store may have committed before reporting an error. Never overwrite an
            // unreadable or stale snapshot with a later mutation.
            do { entries = try await store.load(); loaded = true; showPending() }
            catch { loaded = false }
            setError(.storage); publish(); throw CFLFailure.storage
        }
    }
    public func connect() async {
        guard !disconnecting else { return }
        if active && (transport != nil || state.connection == .connecting) { return }
        active = true
        let startingGeneration = generation
        state.connection = .connecting; publish()
        do {
            try await load()
            guard active && generation == startingGeneration else { return }
            try await open()
        } catch {
            // The receive loop or an explicit disconnect may already own cleanup.
            if active && (generation == startingGeneration || generation == startingGeneration + 1) {
                await disconnected(error, reconnect: true)
            }
        }
    }
    /// Waits for any store access already in progress before the file may be reused.
    /// The store must eventually complete its operations; returning early would let a
    /// previous write race a replacement client.
    public func disconnect() async {
        if disconnecting {
            await withCheckedContinuation { disconnectWaiters.append($0) }
            return
        }
        disconnecting = true
        active = false; reconnectTask?.cancel(); reconnectTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        retirementRequested = false
        await disconnected(CFLFailure.offline, reconnect: false)
        if writing { await withCheckedContinuation { storeDrainWaiters.append($0) } }
        clearThumbnails()
        state.localDrafts.removeAll(); state.localPreviews.removeAll(); publish()
        disconnecting = false
        let waiters = disconnectWaiters; disconnectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func open() async throws {
        generation += 1
        let current = generation
        let previousError = errorRevision
        state.connection = .connecting; publish()
        let socket = try await transportFactory()
        guard active && generation == current else { await socket.close(); throw CFLFailure.offline }
        transport = socket; chord = ChordState(); subscribed = false
        queuedUpdates = []
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, generation: current) }
        let snapshot = try await call(service: "$chord.service", method: "subscribe", args: [.string("view"), .string("lamplit.chat.v2"), .string("singleton")])
        guard generation == current else { throw CFLFailure.offline }
        try chord.hydrate(snapshot)
        subscribed = true
        suppressPublications = true
        do {
            try applyView()
            for update in queuedUpdates {
                try chord.update(update)
                try applyView()
            }
        } catch { suppressPublications = false; throw error }
        suppressPublications = false
        queuedUpdates = []
        guard active && generation == current else { throw CFLFailure.offline }
        state.connection = .online; publish()
        if state.error != .storage { clearError(since: previousError) }
        requestRetirement()
        requestReconcile(publication: true)
    }
    private func receiveLoop(_ socket: any CFLChatTransport, generation current: Int) async {
        do {
            while !Task.isCancelled {
                let text = try await socket.receive()
                guard current == generation else { return }
                guard text.utf8.count <= 2 * 1024 * 1024, let data = text.data(using: .utf8),
                      let frame = try? JSONDecoder().decode(ChordJSON.self, from: data).object,
                      let type = frame["type"]?.string else { throw CFLFailure.protocolError }
                if type == "update" {
                    guard frame["subscriptionId"]?.string == "view", let update = frame["update"] else { throw CFLFailure.protocolError }
                    if subscribed {
                        try chord.update(update)
                        try applyView()
                        requestReconcile(publication: true)
                    }
                    else {
                        guard queuedUpdates.count < 100 else { throw CFLFailure.protocolError }
                        queuedUpdates.append(update)
                    }
                } else if type == "result" || type == "error" {
                    guard let id = frame["id"]?.string else { throw CFLFailure.protocolError }
                    if let pending = calls.removeValue(forKey: id) {
                        timeouts.removeValue(forKey: id)?.cancel()
                        if type == "error" { pending.resume(throwing: CFLFailure.requestFailed) }
                        else if let result = frame["result"] { pending.resume(returning: result) }
                        else { pending.resume(throwing: CFLFailure.protocolError) }
                    }
                } else { throw CFLFailure.protocolError }
            }
        } catch { if current == generation { await disconnected(error, reconnect: true) } }
    }
    private func disconnected(_ error: Error, reconnect: Bool) async {
        generation += 1; receiveTask?.cancel(); receiveTask = nil
        historyLoading = false; historyLoadingID = nil
        for index in gaps.indices where gaps[index].gap.status == .loading { gaps[index].gap.status = .pending }
        state.historyGaps = gaps.map(\.gap)
        deadlineTask?.cancel(); deadlineTask = nil
        checks.removeAll(); finalized.removeAll()
        let old = transport; transport = nil
        for continuation in calls.values { continuation.resume(throwing: CFLFailure.offline) }; calls.removeAll()
        for timer in timeouts.values { timer.cancel() }; timeouts.removeAll()
        subscribed = false; chord = ChordState()
        queuedUpdates = []
        let failure: CFLFailure?
        if let authorization = error as? CFLAuthorizationError {
            switch authorization {
            case .authorizationRequired: failure = .accessDenied
            case .storage: failure = .storage
            default: failure = .offline
            }
        } else { failure = error as? CFLFailure }
        if failure == .accessDenied {
            // A persisted pending refresh can also surface as accessDenied even
            // though its network outcome is unknown. Only the authority can
            // distinguish that case from confirmed loss of authorization.
            let current = generation
            do {
                if let scope = try await thumbnailAuthority() {
                    guard generation == current else { return }
                    adoptThumbnailScope(scope)
                } else { clearThumbnails() }
            } catch { /* thumbnailAuthority evicts only confirmed denial. */ }
            guard generation == current else { return }
        }
        state.connection = failure == .accessDenied ? .accessDenied : failure == .protocolError || error is ChordError ? .protocolError : .offline
        if failure == .storage { setError(.storage) }
        else if state.error != .storage { setError(nil) }
        publish()
        await old?.close()
        if reconnect && active && failure != .accessDenied && failure != .storage {
            reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.connect()
            }
        }
    }
    private func call(service: String = "lamplit.chat.v2", method: String, args: [ChordJSON]) async throws -> ChordJSON {
        guard let socket = transport else { throw CFLFailure.offline }
        sequence += 1; let id = String(sequence); let current = generation
        let frame: ChordJSON = .object(["type": .string("call"), "version": .number(1), "id": .string(id), "call": .object(["serviceId": .string(service), "member": .string(method), "args": .array(args)])])
        let data = try JSONEncoder().encode(frame)
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw CFLFailure.protocolError }
        return try await withCheckedThrowingContinuation { continuation in
            calls[id] = continuation
            Task { [weak self] in
                do { try await socket.send(text) }
                catch { await self?.failCall(id, generation: current, error: error) }
            }
            timeouts[id] = Task { [weak self] in
                do { try await self?.requestTimeout(method) } catch { return }
                await self?.expireCall(id, generation: current, isHistory: service == "lamplit.chat.v2" && method == "history")
            }
        }
    }
    private func expireCall(_ id: String, generation current: Int, isHistory: Bool) async {
        guard current == generation, calls[id] != nil else { return }
        if isHistory {
            timeouts.removeValue(forKey: id)
            calls.removeValue(forKey: id)?.resume(throwing: CFLFailure.requestFailed)
        } else { await disconnected(CFLFailure.offline, reconnect: true) }
    }
    private func failCall(_ id: String, generation current: Int, error: Error = CFLFailure.offline) async {
        guard current == generation, calls[id] != nil else { return }
        await disconnected(error, reconnect: true)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: ChordJSON) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw CFLFailure.protocolError }
    }
    private func validImageWire(_ raw: ChordJSON) -> Bool {
        guard let fields = raw.object,
              Set(fields.keys).subtracting(["sticker"]) == Set(["attachmentId", "name", "mediaType", "availability"]),
              let ref = try? decode(CFLImageRef.self, raw), ref.valid else { return false }
        if let sticker = fields["sticker"] {
            guard let value = sticker.object, Set(value.keys) == Set(["id", "version"]),
                  let id = value["id"]?.string, !id.isEmpty, id.utf8.count <= 100,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  let version = value["version"]?.string, CFLVoiceRef(id: version).valid else { return false }
        }
        return true
    }
    private func validFileWire(_ raw: ChordJSON) -> Bool {
        guard let fields = raw.object, Set(fields.keys) == Set(["attachmentId", "name", "mediaType", "size", "availability"]),
              let ref = try? decode(CFLFileRef.self, raw) else { return false }
        return ref.valid
    }
    private func validRecoveryWire(_ raw: ChordJSON) -> Bool {
        guard let fields = raw.object,
              Set(fields.keys).subtracting(["files"]) == Set(["sourceId", "operationId", "text", "images", "replacementEligible"]),
              let recovery = try? decode(CFLInputRecovery.self, raw),
              !recovery.sourceId.isEmpty, recovery.sourceId.unicodeScalars.count <= 300,
              UUID(uuidString: recovery.operationId) != nil, recovery.text.unicodeScalars.count <= 16000,
              let images = fields["images"]?.array, images.count <= 6, images.allSatisfy(validImageWire),
              fields["replacementEligible"] == .bool(true) || fields["replacementEligible"] == .bool(false) else { return false }
        if let files = fields["files"] { guard let values = files.array, values.count <= 6, values.allSatisfy(validFileWire) else { return false } }
        return true
    }
    // Bound only a copy: future Chord patches must still apply to the original tree.
    private func boundedUIProjection(_ value: ChordJSON) -> ChordJSON {
        guard var fields = value.object, let messages = fields["messages"]?.array else { return value }
        fields["messages"] = .array(messages.map { message in
            guard var item = message.object, let payload = item["ui"] else { return message }
            var count = 0
            func withinBounds(_ value: ChordJSON, _ depth: Int) -> Bool {
                count += 1
                guard count <= 16_384, depth <= 32 else { return false }
                switch value {
                case .number(let n): return n.isFinite
                case .string(let s): return s.utf16.count <= 16_384
                case .array(let values): return values.count <= 16_384 && values.allSatisfy { withinBounds($0, depth + 1) }
                case .object(let values):
                    return values.count <= 16_384 && values.allSatisfy { $0.key.utf16.count <= 16_384 && withinBounds($0.value, depth + 1) }
                default: return true
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            if !withinBounds(payload, 0) || (try? encoder.encode(payload).count).map({ $0 <= 16_384 }) != true {
                item["ui"] = .object([:])
            }
            return .object(item)
        })
        return .object(fields)
    }
    private func validMessageWire(_ raw: ChordJSON) -> Bool {
        guard let fields = raw.object,
              Set(fields.keys).isSubset(of: Set(["id", "role", "text", "ends", "createdAt", "operationId", "turnId", "images", "files", "imageState", "textState", "voice", "source", "thinking", "ui"])),
              let id = fields["id"]?.string, !id.isEmpty, id.utf16.count <= 300,
              let role = fields["role"]?.string, let text = fields["text"]?.string,
              fields["operationId"] == .null || fields["operationId"]?.string != nil,
              fields["turnId"] == .null || fields["turnId"]?.string != nil else { return false }
        if fields["ui"] != nil {
            guard role == "agent", text.isEmpty,
                  ["source", "voice", "images", "files", "imageState", "textState", "ends"].allSatisfy({ fields[$0] == nil }) else { return false }
        }
        let isReply = role == "agent" && fields["source"] == nil && fields["imageState"] == nil && fields["voice"] == nil && fields["ui"] == nil
        guard validReplyEnds(fields["ends"], text: text, required: isReply) else { return false }
        if let images = fields["images"] { guard let items = images.array, items.allSatisfy(validImageWire) else { return false } }
        if let files = fields["files"] { guard let items = files.array, items.allSatisfy(validFileWire) else { return false } }
        if let imageState = fields["imageState"] { guard let value = imageState.string, CFLImageState(rawValue: value) != nil else { return false } }
        if let textState = fields["textState"] { guard let value = textState.string, CFLTextState(rawValue: value) != nil else { return false } }
        if let voice = fields["voice"] { guard let value = voice.object, Set(value.keys) == Set(["id"]), let id = value["id"]?.string, CFLVoiceRef(id: id).valid else { return false } }
        if let thinking = fields["thinking"], thinking.string == nil { return false }
        return true
    }
    private func validReplyEnds(_ raw: ChordJSON?, text: String, required: Bool) -> Bool {
        guard let raw else { return !required }
        guard raw.array != nil, let ends = try? decode([Int].self, raw),
              CFLReplySegments.valid(text, ends: ends) else { return false }
        return true
    }
    private func validStreamingReplyWire(_ raw: ChordJSON?) -> Bool {
        guard let raw else { return true }
        guard let fields = raw.object, Set(fields.keys).isSubset(of: Set(["id", "turnId", "createdAt", "text", "ends"])),
              let id = fields["id"]?.string, !id.isEmpty, id.utf16.count <= 300,
              fields["turnId"] == .null || fields["turnId"]?.string != nil,
              let text = fields["text"]?.string else { return false }
        return validReplyEnds(fields["ends"], text: text, required: true)
    }
    // A view can temporarily omit an interior or trailing item. Keep its last
    // position until a later view or history establishes the structure.
    private func mergeWindow(_ incoming: [CFLMessage], before: String?) -> (older: [CFLMessage], latest: [CFLMessage], ambiguous: Bool) {
        let previous = olderMessages + latestMessages
        guard !previous.isEmpty else { return ([], incoming, false) }
        guard !incoming.isEmpty else { return (olderMessages, latestMessages, !latestMessages.isEmpty) }
        let oldIDs = Set(previous.map(\.id)), newIDs = Set(incoming.map(\.id))
        guard let firstShared = previous.firstIndex(where: { newIDs.contains($0.id) }) else { return (previous, incoming, true) }
        let priorShared = previous.filter { newIDs.contains($0.id) }.map(\.id)
        let incomingShared = incoming.filter { oldIDs.contains($0.id) }.map(\.id)
        let lastShared = incoming.lastIndex(where: { oldIDs.contains($0.id) })!
        let newTail = incoming.dropFirst(lastShared + 1).contains { !oldIDs.contains($0.id) }
        let prefixAdvanced = before != latestBefore || newTail
        let split = prefixAdvanced ? firstShared : min(firstShared, olderMessages.count)
        let prefix = Array(previous.prefix(split)), suffix = Array(previous.dropFirst(split))
        var beforeItems: [String: [CFLMessage]] = [:], afterItems: [String: [CFLMessage]] = [:]
        var missing: [CFLMessage] = [], lastAnchor: String?
        for old in suffix {
            if newIDs.contains(old.id) {
                beforeItems[old.id, default: []].append(contentsOf: missing)
                missing.removeAll(keepingCapacity: true); lastAnchor = old.id
            } else { missing.append(old) }
        }
        if let lastAnchor { afterItems[lastAnchor, default: []].append(contentsOf: missing) }
        var merged: [CFLMessage] = []
        for message in incoming {
            merged.append(contentsOf: beforeItems[message.id] ?? []); merged.append(message)
            merged.append(contentsOf: afterItems[message.id] ?? [])
        }
        return (prefix, merged, priorShared != incomingShared || suffix.contains { !newIDs.contains($0.id) })
    }
    private func applyView() throws {
        guard let value = chord.value, let fields = value.object,
              fields["activeTurnId"] != nil, fields["before"] != nil,
              let capabilities = fields["capabilities"]?.object,
              capabilities["text"] == .bool(true), capabilities["stop"] == .bool(true),
              fields["contextUsage"] != nil, fields["compaction"] != nil, let rawRecovery = fields["recovery"]?.array, rawRecovery.allSatisfy(validRecoveryWire) else { throw CFLFailure.protocolError }
        let view = try decode(CFLView.self, boundedUIProjection(value))
        guard view.version == 2, !view.sessionId.isEmpty, view.messages.count <= 30,
              let rawMessages = fields["messages"]?.array, rawMessages.allSatisfy(validMessageWire),
              validStreamingReplyWire(fields["streamingReply"]),
              view.streamingReply?.createdAt.isFinite ?? true,
              Set(view.messages.map(\.id)).count == view.messages.count,
              view.messages.allSatisfy(\.valid) else { throw CFLFailure.protocolError }
        var imageLimits: CFLImageLimits?
        if let images = capabilities["images"], images != .bool(false) {
            let limits = try decode(CFLImageLimits.self, images)
            guard limits.valid else { throw CFLFailure.protocolError }
            imageLimits = limits
        }
        var fileLimits: CFLFileLimits?
        if let files = capabilities["files"], files != .bool(false) {
            guard let object = files.object, Set(object.keys) == Set(["maxFilesPerMessage", "maxFileBytes", "maxMessageFileBytes"]) else { throw CFLFailure.protocolError }
            let limits = try decode(CFLFileLimits.self, files)
            guard limits.valid else { throw CFLFailure.protocolError }
            fileLimits = limits
        }
        let recovery = try decode([CFLInputRecovery].self, .array(rawRecovery))
        let changedSession = state.sessionId != view.sessionId
        if changedSession {
            sessionRevision += 1; state.sessionRevision = sessionRevision
            historyRevision += 1; historyLoaded = false
            historyLoading = false; historyLoadingID = nil
            olderMessages = []; latestMessages = []; lastLiveMessages = []; latestBefore = nil
            gaps = []; state.historyGaps = []; historySources = []; unconfirmedInputs = []
            state.before = view.before; state.historySyncFailed = false
            deadlineTask?.cancel(); deadlineTask = nil
            checks.removeAll(); finalized.removeAll()
            state.localDrafts.removeAll(); state.localPreviews.removeAll()
        }
        let incoming = view.messages
        if !changedSession {
            // An empty live projection does not erase the last retained window.
            let previousLive = lastLiveMessages.isEmpty ? latestMessages : lastLiveMessages
            let oldIDs = Set(previousLive.map(\.id)), newIDs = Set(incoming.map(\.id))
            let localPending = Set(entries.filter { $0.target == target && $0.sessionId == view.sessionId }.map(\.operationId))
            func eligible(_ message: CFLMessage) -> Bool {
                guard let operation = message.operationId else { return true }
                return !localPending.contains(operation) && !unconfirmedInputs.contains(operation)
            }
            let oldWindow = previousLive.filter(eligible), newWindow = incoming.filter(eligible)
            let overlap: Bool
            if let first = newWindow.first, let index = oldWindow.firstIndex(where: { $0.id == first.id }) {
                let suffix = oldWindow[index...].map(\.id)
                overlap = suffix.count <= newWindow.count && suffix.elementsEqual(newWindow.prefix(suffix.count).map(\.id))
            } else { overlap = false }
            let oldTail = previousLive.last(where: { !newIDs.contains($0.id) && eligible($0) })
                ?? (olderMessages + latestMessages).last(where: { !newIDs.contains($0.id) && eligible($0) })
            let newHead = incoming.first(where: { !oldIDs.contains($0.id) && eligible($0) })
            if !overlap, let oldTail, let newHead {
                let gap = CFLHistoryGap(id: UUID(), afterId: oldTail.id, beforeId: newHead.id,
                                        status: view.before == nil ? .unavailable : .pending)
                gaps.append(HistoryGapWork(gap: gap, cursor: view.before, visited: Set(view.before.map { [$0] } ?? [])))
                state.historyGaps = gaps.map(\.gap)
            }
            if historyLoading && olderMessages.isEmpty && !historyLoaded && latestBefore != view.before {
                historyRevision += 1
            }
        }
        lastLiveMessages = incoming
        let window = mergeWindow(incoming, before: view.before)
        olderMessages = window.older; latestMessages = window.latest
        latestBefore = view.before
        if olderMessages.isEmpty && !historyLoaded && (!incoming.isEmpty || latestMessages.isEmpty) { state.before = view.before }
        state.messages = olderMessages + latestMessages
        state.sessionId = view.sessionId; state.name = view.name; state.activeTurnId = view.activeTurnId; state.streamingReply = view.streamingReply; state.replyCompletedTurnId = view.replyCompletedTurnId
        state.imageLimits = imageLimits; state.fileLimits = fileLimits; state.recovery = recovery
        showPending(); publish(); requestRetirement()
    }
    /// Retry the top-of-history page after an explicit user action.
    public func retryHistory() async {
        state.historySyncFailed = false
        publish()
        try? await loadEarlier()
    }
    public func loadEarlier() async throws {
        guard state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        let current = generation, sessionVersion = sessionRevision
        guard !historyLoading, let before = state.before else { return }
        let revision = historyRevision
        let loadingID = UUID()
        historyLoading = true; historyLoadingID = loadingID
        defer {
            if historyLoadingID == loadingID {
                historyLoading = false; historyLoadingID = nil
            }
        }
        do {
            let raw = try await call(method: "history", args: [.string(before)])
            try Task.checkCancellation()
            guard raw.object?["before"] != nil else { throw CFLFailure.protocolError }
            let page: CFLPage = try decode(CFLPage.self, boundedUIProjection(raw))
            guard state.sessionId == session, generation == current, sessionRevision == sessionVersion,
                  historyRevision == revision else { throw CFLFailure.sessionChanged }
            guard page.messages.count <= 30, raw.object?["messages"]?.array?.allSatisfy(validMessageWire) == true, page.messages.allSatisfy(\.valid), Set(page.messages.map(\.id)).count == page.messages.count else { throw CFLFailure.protocolError }
            let ids = Set(state.messages.map(\.id)); let added = page.messages.filter { !ids.contains($0.id) }
            olderMessages = added + olderMessages; state.messages = added + state.messages
            noteHistory(page.messages)
            historyLoaded = true; state.before = page.before; state.historySyncFailed = false; publish(); requestRetirement()
        } catch {
            if !(error is CancellationError), state.sessionId == session, generation == current,
               sessionRevision == sessionVersion, historyRevision == revision {
                state.historySyncFailed = true; publish()
            }
            throw error
        }
    }
    private func noteHistory(_ messages: [CFLMessage]) {
        for message in messages {
            historySources.insert(message.id)
            if let operation = message.operationId { unconfirmedInputs.remove(operation) }
        }
    }
    private func publishGaps() {
        state.historyGaps = gaps.map(\.gap)
        publish()
    }
    /// Read at most one page for a visible gap. Errors stay on that gap for explicit retry.
    public func fillGap(id: UUID) async {
        guard active, !disconnecting, state.connection == .online, let session = state.sessionId,
              let index = gaps.firstIndex(where: { $0.gap.id == id }),
              gaps[index].gap.status != .loading, gaps[index].gap.status != .unavailable,
              let cursor = gaps[index].cursor else { return }
        guard gaps.filter({ $0.gap.status == .loading }).count < 8 else {
            gaps[index].gap.status = .error; publishGaps(); return
        }
        let current = generation, version = sessionRevision
        gaps[index].gap.status = .loading; publishGaps()
        do {
            let raw = try await call(method: "history", args: [.string(cursor)])
            try Task.checkCancellation()
            guard active, !disconnecting, generation == current, sessionRevision == version, state.sessionId == session,
                  let index = gaps.firstIndex(where: { $0.gap.id == id && $0.cursor == cursor && $0.gap.status == .loading }) else { return }
            guard raw.object?["before"] != nil else { throw CFLFailure.protocolError }
            let page = try decode(CFLPage.self, boundedUIProjection(raw))
            guard page.messages.count <= 30, raw.object?["messages"]?.array?.allSatisfy(validMessageWire) == true,
                  page.messages.allSatisfy(\.valid), Set(page.messages.map(\.id)).count == page.messages.count else { throw CFLFailure.protocolError }
            let all = olderMessages + latestMessages
            guard let anchor = all.firstIndex(where: { $0.id == gaps[index].gap.afterId }) else { throw CFLFailure.protocolError }
            let boundary = page.messages.firstIndex(where: { $0.id == gaps[index].gap.afterId })
            let candidates = boundary.map { Array(page.messages.dropFirst($0 + 1)) } ?? page.messages
            let known = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
            var fresh: [CFLMessage] = [], sawKnown = false, lastKnown = anchor
            for message in candidates {
                if let position = known[message.id] {
                    guard position > lastKnown else { throw CFLFailure.protocolError }
                    sawKnown = true; lastKnown = position
                } else {
                    guard !sawKnown else { throw CFLFailure.protocolError }
                    fresh.append(message)
                }
            }
            var merged = all
            merged.insert(contentsOf: fresh, at: anchor + 1)
            let split = latestMessages.first.flatMap { first in merged.firstIndex(where: { $0.id == first.id }) } ?? merged.count
            olderMessages = Array(merged.prefix(split)); latestMessages = Array(merged.dropFirst(split))
            state.messages = merged
            noteHistory(page.messages)
            if boundary != nil {
                gaps.remove(at: index)
            } else {
                if let first = fresh.first { gaps[index].gap.beforeId = first.id }
                if let next = page.before, !gaps[index].visited.contains(next) {
                    gaps[index].cursor = next; gaps[index].visited.insert(next); gaps[index].gap.status = .pending
                } else {
                    gaps[index].gap.status = .unavailable
                }
            }
            publishGaps(); requestRetirement()
        } catch {
            guard active, !disconnecting, generation == current, sessionRevision == version, state.sessionId == session,
                  let index = gaps.firstIndex(where: { $0.gap.id == id && $0.cursor == cursor && $0.gap.status == .loading }) else { return }
            gaps[index].gap.status = .error; publishGaps()
        }
    }
    /// Validate a complete proposed draft against the latest advertised limits.
    public func validateImages(_ images: [CFLPreparedImage]) throws {
        guard let limits = state.imageLimits else { throw CFLFailure.invalidInput }
        try validate(images, limits: limits)
    }
    private func validate(_ images: [CFLPreparedImage], limits: CFLImageLimits) throws {
        guard images.count <= limits.maxImagesPerMessage,
              Set(images.map(\.id)).count == images.count,
              images.reduce(0, { $0 + $1.original.count }) <= limits.maxMessageImageBytes else { throw CFLFailure.invalidInput }
        for image in images {
            let ref = CFLImageRef(attachmentId: image.id, name: image.name, mediaType: image.mediaType, availability: "available")
            let bytes = [UInt8](image.original.prefix(12))
            let signature: Bool
            switch image.mediaType {
            case "image/jpeg": signature = bytes.starts(with: [255, 216, 255])
            case "image/png": signature = bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            case "image/gif": signature = bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8))
            case "image/webp": signature = bytes.count >= 12 && bytes.starts(with: Array("RIFF".utf8)) && Array(bytes[8..<12]) == Array("WEBP".utf8)
            default: signature = false
            }
            guard ref.valid, limits.mediaTypes.contains(image.mediaType), signature,
                  image.original.count <= limits.maxImageBytes,
                  !image.preview.isEmpty, image.preview.count <= 160_000, image.preview.starts(with: [255, 216, 255]),
                  !image.model.isEmpty, image.model.count <= 320_000, image.model.starts(with: [255, 216, 255]) else { throw CFLFailure.invalidInput }
        }
    }
    public func validateFiles(_ files: [CFLPreparedFile]) throws {
        guard let limits = state.fileLimits else { throw CFLFailure.invalidInput }
        try validate(files, limits: limits)
    }
    private func validate(_ files: [CFLPreparedFile], limits: CFLFileLimits) throws {
        guard files.count <= limits.maxFilesPerMessage, Set(files.map(\.id)).count == files.count,
              files.allSatisfy({ $0.size <= limits.maxFileBytes }),
              files.reduce(0, { $0 + $1.size }) <= limits.maxMessageFileBytes else { throw CFLFailure.invalidInput }
        for file in files {
            guard CFLFileRef(attachmentId: file.id, name: file.name, mediaType: file.mediaType,
                             size: file.size, availability: "available").valid else { throw CFLFailure.invalidInput }
        }
    }
    private func request(path: String, method: String) throws -> URLRequest {
        guard let origin = CFLHTTPSOrigin.normalized(target), !origin.isEmpty, origin == target,
              let url = URL(string: origin + path) else { throw CFLFailure.invalidInput }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    private func imageResponse(_ request: URLRequest, allowNotFound: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await imageHTTP.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url else { throw CFLFailure.protocolError }
        guard (200...299).contains(http.statusCode) || (allowNotFound && http.statusCode == 404) else { throw http.statusCode == 401 || http.statusCode == 403 ? CFLFailure.accessDenied : CFLFailure.requestFailed }
        return (data, http)
    }
    // Every catalog operation is bound to the caller's current session and revision.
    private func stickerContext(_ session: String, _ revision: Int) throws -> Int {
        guard active, !disconnecting, state.connection == .online else { throw CFLFailure.offline }
        guard state.sessionId == session, sessionRevision == revision else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        return generation
    }
    private func checkStickerContext(_ session: String, _ revision: Int, _ current: Int) throws {
        guard !Task.isCancelled, active, !disconnecting, generation == current,
              state.connection == .online, state.sessionId == session, sessionRevision == revision else { throw CFLFailure.sessionChanged }
    }
    private func stickerRequest(path: String, session: String, cursor: String?, limit: Int, query: String?) throws -> URLRequest {
        guard (1...30).contains(limit), query.map({ $0.utf16.count <= 100 }) ?? true,
              cursor.map(Self.validStickerCursor) ?? true else { throw CFLFailure.invalidInput }
        var request = try request(path: "/api/stickers/" + path, method: "GET")
        guard var url = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { throw CFLFailure.invalidInput }
        url.queryItems = [URLQueryItem(name: "sessionId", value: session), URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let query { url.queryItems?.append(URLQueryItem(name: "query", value: query)) }
        guard let final = url.url else { throw CFLFailure.invalidInput }
        request.url = final
        return request
    }
    private static func validStickerCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= 300 && cursor.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    private func stickerJSON<T: Decodable>(_ type: T.Type, request: URLRequest, session: String, revision: Int) async throws -> (T, ChordJSON) {
        let current = try stickerContext(session, revision)
        let (data, _) = try await imageResponse(request)
        try checkStickerContext(session, revision, current)
        guard data.count <= 1_000_000, let wire = try? JSONDecoder().decode(ChordJSON.self, from: data),
              let result = try? JSONDecoder().decode(type, from: data) else { throw CFLFailure.protocolError }
        return (result, wire)
    }
    private func validStickerWire(_ wire: ChordJSON) -> Bool {
        guard let value = wire.object else { return false }
        return Set(value.keys) == Set(["id", "version", "name", "tags", "mediaType", "available"])
    }
    private func stickerPage(_ path: String, session: String, revision: Int, cursor: String?, limit: Int, query: String?) async throws -> CFLStickerPage {
        let request = try stickerRequest(path: path, session: session, cursor: cursor, limit: limit, query: query)
        let current = try stickerContext(session, revision)
        let scope = try await thumbnailAuthority()
        try checkStickerContext(session, revision, current)
        let favoriteRequestEpoch = path == "favorites" ? favoriteEpoch : 0
        let key = cacheKey("catalog", session: session, parts: [request.url!.absoluteString])
        let flight: CatalogFlight<CFLStickerPage>
        if var existing = stickerPageFlights[key], existing.generation == current, existing.revision == revision,
           existing.scope == scope, existing.favoriteEpoch == favoriteRequestEpoch {
            existing.waiters += 1; stickerPageFlights[key] = existing; flight = existing
        } else {
            let token = UUID()
            let task = Task { try await self.loadStickerPage(path, request: request, session: session, revision: revision,
                current: current, scope: scope, favoriteRequestEpoch: favoriteRequestEpoch,
                key: key, version: token, limit: limit) }
            flight = CatalogFlight(token: token, generation: current, revision: revision, scope: scope,
                                   favoriteEpoch: favoriteRequestEpoch, task: task, waiters: 1)
            stickerPageFlights[key] = flight
        }
        defer {
            if var running = stickerPageFlights[key], running.token == flight.token {
                running.waiters -= 1
                if running.waiters == 0 { stickerPageFlights.removeValue(forKey: key) } else { stickerPageFlights[key] = running }
            }
        }
        let page = try await flight.task.value
        try checkStickerContext(session, revision, current)
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        guard stickerPageFlights[key]?.token == flight.token,
              path != "favorites" || favoriteEpoch == favoriteRequestEpoch else { throw CFLFailure.sessionChanged }
        return page
    }
    private func loadStickerPage(_ path: String, request: URLRequest, session: String, revision: Int, current: Int,
                                 scope: UUID?, favoriteRequestEpoch: Int, key: String,
                                 version: UUID, limit: Int) async throws -> CFLStickerPage {
        guard stickerPageFlights[key]?.token == version else { throw CFLFailure.sessionChanged }
        cacheVersions[key] = version
        defer { if cacheVersions[key] == version { cacheVersions.removeValue(forKey: key) } }
        let (page, wire) = try await stickerJSON(CFLStickerPage.self, request: request, session: session, revision: revision)
        guard let fields = wire.object, Set(fields.keys) == Set(["stickers", "nextCursor"]),
              let items = fields["stickers"]?.array, items.allSatisfy(validStickerWire),
              page.stickers.count <= limit, page.stickers.allSatisfy(\.valid),
              page.nextCursor.map(Self.validStickerCursor) ?? true else { throw CFLFailure.protocolError }
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        if path == "favorites", favoriteRequestEpoch != favoriteEpoch { throw CFLFailure.sessionChanged }
        guard cacheVersions[key] == version else { throw CFLFailure.sessionChanged }
        if path == "favorites", favoriteRequestEpoch == favoriteEpoch {
            await saveFavoritePage(page, request: request, session: session, revision: revision, current: current, epoch: favoriteRequestEpoch)
        } else if path != "favorites", let data = try? JSONEncoder().encode(page), data.count <= 1_000_000 {
            await cacheWrite(data, key: key, session: session, revision: revision, current: current, version: version, withoutExpiry: true)
        }
        try checkStickerContext(session, revision, current)
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        guard cacheVersions[key] == version else { throw CFLFailure.sessionChanged }
        if path == "favorites", favoriteRequestEpoch != favoriteEpoch { throw CFLFailure.sessionChanged }
        return page
    }
    public func stickerPacks(session: String, revision: Int, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> CFLStickerPackPage {
        let request = try stickerRequest(path: "packs", session: session, cursor: cursor, limit: limit, query: query)
        let current = try stickerContext(session, revision)
        let scope = try await thumbnailAuthority()
        try checkStickerContext(session, revision, current)
        let key = cacheKey("catalog", session: session, parts: [request.url!.absoluteString])
        let flight: CatalogFlight<CFLStickerPackPage>
        if var existing = stickerPackFlights[key], existing.generation == current, existing.revision == revision,
           existing.scope == scope {
            existing.waiters += 1; stickerPackFlights[key] = existing; flight = existing
        } else {
            let token = UUID()
            let task = Task { try await self.loadStickerPacks(request, session: session, revision: revision, current: current,
                scope: scope, key: key, version: token, limit: limit) }
            flight = CatalogFlight(token: token, generation: current, revision: revision, scope: scope,
                                   favoriteEpoch: 0, task: task, waiters: 1)
            stickerPackFlights[key] = flight
        }
        defer {
            if var running = stickerPackFlights[key], running.token == flight.token {
                running.waiters -= 1
                if running.waiters == 0 { stickerPackFlights.removeValue(forKey: key) } else { stickerPackFlights[key] = running }
            }
        }
        let page = try await flight.task.value
        try checkStickerContext(session, revision, current)
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        guard stickerPackFlights[key]?.token == flight.token else { throw CFLFailure.sessionChanged }
        return page
    }
    private func loadStickerPacks(_ request: URLRequest, session: String, revision: Int, current: Int, scope: UUID?,
                                  key: String, version: UUID, limit: Int) async throws -> CFLStickerPackPage {
        guard stickerPackFlights[key]?.token == version else { throw CFLFailure.sessionChanged }
        cacheVersions[key] = version
        defer { if cacheVersions[key] == version { cacheVersions.removeValue(forKey: key) } }
        let (page, wire) = try await stickerJSON(CFLStickerPackPage.self, request: request, session: session, revision: revision)
        guard let fields = wire.object, Set(fields.keys) == Set(["packs", "nextCursor"]), let items = fields["packs"]?.array,
              items.allSatisfy({ item in
                  guard let value = item.object, Set(value.keys) == Set(["id", "name", "description", "cover"]), let cover = value["cover"] else { return false }
                  return validStickerWire(cover)
              }), page.packs.count <= limit, page.packs.allSatisfy(\.valid),
              page.nextCursor.map(Self.validStickerCursor) ?? true else { throw CFLFailure.protocolError }
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        guard cacheVersions[key] == version else { throw CFLFailure.sessionChanged }
        if let data = try? JSONEncoder().encode(page), data.count <= 1_000_000 {
            await cacheWrite(data, key: key, session: session, revision: revision, current: current, version: version, withoutExpiry: true)
        }
        try checkStickerContext(session, revision, current)
        guard try await thumbnailAuthority() == scope else { throw CFLFailure.sessionChanged }
        try checkStickerContext(session, revision, current)
        guard cacheVersions[key] == version else { throw CFLFailure.sessionChanged }
        return page
    }
    /// A snapshot is exactly one previously fetched page. Its cursor is retained;
    /// absence from a partial page never proves that an item is absent globally.
    public func cachedStickerPacks(session: String, revision: Int, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> CFLStickerPackPage? {
        let current = generation
        try thumbnailContext(session, revision, generation: current)
        let req = try stickerRequest(path: "packs", session: session, cursor: cursor, limit: limit, query: query)
        let key = cacheKey("catalog", session: session, parts: [req.url!.absoluteString])
        guard let data = try await cacheRead(key, session: session, revision: revision, current: current), data.count <= 1_000_000,
              let page = try? JSONDecoder().decode(CFLStickerPackPage.self, from: data),
              page.packs.count <= limit, page.packs.allSatisfy(\.valid),
              page.nextCursor.map(Self.validStickerCursor) ?? true else { return nil }
        return page
    }
    private func cachedStickerPage(_ path: String, session: String, revision: Int, cursor: String?, limit: Int, query: String?) async throws -> CFLStickerPage? {
        let current = generation
        try thumbnailContext(session, revision, generation: current)
        let req = try stickerRequest(path: path, session: session, cursor: cursor, limit: limit, query: query)
        let key = cacheKey("catalog", session: session, parts: [req.url!.absoluteString])
        guard let data = try await cacheRead(key, session: session, revision: revision, current: current), data.count <= 1_000_000,
              let page = try? JSONDecoder().decode(CFLStickerPage.self, from: data),
              page.stickers.count <= limit, page.stickers.allSatisfy(\.valid),
              page.nextCursor.map(Self.validStickerCursor) ?? true else { return nil }
        return page
    }
    public func cachedStickerPackMembers(_ packId: String, session: String, revision: Int, cursor: String? = nil, limit: Int = 30) async throws -> CFLStickerPage? {
        guard CFLStickerIdentity(id: packId, version: String(repeating: "0", count: 64)).valid else { throw CFLFailure.invalidInput }
        return try await cachedStickerPage("packs/" + packId, session: session, revision: revision, cursor: cursor, limit: limit, query: nil)
    }
    public func cachedSearchStickers(_ query: String, session: String, revision: Int, cursor: String? = nil, limit: Int = 30) async throws -> CFLStickerPage? {
        try await cachedStickerPage("search", session: session, revision: revision, cursor: cursor, limit: limit, query: query)
    }
    public func cachedFavoriteStickers(session: String, revision: Int, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> CFLStickerPage? {
        try await cachedFavoriteSnapshot(session: session, revision: revision, cursor: cursor, limit: limit, query: query)?.page
    }
    public func cachedFavoriteSnapshot(session: String, revision: Int, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> CFLFavoriteSnapshot? {
        let current = generation
        try thumbnailContext(session, revision, generation: current)
        let req = try stickerRequest(path: "favorites", session: session, cursor: cursor, limit: limit, query: query)
        let key = cacheKey("favorite-pages", session: session, parts: [])
        guard let data = try await cacheRead(key, session: session, revision: revision, current: current), data.count <= 1_000_000,
              let archive = try? JSONDecoder().decode(FavoriteArchive.self, from: data),
              let snapshot = archive.pages[req.url!.absoluteString]?.snapshot,
              snapshot.page.stickers.count <= limit, snapshot.page.stickers.allSatisfy(\.valid),
              snapshot.page.nextCursor.map(Self.validStickerCursor) ?? true else { return nil }
        return snapshot
    }
    private func saveFavoritePage(_ page: CFLStickerPage, request: URLRequest, session: String, revision: Int, current: Int, epoch: Int) async {
        await acquireFavoriteSnapshot()
        defer { releaseFavoriteSnapshot() }
        guard let cache = mediaCache, await cacheAuthority() != nil, favoriteEpoch == epoch,
              (try? thumbnailContext(session, revision, generation: current)) != nil,
              let pageKey = request.url?.absoluteString else { return }
        let key = cacheKey("favorite-pages", session: session, parts: [])
        cacheReads.removeValue(forKey: key)
        try? await cache.update(key: key, withoutExpiry: true) { data in
            var archive = data.flatMap { try? JSONDecoder().decode(FavoriteArchive.self, from: $0) } ?? FavoriteArchive()
            archive.pages[pageKey] = FavoriteArchive.Entry(snapshot: CFLFavoriteSnapshot(page: page, needsRevalidation: false), stored: Date())
            while archive.pages.count > 32, let oldest = archive.pages.min(by: { $0.value.stored < $1.value.stored })?.key {
                archive.pages.removeValue(forKey: oldest)
            }
            guard let encoded = try? JSONEncoder().encode(archive), encoded.count <= 1_000_000 else { return nil }
            return encoded
        }
        _ = await cacheAuthority()
    }
    private func updateFavoritePages(_ result: CFLStickerFavoriteResult, session: String, revision: Int, current: Int) async {
        favoriteEpoch += 1
        await acquireFavoriteSnapshot()
        defer { releaseFavoriteSnapshot() }
        guard let cache = mediaCache, await cacheAuthority() != nil,
              (try? thumbnailContext(session, revision, generation: current)) != nil else { return }
        let key = cacheKey("favorite-pages", session: session, parts: [])
        cacheReads.removeValue(forKey: key)
        try? await cache.update(key: key, withoutExpiry: true) { data in
            guard let data, var archive = try? JSONDecoder().decode(FavoriteArchive.self, from: data) else { return nil }
            for (pageKey, entry) in archive.pages {
                let items = result.favorite ? entry.snapshot.page.stickers : entry.snapshot.page.stickers.filter { $0.id != result.sticker.id }
                let page = CFLStickerPage(stickers: items, nextCursor: entry.snapshot.page.nextCursor)
                archive.pages[pageKey] = FavoriteArchive.Entry(snapshot: CFLFavoriteSnapshot(page: page, needsRevalidation: true), stored: entry.stored)
            }
            guard let encoded = try? JSONEncoder().encode(archive), encoded.count <= 1_000_000 else { return nil }
            return encoded
        }
        _ = await cacheAuthority()
    }
    public func stickerPackMembers(_ packId: String, session: String, revision: Int, cursor: String? = nil, limit: Int = 30) async throws -> CFLStickerPage {
        guard CFLStickerIdentity(id: packId, version: String(repeating: "0", count: 64)).valid else { throw CFLFailure.invalidInput }
        return try await stickerPage("packs/" + packId, session: session, revision: revision, cursor: cursor, limit: limit, query: nil)
    }
    public func searchStickers(_ query: String, session: String, revision: Int, cursor: String? = nil, limit: Int = 30) async throws -> CFLStickerPage {
        try await stickerPage("search", session: session, revision: revision, cursor: cursor, limit: limit, query: query)
    }
    public func favoriteStickers(session: String, revision: Int, cursor: String? = nil, limit: Int = 30, query: String? = nil) async throws -> CFLStickerPage {
        try await stickerPage("favorites", session: session, revision: revision, cursor: cursor, limit: limit, query: query)
    }
    private func stickerPost<T: Decodable>(_ type: T.Type, path: String, body: [String: Any], session: String, revision: Int) async throws -> (T, ChordJSON) {
        var req = try request(path: "/api/stickers/" + path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await stickerJSON(type, request: req, session: session, revision: revision)
    }
    private func favoriteResult(path: String, body: [String: Any], session: String, revision: Int, expectedId: String?, favorite: Bool) async throws -> CFLStickerFavoriteResult {
        let current = try stickerContext(session, revision)
        let (result, wire) = try await stickerPost(CFLStickerFavoriteResult.self, path: path, body: body, session: session, revision: revision)
        guard let fields = wire.object, Set(fields.keys) == Set(["sticker", "favorite"]), let sticker = fields["sticker"],
              validStickerWire(sticker), result.sticker.valid, result.favorite == favorite,
              expectedId.map({ $0 == result.sticker.id }) ?? true else { throw CFLFailure.protocolError }
        await updateFavoritePages(result, session: session, revision: revision, current: current)
        try checkStickerContext(session, revision, current)
        return result
    }
    public func setStickerFavorite(_ id: String, favorite: Bool, session: String, revision: Int) async throws -> CFLStickerFavoriteResult {
        guard CFLStickerIdentity(id: id, version: String(repeating: "0", count: 64)).valid else { throw CFLFailure.invalidInput }
        return try await favoriteResult(path: "favorites", body: ["sessionId": session, "stickerId": id, "favorite": favorite], session: session, revision: revision, expectedId: id, favorite: favorite)
    }
    /// Existing sticker identities never fall back to creating a new catalog item.
    public func favoriteChatImage(_ image: CFLImageRef, session: String, revision: Int) async throws -> CFLStickerFavoriteResult {
        guard image.valid, image.availability == "available" else { throw CFLFailure.invalidInput }
        if let sticker = image.sticker {
            return try await setStickerFavorite(sticker.id, favorite: true, session: session, revision: revision)
        }
        var label = image.name.trimmingCharacters(in: .whitespacesAndNewlines)
        while label.utf16.count > 160 { label.removeLast() }
        return try await favoriteResult(path: "favorites/image", body: ["sessionId": session, "imageId": image.attachmentId,
            "name": label.isEmpty ? "聊天图片" : label, "tags": [String]()], session: session, revision: revision, expectedId: nil, favorite: true)
    }
    private func thumbnailContext(_ session: String, _ revision: Int, generation current: Int) throws {
        guard !Task.isCancelled, active, !disconnecting, generation == current,
              state.connection != .accessDenied, state.sessionId == session, sessionRevision == revision else { throw CFLFailure.sessionChanged }
    }
    private func thumbnailAuthority() async throws -> UUID? {
        guard let authority = imageHTTP as? any CFLStickerCacheAuthority else { return nil }
        do { return try await authority.stickerThumbnailScope() }
        catch CFLFailure.accessDenied { clearThumbnails(); throw CFLFailure.accessDenied }
    }
    private func adoptThumbnailScope(_ scope: UUID) {
        if thumbnailScope != scope { clearThumbnails(); thumbnailScope = scope }
    }
    private func retainThumbnail(_ data: Data, etag: String?, for key: ThumbnailKey) {
        thumbnailClock &+= 1
        thumbnails[key] = ThumbnailEntry(data: data, etag: etag, used: thumbnailClock)
        while thumbnails.count > thumbnailCountLimit || thumbnails.values.reduce(0, { $0 + $1.data.count }) > thumbnailByteLimit {
            guard let oldest = thumbnails.min(by: { $0.value.used < $1.value.used })?.key else { break }
            thumbnails.removeValue(forKey: oldest)
        }
    }
    /// Returns a bounded in-memory or persistent copy for this session;
    /// render it immediately and separately call stickerMedia to revalidate it.
    /// A nil result also means the transport cannot establish an identity scope.
    public func cachedStickerThumbnail(_ sticker: CFLSticker, session: String, revision: Int) async throws -> Data? {
        guard sticker.valid else { throw CFLFailure.invalidInput }
        let current = generation
        try thumbnailContext(session, revision, generation: current)
        if !sticker.available {
            cancelThumbnailFlight(ThumbnailKey(session: session, id: sticker.id, version: sticker.version))
            throw CFLStickerThumbnailFailure.removed
        }
        guard let scope = try await thumbnailAuthority() else { return nil }
        try thumbnailContext(session, revision, generation: current)
        adoptThumbnailScope(scope)
        let key = ThumbnailKey(session: session, id: sticker.id, version: sticker.version)
        if thumbnails[key] == nil {
            let diskKey = cacheKey("sticker-thumbnail", session: session, parts: [sticker.id, sticker.version])
            if let data = try await cacheRead(diskKey, session: session, revision: revision, current: current) {
                let bytes = [UInt8](data.prefix(12))
                if data.count <= 160_000, bytes.count == 12,
                   bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
                    retainThumbnail(data, etag: nil, for: key)
                } else { await cacheRemove(diskKey) }
            }
        }
        guard var entry = thumbnails[key] else { return nil }
        thumbnailClock &+= 1; entry.used = thumbnailClock; thumbnails[key] = entry
        return entry.data
    }
    /// Revalidates thumbnails; a 304 reuses an identity-bound cached value.
    /// HTTP errors retain existing copies; a later successful response refreshes them.
    /// Originals are fetched independently and cached on demand.
    public func stickerMedia(_ sticker: CFLSticker, original: Bool = false, session: String, revision: Int, revalidate: Bool = false) async throws -> Data {
        guard sticker.valid else { throw CFLFailure.invalidInput }
        let current = generation
        if original && !revalidate {
            try thumbnailContext(session, revision, generation: current)
        } else {
            _ = try stickerContext(session, revision)
        }
        if !sticker.available {
            cancelThumbnailFlight(ThumbnailKey(session: session, id: sticker.id, version: sticker.version))
            throw CFLStickerThumbnailFailure.removed
        }
        if original {
            let diskKey = cacheKey("sticker-original", session: session, parts: [sticker.id, sticker.version])
            if !revalidate, let cached = try await cacheRead(diskKey, session: session, revision: revision, current: current) {
                if cached.count <= 5 * 1024 * 1024, Self.supportedImageBytes(cached) {
                    if state.connection == .online {
                        Task { [weak self] in _ = try? await self?.stickerMedia(sticker, original: true, session: session, revision: revision, revalidate: true) }
                    }
                    return cached
                }
                await cacheRemove(diskKey)
            }
            let onlineGeneration = try stickerContext(session, revision)
            guard onlineGeneration == current else { throw CFLFailure.sessionChanged }
            let version = UUID(); cacheVersions[diskKey] = version
            defer { if cacheVersions[diskKey] == version { cacheVersions.removeValue(forKey: diskKey) } }
            let scope = try await thumbnailAuthority()
            try checkStickerContext(session, revision, current)
            let req = try request(path: "/api/stickers/media/\(sticker.version)/original", method: "GET")
            let (data, response): (Data, HTTPURLResponse)
            do { (data, response) = try await imageResponse(req) }
            catch {
                try checkStickerContext(session, revision, current)
                if (error as? CFLFailure) == .accessDenied {
                    if scope != nil { _ = try? await thumbnailAuthority() }
                    else { clearThumbnails() }
                }
                throw error
            }
            try checkStickerContext(session, revision, current)
            if let scope {
                let after = try await thumbnailAuthority()
                try checkStickerContext(session, revision, current)
                guard after == scope else { throw CFLFailure.sessionChanged }
            }
            let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
            guard !data.isEmpty, data.count <= 5 * 1024 * 1024, type == sticker.mediaType else { throw CFLFailure.protocolError }
            await cacheWrite(data, key: diskKey, session: session, revision: revision, current: current, version: version)
            try checkStickerContext(session, revision, current)
            if let scope, try await thumbnailAuthority() != scope { throw CFLFailure.sessionChanged }
            return data
        }
        let scope = try await thumbnailAuthority()
        try checkStickerContext(session, revision, current)
        if let scope { adoptThumbnailScope(scope) }
        let key = ThumbnailKey(session: session, id: sticker.id, version: sticker.version)
        let flight: ThumbnailFlight
        if var existing = thumbnailFlights[key], existing.generation == current,
           existing.revision == revision, existing.scope == scope {
            existing.waiters += 1
            thumbnailFlights[key] = existing
            flight = existing
        } else {
            thumbnailFlights.removeValue(forKey: key)?.task.cancel()
            let token = UUID()
            let task = Task { try await self.loadStickerThumbnail(key, scope: scope, generation: current, revision: revision, token: token) }
            flight = ThumbnailFlight(token: token, generation: current, revision: revision, scope: scope, task: task, waiters: 1)
            thumbnailFlights[key] = flight
        }
        defer { finishThumbnailWaiter(key, token: flight.token) }
        let data = try await flight.task.value
        try checkStickerContext(session, revision, current)
        if let scope {
            let after = try await thumbnailAuthority()
            try checkStickerContext(session, revision, current)
            guard after == scope else { throw CFLFailure.sessionChanged }
        }
        guard thumbnailFlights[key]?.token == flight.token else { throw CFLFailure.sessionChanged }
        return data
    }
    /// One task owns validation/cache mutation; all current waiters share its result.
    private func loadStickerThumbnail(_ key: ThumbnailKey, scope: UUID?, generation current: Int, revision: Int, token: UUID) async throws -> Data {
        let session = key.session
        let diskKey = cacheKey("sticker-thumbnail", session: session, parts: [key.id, key.version])
        cacheVersions[diskKey] = token
        defer { if cacheVersions[diskKey] == token { cacheVersions.removeValue(forKey: diskKey) } }
        var req = try request(path: "/api/stickers/media/\(key.version)/thumbnail", method: "GET")
        let cached = scope == nil ? nil : thumbnails[key]
        if let etag = cached?.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let result: (Data, URLResponse)
        do { result = try await imageHTTP.data(for: req) }
        catch {
            try checkStickerContext(session, revision, current)
            if let scope {
                let after = try await thumbnailAuthority()
                try checkStickerContext(session, revision, current)
                guard after == scope, thumbnailFlights[key]?.token == token else { throw CFLFailure.sessionChanged }
            } else if thumbnailFlights[key]?.token != token { throw CFLFailure.sessionChanged }
            if (error as? CFLFailure) == .accessDenied { clearThumbnails() }
            throw error
        }
        try checkStickerContext(session, revision, current)
        if let scope {
            let after = try await thumbnailAuthority()
            try checkStickerContext(session, revision, current)
            guard after == scope, thumbnailFlights[key]?.token == token else { throw CFLFailure.sessionChanged }
        } else if thumbnailFlights[key]?.token != token { throw CFLFailure.sessionChanged }
        guard let response = result.1 as? HTTPURLResponse, response.url == req.url else { throw CFLFailure.protocolError }
        if response.statusCode == 403 || response.statusCode == 404 { throw CFLFailure.requestFailed }
        if response.statusCode == 401 { clearThumbnails(); throw CFLFailure.accessDenied }
        if response.statusCode == 304 {
            guard let cached, let etag = cached.etag,
                  response.value(forHTTPHeaderField: "ETag") == etag,
                  thumbnails[key]?.etag == etag else { throw CFLFailure.protocolError }
            retainThumbnail(cached.data, etag: etag, for: key)
            return cached.data
        }
        guard (200...299).contains(response.statusCode) else { throw CFLFailure.requestFailed }
        let data = result.0
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        let bytes = [UInt8](data.prefix(12))
        guard type == "image/webp", !data.isEmpty, data.count <= 160_000,
              bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) else { throw CFLFailure.protocolError }
        let rawETag = response.value(forHTTPHeaderField: "ETag")
        let etag = rawETag.flatMap { value in
            !value.isEmpty && value.utf8.count <= 256 && value.rangeOfCharacter(from: .controlCharacters) == nil ? value : nil
        }
        if scope != nil { retainThumbnail(data, etag: etag, for: key) }
        await cacheWrite(data, key: diskKey, session: session, revision: revision, current: current, version: token, withoutExpiry: true)
        return data
    }
    private func stageSticker(_ sticker: CFLSticker, session: String, operation: String) async throws -> CFLImageRef {
        struct Result: Decodable { let sessionId: String; let operationId: String; let image: CFLImageRef }
        let (result, wire) = try await stickerPost(Result.self, path: "stage", body: ["sessionId": session, "operationId": operation,
            "sticker": ["id": sticker.id, "version": sticker.version]], session: session, revision: sessionRevision)
        guard let fields = wire.object, Set(fields.keys) == Set(["sessionId", "operationId", "image"]), let image = fields["image"],
              validImageWire(image), result.sessionId == session, result.operationId == operation,
              result.image.valid, result.image.availability == "available", result.image.sticker == sticker.identity,
              result.image.mediaType == sticker.mediaType else { throw CFLFailure.protocolError }
        return result.image
    }
    /// Read a contract-approved relative media path with the current authenticated
    /// transport. Cancel the caller's Task when the scheme task stops. Audio Range
    /// requests are served by slicing a bounded full response, never by forwarding
    /// arbitrary request headers. Images do not accept Range.
    public func rendererMedia(_ path: String, range: String? = nil, expectedSessionId: String,
                              expectedSessionRevision: Int) async throws -> CFLRendererMediaResponse {
        if let workspace = CFLWorkspaceRendererResource.parse(path) {
            return try await rendererWorkspaceMedia(workspace, range: range, session: expectedSessionId, revision: expectedSessionRevision).response
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let isAudio: Bool
        let variant: String
        if components.count == 6, components[0].isEmpty, components[1] == "api", components[2] == "chat", components[3] == "media" {
            let id = components[4]
            guard !id.isEmpty, id.utf8.count <= 100, id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }), ["original", "preview", "model"].contains(String(components[5])), range == nil else { throw CFLFailure.invalidInput }
            isAudio = false; variant = String(components[5])
        } else if components.count == 4, components[0].isEmpty, components[1] == "api", components[2] == "audio",
                  components[3].hasSuffix(".mp3"), CFLVoiceRef(id: String(components[3].dropLast(4))).valid {
            isAudio = true; variant = "audio"
        } else { throw CFLFailure.invalidInput }
        // Parse before issuing any authenticated request; multiple ranges are unsupported.
        var bounds: (Int?, Int?)?
        if let range {
            guard isAudio, range.hasPrefix("bytes="), !range.contains(",") else { throw CFLFailure.invalidInput }
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, !(parts[0].isEmpty && parts[1].isEmpty),
                  parts.allSatisfy({ $0.isEmpty || $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  (parts[0].isEmpty || Int(parts[0]) != nil), (parts[1].isEmpty || Int(parts[1]) != nil) else { throw CFLFailure.invalidInput }
            bounds = (Int(parts[0]), Int(parts[1]))
        }
        let current = try stickerContext(expectedSessionId, expectedSessionRevision)
        let req = try request(path: path, method: "GET")
        let limit = variant == "preview" ? 160_000 : (variant == "model" ? 320_000 : 32 * 1024 * 1024)
        let (data, raw) = try await imageHTTP.boundedData(for: req, maximumBytes: limit)
        try Task.checkCancellation()
        try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
        guard let response = raw as? HTTPURLResponse, response.url == req.url else { throw CFLFailure.protocolError }
        guard response.statusCode == 200 else {
            throw response.statusCode == 401 || response.statusCode == 403 ? CFLFailure.accessDenied : CFLFailure.requestFailed
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        guard !data.isEmpty, data.count <= limit, let type,
              (isAudio ? type == "audio/mpeg" : (CFLImageLimits.types.contains(type) && (variant == "original" || type == "image/jpeg"))) else { throw CFLFailure.protocolError }
        var headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard isAudio else { return CFLRendererMediaResponse(data: data, statusCode: 200, headers: headers) }
        headers["Accept-Ranges"] = "bytes"
        guard let bounds else { return CFLRendererMediaResponse(data: data, statusCode: 200, headers: headers) }
        let start: Int, end: Int
        if let first = bounds.0 {
            start = first; end = min(bounds.1 ?? (data.count - 1), data.count - 1)
        } else {
            let suffix = bounds.1 ?? 0
            start = max(0, data.count - min(suffix, data.count)); end = data.count - 1
        }
        guard start < data.count, start <= end else {
            headers["Content-Range"] = "bytes */\(data.count)"; headers["Content-Length"] = "0"
            return CFLRendererMediaResponse(data: Data(), statusCode: 416, headers: headers)
        }
        let partial = data.subdata(in: start..<(end + 1))
        headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
        headers["Content-Length"] = String(partial.count)
        return CFLRendererMediaResponse(data: partial, statusCode: 206, headers: headers)
    }
    // Version stays native and is never included in the scheme response headers.
    private func rendererWorkspaceMedia(_ resource: CFLWorkspaceRendererResource, range: String?, session: String,
                                        revision: Int, version: String? = nil) async throws -> (response: CFLRendererMediaResponse, version: String?) {
        let parsedRange: CFLWorkspaceRange?
        if let range {
            guard resource.kind != .image, let parsed = CFLWorkspaceRange.parse(range) else { throw CFLFailure.invalidInput }
            parsedRange = parsed
        } else { parsedRange = nil }
        let current = try stickerContext(session, revision)
        var req = try request(path: resource.path, method: "GET")
        if let parsedRange { req.setValue(parsedRange.request, forHTTPHeaderField: "Range") }
        if let version { req.setValue(version, forHTTPHeaderField: "If-CFL-Media-Version") }
        let limit = parsedRange == nil ? (resource.kind == .image ? 20 * 1024 * 1024 : 32 * 1024 * 1024) : CFLWorkspaceRange.segmentBytes
        let (data, raw) = try await imageHTTP.boundedData(for: req, maximumBytes: limit)
        try Task.checkCancellation()
        try checkStickerContext(session, revision, current)
        guard let response = raw as? HTTPURLResponse, response.url == req.url else { throw CFLFailure.protocolError }
        if response.statusCode == 401 || response.statusCode == 403 { throw CFLFailure.accessDenied }
        if response.statusCode == 416, let parsedRange {
            let header = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard header.hasPrefix("bytes */"), let total = Int(header.dropFirst(8)),
                  total >= 0, total <= CFLWorkspaceRange.maximumTotal, header == "bytes */\(total)",
                  parsedRange.expected(total: total) == nil, data.isEmpty else { throw CFLFailure.protocolError }
            return (CFLRendererMediaResponse(data: Data(), statusCode: 416,
                headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0", "Accept-Ranges": "bytes", "Cache-Control": "no-store"]), nil)
        }
        guard response.statusCode == (parsedRange == nil ? 200 : 206) else { throw CFLFailure.requestFailed }
        let returnedVersion: String?
        if resource.kind == .image { returnedVersion = nil }
        else {
            guard response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
                  let token = response.value(forHTTPHeaderField: "X-CFL-Media-Version"),
                  !token.isEmpty, token.utf8.count <= 256,
                  token.utf8.allSatisfy({ (33...126).contains($0) }),
                  version == nil || version == token else { throw CFLFailure.protocolError }
            returnedVersion = token
        }
        guard !data.isEmpty, data.count <= limit,
              let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased(),
              resource.accepts(type) else { throw CFLFailure.protocolError }
        if let rawLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int(rawLength), rawLength == String(length), length == data.count else { throw CFLFailure.protocolError }
        } else if resource.kind != .image { throw CFLFailure.protocolError }
        var headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        if resource.kind != .image { headers["Accept-Ranges"] = "bytes" }
        if let parsedRange {
            let header = response.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard header.hasPrefix("bytes ") else { throw CFLFailure.protocolError }
            let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let total = Int(parts[1]), let expected = parsedRange.expected(total: total) else { throw CFLFailure.protocolError }
            let exact = "bytes \(expected.0)-\(expected.1)/\(total)"
            guard header == exact, data.count == expected.1 - expected.0 + 1 else { throw CFLFailure.protocolError }
            headers["Content-Range"] = exact
        } else if response.value(forHTTPHeaderField: "Content-Range") != nil { throw CFLFailure.protocolError }
        return (CFLRendererMediaResponse(data: data, statusCode: response.statusCode, headers: headers), returnedVersion)
    }

    /// Streams a workspace audio/video URL for a missing or single byte Range.
    /// Callbacks are serial and awaited on the caller's task; no executor is
    /// prescribed. The scheme handler must marshal to its own executor, cancel
    /// on stop, and check its stopped state before every WebKit callback.
    /// A version mismatch, 412, cancellation, or session change terminates the
    /// stream; the handler must fail an already-started scheme task on errors.
    public func rendererWorkspaceMediaStream(_ path: String, range: String? = nil,
        expectedSessionId: String, expectedSessionRevision: Int,
        onResponse: @Sendable (CFLRendererMediaResponse) async throws -> Void,
        onChunk: @Sendable (Data) async throws -> Void) async throws {
        guard let resource = CFLWorkspaceRendererResource.parse(path), resource.kind != .image else { throw CFLFailure.invalidInput }
        let requested: CFLWorkspaceRange?
        if let range {
            guard let value = CFLWorkspaceRange.parse(range) else { throw CFLFailure.invalidInput }
            requested = value
        } else { requested = nil }
        let current = try stickerContext(expectedSessionId, expectedSessionRevision)
        // A one-byte probe works for closed, open, suffix and unsatisfiable
        // ranges alike, without asking CFL for an unbounded response.
        let probe = try await rendererWorkspaceMedia(resource, range: "bytes=0-0", session: expectedSessionId,
                                                      revision: expectedSessionRevision)
        guard probe.response.statusCode == 206, let version = probe.version,
              let type = probe.response.headers["Content-Type"],
              let header = probe.response.headers["Content-Range"],
              let slash = header.lastIndex(of: "/"), let total = Int(header[header.index(after: slash)...]),
              total > 0, total <= CFLWorkspaceRange.maximumTotal else { throw CFLFailure.protocolError }
        let bounds: (Int, Int)
        if let requested {
            guard let result = requested.requested(total: total) else {
                try Task.checkCancellation()
                try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
                try await onResponse(CFLRendererMediaResponse(data: Data(), statusCode: 416,
                    headers: ["Content-Range": "bytes */\(total)", "Content-Length": "0", "Accept-Ranges": "bytes", "Cache-Control": "no-store"]))
                return
            }
            bounds = result
        } else { bounds = (0, total - 1) }
        var headers = ["Content-Type": type, "Content-Length": String(bounds.1 - bounds.0 + 1),
                       "Accept-Ranges": "bytes", "Cache-Control": "no-store"]
        if requested != nil { headers["Content-Range"] = "bytes \(bounds.0)-\(bounds.1)/\(total)" }
        try Task.checkCancellation()
        try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
        try await onResponse(CFLRendererMediaResponse(data: Data(), statusCode: requested == nil ? 200 : 206, headers: headers))
        var offset = bounds.0
        while offset <= bounds.1 {
            try Task.checkCancellation()
            try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
            let last = min(bounds.1, offset + CFLWorkspaceRange.segmentBytes - 1)
            let result = try await rendererWorkspaceMedia(resource, range: "bytes=\(offset)-\(last)", session: expectedSessionId,
                                                          revision: expectedSessionRevision, version: version)
            let response = result.response
            guard response.statusCode == 206, result.version == version, response.headers["Content-Type"] == type,
                  response.headers["Content-Range"] == "bytes \(offset)-\(last)/\(total)" else { throw CFLFailure.protocolError }
            try Task.checkCancellation()
            try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
            try await onChunk(response.data)
            try Task.checkCancellation()
            try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
            offset += response.data.count
        }
    }
    /// Loads a voice from this connection's origin. Cancel on disappearance and
    /// discard results if the owning client changes.
    public func voice(_ ref: CFLVoiceRef, expectedSessionId: String, expectedSessionRevision: Int) async throws -> Data {
        guard ref.valid else { throw CFLFailure.invalidInput }
        guard active, !disconnecting, state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        guard session == expectedSessionId, sessionRevision == expectedSessionRevision else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        let current = generation, revision = sessionRevision
        let request = try request(path: "/api/audio/\(ref.id).mp3", method: "GET")
        let (data, response) = try await imageResponse(request)
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
              state.sessionId == session, state.connection == .online else { throw CFLFailure.sessionChanged }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        guard !data.isEmpty, type == "audio/mpeg" else { throw CFLFailure.protocolError }
        return data
    }
    /// Read an original Markdown destination using this connection's authorized HTTP transport.
    /// The UI must cancel on disappearance and discard results if its owning client/target changes.
    public func markdownImage(_ source: String, expectedSessionId: String, expectedSessionRevision: Int, revalidate: Bool = false) async throws -> Data {
        guard active, !disconnecting, let session = state.sessionId else { throw CFLFailure.offline }
        guard session == expectedSessionId, sessionRevision == expectedSessionRevision else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        let current = generation, revision = sessionRevision
        let path: String
        switch CFLMarkdownImage.resolve(source) {
        case .workspace(let literal):
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
            guard let encoded = literal.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CFLFailure.invalidInput }
            path = "/api/chat/workspace-image?path=" + encoded
        case .api(let raw):
            // A relative API URL may not change authority or escape the API path.
            guard raw.removingPercentEncoding != nil, let parts = URLComponents(string: raw), parts.scheme == nil, parts.host == nil,
                  parts.fragment == nil, parts.percentEncodedPath.hasPrefix("/api/"),
                  parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ segment in
                      guard let decoded = String(segment).removingPercentEncoding else { return false }
                      return decoded != "." && decoded != ".." && !decoded.contains("/") && !decoded.contains("\\") && decoded.rangeOfCharacter(from: .controlCharacters) == nil
                  }) else { throw CFLFailure.invalidInput }
            path = raw
        case .external, .invalid: throw CFLFailure.invalidInput
        }
        let key = cacheKey("markdown", session: session, parts: [path])
        if !revalidate, let data = try await cacheRead(key, session: session, revision: revision, current: current) {
            if !data.isEmpty && data.count <= 32 * 1024 * 1024 {
                if state.connection == .online {
                    Task { [weak self] in _ = try? await self?.markdownImage(source, expectedSessionId: session, expectedSessionRevision: revision, revalidate: true) }
                }
                return data
            }
            await cacheRemove(key)
        }
        guard state.connection == .online else { throw CFLFailure.offline }
        let version = UUID(); cacheVersions[key] = version
        defer { if cacheVersions[key] == version { cacheVersions.removeValue(forKey: key) } }
        let scope = await cacheAuthority()
        let request = try request(path: path, method: "GET")
        let (data, response) = try await imageResponse(request, allowNotFound: true)
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
              state.sessionId == session, state.connection == .online else { throw CFLFailure.sessionChanged }
        if let scope, await cacheAuthority() != scope { throw CFLFailure.sessionChanged }
        if response.statusCode == 404 { await cacheRemove(key); throw CFLFailure.requestFailed }
        if !data.isEmpty, data.count <= 32 * 1024 * 1024 {
            await cacheWrite(data, key: key, session: session, revision: revision, current: current, version: version)
        }
        try checkStickerContext(session, revision, current)
        if let scope, await cacheAuthority() != scope { throw CFLFailure.sessionChanged }
        return data
    }
    /// External HTTPS is fetched without CFL credentials. Explicit storage
    /// prohibitions are honored for the final response and every redirect.
    public func externalImage(_ source: String, expectedSessionId: String, expectedSessionRevision: Int) async throws -> Data {
        guard case .external = CFLMarkdownImage.resolve(source) else { throw CFLFailure.invalidInput }
        let current = generation, session = expectedSessionId, revision = expectedSessionRevision
        try thumbnailContext(session, revision, generation: current)
        let bytesKey = cacheKey("external-image", session: session, parts: [source])
        let dateKey = cacheKey("external-expiration", session: session, parts: [source])
        if let dateData = try await cacheRead(dateKey, session: session, revision: revision, current: current),
           let record = (try? JSONDecoder().decode(ExternalImageCacheRecord.self, from: dateData)) ??
               (try? JSONDecoder().decode(Date.self, from: dateData)).map({ ExternalImageCacheRecord(freshUntil: $0) }),
           record.freshUntil.map({ $0 > Date() }) ?? true,
           let data = try await cacheRead(bytesKey, session: session, revision: revision, current: current),
           !data.isEmpty, data.count <= 32 * 1024 * 1024 { return data }
        let version = UUID(); cacheVersions[bytesKey] = version; cacheVersions[dateKey] = version
        defer {
            if cacheVersions[bytesKey] == version { cacheVersions.removeValue(forKey: bytesKey) }
            if cacheVersions[dateKey] == version { cacheVersions.removeValue(forKey: dateKey) }
        }
        let result = try await externalImageLoader.response(for: source)
        try thumbnailContext(session, revision, generation: current)
        let record: ExternalImageCacheRecord?
        switch result.policy {
        case .prohibited: record = nil
        case .lastAccess: record = ExternalImageCacheRecord(freshUntil: nil)
        case .until(let date): record = ExternalImageCacheRecord(freshUntil: date)
        }
        if let record, !result.data.isEmpty, result.data.count <= 32 * 1024 * 1024,
           let dateData = try? JSONEncoder().encode(record) {
            if await cacheWrite(result.data, key: bytesKey, session: session, revision: revision, current: current, version: version) {
                await cacheWrite(dateData, key: dateKey, session: session, revision: revision, current: current, version: version)
            }
        }
        try thumbnailContext(session, revision, generation: current)
        return result.data
    }
    private func upload(_ images: [CFLPreparedImage], session: String, operation: String) async throws -> [CFLImageRef] {
        let items: [[String: Any]] = images.enumerated().map { index, image in
            ["id": image.id, "order": index, "name": image.name, "mediaType": image.mediaType,
             "original": image.original.base64EncodedString(), "preview": image.preview.base64EncodedString(), "model": image.model.base64EncodedString()]
        }
        var request = try request(path: "/api/chat/images", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": session, "operationId": operation, "images": items])
        guard (request.httpBody?.count ?? 0) <= 36_000_000 else { throw CFLFailure.invalidInput }
        let (data, _) = try await imageResponse(request)
        struct Result: Decodable {
            struct Item: Decodable { let id: String; let order: Int; let ref: CFLImageRef }
            let sessionId: String; let operationId: String; let images: [Item]
        }
        guard data.count <= 100_000, let wire = try? JSONDecoder().decode(ChordJSON.self, from: data), let fields = wire.object,
              Set(fields.keys) == Set(["sessionId", "operationId", "images"]), let rawImages = fields["images"]?.array,
              rawImages.allSatisfy({ item in
                  guard let value = item.object, Set(value.keys) == Set(["id", "order", "ref"]), let ref = value["ref"] else { return false }
                  return validImageWire(ref)
              }),
              let result = try? JSONDecoder().decode(Result.self, from: data),
              result.sessionId == session, result.operationId == operation, result.images.count == images.count,
              Set(result.images.map(\.id)).count == images.count, Set(result.images.map { $0.ref.attachmentId }).count == images.count,
              result.images.enumerated().allSatisfy({ index, item in
                  item.order == index && item.id == images[index].id && item.ref.valid && item.ref.availability == "available"
                    && item.ref.name == images[index].name && item.ref.mediaType == images[index].mediaType
              }) else { throw CFLFailure.protocolError }
        return result.images.map(\.ref)
    }
    private func fileUploadResult(_ data: Data, files: [CFLPreparedFile], session: String, operation: String) throws -> [CFLFileRef] {
        struct Result: Decodable {
            struct Item: Decodable { let id: String; let order: Int; let ref: CFLFileRef }
            let sessionId: String, operationId: String
            let files: [Item]
        }
        guard data.count <= 100_000, let wire = try? JSONDecoder().decode(ChordJSON.self, from: data),
              let fields = wire.object, Set(fields.keys) == Set(["sessionId", "operationId", "files"]),
              let raw = fields["files"]?.array, raw.allSatisfy({ item in
                  guard let fields = item.object, Set(fields.keys) == Set(["id", "order", "ref"]), let ref = fields["ref"] else { return false }
                  return validFileWire(ref)
              }), let result = try? JSONDecoder().decode(Result.self, from: data),
              result.sessionId == session, result.operationId == operation, result.files.count == files.count,
              Set(result.files.map(\.id)).count == files.count, Set(result.files.map { $0.ref.attachmentId }).count == files.count,
              result.files.enumerated().allSatisfy({ index, item in
                  item.order == index && item.id == files[index].id && item.ref.availability == "available" &&
                  item.ref.name.utf8.elementsEqual(files[index].name.utf8) && item.ref.mediaType.utf8.elementsEqual(files[index].mediaType.utf8) && item.ref.size == files[index].size
              }) else { throw CFLFailure.protocolError }
        return result.files.map(\.ref)
    }
    private func fileOperationStatus(_ data: Data, files: [CFLPreparedFile], session: String, operation: String) throws -> CFLFileStagingStatus {
        guard data.count <= 100_000, let raw = try? JSONDecoder().decode(ChordJSON.self, from: data),
              let fields = raw.object, Set(fields.keys).subtracting(["result"]) == Set(["manifest", "uploaded"]),
              let manifest = fields["manifest"]?.object, Set(manifest.keys) == Set(["sessionId", "operationId", "files"]),
              manifest["sessionId"]?.string == session, manifest["operationId"]?.string == operation,
              let items = manifest["files"]?.array, items.count == files.count,
              items.enumerated().allSatisfy({ index, item in
                  guard let values = item.object, Set(values.keys) == Set(["id", "name", "mediaType", "size"]),
                        let name = values["name"]?.string, let type = values["mediaType"]?.string else { return false }
                  return values["id"]?.string == files[index].id && name.utf8.elementsEqual(files[index].name.utf8) &&
                      type.utf8.elementsEqual(files[index].mediaType.utf8) && values["size"]?.integer == files[index].size
              }), let rawUploaded = fields["uploaded"]?.array else { throw CFLFailure.protocolError }
        let uploaded = rawUploaded.compactMap(\.string)
        guard uploaded.count == rawUploaded.count, Set(uploaded).count == uploaded.count,
              Set(uploaded).isSubset(of: Set(files.map(\.id))) else { throw CFLFailure.protocolError }
        var result: [CFLFileRef]?
        if let rawResult = fields["result"] {
            guard uploaded.count == files.count else { throw CFLFailure.protocolError }
            result = try fileUploadResult(JSONEncoder().encode(rawResult), files: files, session: session, operation: operation)
        }
        return CFLFileStagingStatus(uploaded: uploaded, files: result)
    }
    private func verifyFileSnapshot(_ file: CFLPreparedFile) async throws {
        let task = Task.detached { try CFLFileDraftStorage.verify(file) }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func uploadFileOperation(_ files: [CFLPreparedFile], session: String, operation: String, generation current: Int, revision: Int) async throws -> [CFLFileRef] {
        let expectedLimits = state.fileLimits
        func check() throws {
            guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
                  state.connection == .online, state.sessionId == session, state.fileLimits == expectedLimits else { throw CFLFailure.sessionChanged }
        }
        for file in files { try await verifyFileSnapshot(file); try check() }
        let manifest: [String: Any] = ["sessionId": session, "operationId": operation, "files": files.map {
            ["id": $0.id, "name": $0.name, "mediaType": $0.mediaType, "size": $0.size] as [String: Any]
        }]
        var reserved = false
        do {
            try check()
            var req = try request(path: "/api/chat/file-operations", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: manifest)
            guard (req.httpBody?.count ?? 0) <= 32_768 else { throw CFLFailure.invalidInput }
            reserved = true
            let (data, raw) = try await imageHTTP.boundedData(for: req, maximumBytes: 100_000)
            try check()
            if let response = raw as? HTTPURLResponse, response.url == req.url {
                if response.statusCode == 410 { throw CFLFileOperationRetired() }
                if response.statusCode == 401 || response.statusCode == 403 { throw CFLFailure.accessDenied }
            }
            guard let response = raw as? HTTPURLResponse, response.url == req.url, (200...299).contains(response.statusCode) else { throw CFLFailure.requestFailed }
            let initial = try fileOperationStatus(data, files: files, session: session, operation: operation)
            guard initial.uploaded.isEmpty, initial.files == nil else { throw CFLFailure.protocolError }
            for file in files {
                try check(); try await verifyFileSnapshot(file); try check()
                var upload = try request(path: "/api/chat/file-operations/" + operation + "/files/" + file.id, method: "PUT")
                upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                upload.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
                let (_, rawUpload) = try await imageHTTP.uploadFile(for: upload, from: file.ownedFileURL, maximumResponseBytes: 0)
                try check(); try await verifyFileSnapshot(file); try check()
                if let response = rawUpload as? HTTPURLResponse, response.url == upload.url {
                    if response.statusCode == 410 { throw CFLFileOperationRetired() }
                    if response.statusCode == 401 || response.statusCode == 403 { throw CFLFailure.accessDenied }
                }
                guard let response = rawUpload as? HTTPURLResponse, response.url == upload.url, response.statusCode == 204 else { throw CFLFailure.requestFailed }
            }
            try check()
            let complete = try request(path: "/api/chat/file-operations/" + operation + "/complete", method: "POST")
            let (result, rawComplete) = try await imageHTTP.boundedData(for: complete, maximumBytes: 100_000)
            try check()
            if let response = rawComplete as? HTTPURLResponse, response.url == complete.url {
                if response.statusCode == 410 { throw CFLFileOperationRetired() }
                if response.statusCode == 401 || response.statusCode == 403 { throw CFLFailure.accessDenied }
            }
            guard let response = rawComplete as? HTTPURLResponse, response.url == complete.url, (200...299).contains(response.statusCode) else { throw CFLFailure.requestFailed }
            return try fileUploadResult(result, files: files, session: session, operation: operation)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if (error as? CFLFailure) == .accessDenied { throw error }
            if error is CFLFileOperationRetired { throw error }
            guard reserved else { throw error }
            throw CFLFileStagingUncertain(sessionId: session, operationId: operation)
        }
    }
    /// Fetch to a newly created app-private file. The caller owns the returned
    /// URL and must delete it when no longer needed; metadata is never a path.
    public func downloadFile(_ ref: CFLFileRef, directory: URL, expectedSessionId: String, expectedSessionRevision: Int) async throws -> URL {
        guard ref.valid, ref.availability == "available", directory.isFileURL else { throw CFLFailure.invalidInput }
        let current = try stickerContext(expectedSessionId, expectedSessionRevision)
        let destination = try CFLFileDraftStorage.createEmpty(in: directory)
        do {
            let req = try request(path: "/api/chat/files/" + ref.attachmentId, method: "GET")
            let raw = try await imageHTTP.downloadFile(for: req, to: destination, maximumBytes: ref.size)
            try checkStickerContext(expectedSessionId, expectedSessionRevision, current)
            guard let response = raw as? HTTPURLResponse, response.url == req.url else { throw CFLFailure.protocolError }
            guard (200...299).contains(response.statusCode) else {
                throw response.statusCode == 401 || response.statusCode == 403 ? CFLFailure.accessDenied : CFLFailure.requestFailed
            }
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == ref.size else { throw CFLFailure.protocolError }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    /// Loads only an authenticated media ID from the currently connected origin.
    /// If a preview is absent, falls back to the bounded original; an absent
    /// original remains a failure. Discard results when the page disappears.
    public func media(_ ref: CFLImageRef, original: Bool = false,
                      expectedSessionId: String? = nil, expectedSessionRevision: Int? = nil, revalidate: Bool = false) async throws -> Data {
        guard ref.valid, ref.availability == "available" else { throw CFLFailure.invalidInput }
        guard active, !disconnecting, let session = state.sessionId else { throw CFLFailure.offline }
        guard expectedSessionId.map({ $0 == session }) ?? true,
              expectedSessionRevision.map({ $0 == sessionRevision }) ?? true else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        let current = generation, revision = sessionRevision
        let key = cacheKey("chat-media", session: session, parts: [ref.attachmentId, original ? "original" : "preview"])
        if !revalidate, let cached = try await cacheRead(key, session: session, revision: revision, current: current) {
            if cached.count <= 32 * 1024 * 1024, Self.supportedImageBytes(cached) {
                if state.connection == .online {
                    Task { [weak self] in _ = try? await self?.media(ref, original: original, expectedSessionId: session, expectedSessionRevision: revision, revalidate: true) }
                }
                return cached
            }
            await cacheRemove(key)
        }
        guard state.connection == .online else { throw CFLFailure.offline }
        let version = UUID(); cacheVersions[key] = version
        defer { if cacheVersions[key] == version { cacheVersions.removeValue(forKey: key) } }
        let scope = await cacheAuthority()
        func checkCurrent() throws {
            guard !Task.isCancelled, active, generation == current, sessionRevision == revision, state.sessionId == session,
                  state.connection == .online else { throw CFLFailure.sessionChanged }
        }
        let request = try request(path: "/api/chat/media/\(ref.attachmentId)/\(original ? "original" : "preview")", method: "GET")
        var (data, response) = try await imageResponse(request, allowNotFound: true)
        try checkCurrent()
        var readOriginal = original
        if response.statusCode == 404 && !original {
            let fallback = try self.request(path: "/api/chat/media/\(ref.attachmentId)/original", method: "GET")
            (data, response) = try await imageResponse(fallback, allowNotFound: true)
            readOriginal = true
            try checkCurrent()
        }
        if response.statusCode == 404 { await cacheRemove(key); throw CFLFailure.requestFailed }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        guard data.count <= (readOriginal ? 32 * 1024 * 1024 : 160_000), !data.isEmpty,
              let type, CFLImageLimits.types.contains(type), readOriginal || type == "image/jpeg" else { throw CFLFailure.protocolError }
        if let scope, await cacheAuthority() != scope { throw CFLFailure.sessionChanged }
        await cacheWrite(data, key: key, session: session, revision: revision, current: current, version: version)
        try checkCurrent()
        if let scope, await cacheAuthority() != scope { throw CFLFailure.sessionChanged }
        return data
    }
    /// Returns the locally durable operation ID, not an admission or reply receipt.
    /// After this returns, inspect pending state even if the connection was lost.
    /// CFLPendingStorageUncertain identifies an undispatched input whose first save
    /// could not be verified; preserve it until the store can be read again.
    @discardableResult public func send(_ text: String, images: [CFLPreparedImage] = [], files: [CFLPreparedFile] = [],
                                        expectedSessionId: String? = nil, expectedSessionRevision: Int? = nil) async throws -> String {
        let result = try await sendCore(text, images: images, files: files, sticker: nil, operation: UUID().uuidString.lowercased(), expectedSessionId: expectedSessionId, expectedSessionRevision: expectedSessionRevision)
        return result.operationId
    }
    /// Supply a freshly generated UUID for one local operation and never reuse it.
    /// Throws before submit on validation/upload failure, or CFLPendingStorageUncertain
    /// when the first save cannot be read back. Retain the original input in either case.
    @discardableResult public func send(_ text: String, images: [CFLPreparedImage] = [], files: [CFLPreparedFile] = [], operationId: String,
                                        expectedSessionId: String, expectedSessionRevision: Int) async throws -> CFLSendOutcome {
        let result = try await sendCore(text, images: images, files: files, sticker: nil, operation: operationId, expectedSessionId: expectedSessionId, expectedSessionRevision: expectedSessionRevision)
        return result.outcome
    }
    /// Sends a sticker independently of the composer's text and image drafts.
    @discardableResult public func sendSticker(_ sticker: CFLSticker, expectedSessionId: String, expectedSessionRevision: Int) async throws -> String {
        guard sticker.valid, sticker.available else { throw CFLFailure.invalidInput }
        let result = try await sendCore("", images: [], files: [], sticker: sticker, operation: UUID().uuidString.lowercased(), expectedSessionId: expectedSessionId, expectedSessionRevision: expectedSessionRevision)
        return result.operationId
    }
    private func sendCore(_ text: String, images: [CFLPreparedImage], files: [CFLPreparedFile], sticker: CFLSticker?,
                          operation: String, expectedSessionId: String?, expectedSessionRevision: Int?) async throws -> (operationId: String, outcome: CFLSendOutcome) {
        guard let operationUUID = UUID(uuidString: operation) else { throw CFLFailure.invalidInput }
        guard !usedSendOperations.contains(operationUUID) else { throw CFLSendFailure.duplicateOperationId }
        guard !sending else { throw CFLFailure.requestFailed }
        sending = true
        defer { sending = false }
        let current = generation
        try await load()
        guard active, !disconnecting, generation == current, state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        let revision = sessionRevision
        guard expectedSessionId.map({ $0 == session }) ?? true,
              expectedSessionRevision.map({ $0 == revision }) ?? true else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !images.isEmpty || !files.isEmpty || sticker != nil), trimmed != "/compact", text.utf16.count <= 16000 else { throw CFLFailure.invalidInput }
        guard !entries.contains(where: { UUID(uuidString: $0.operationId) == operationUUID || $0.retrySource.flatMap { UUID(uuidString: $0) } == operationUUID }),
              !state.messages.contains(where: { $0.operationId.flatMap { UUID(uuidString: $0) } == operationUUID }) else {
            throw CFLSendFailure.duplicateOperationId
        }
        usedSendOperations.insert(operationUUID)
        var beganPersistence = false
        defer {
            if !beganPersistence {
                let count = state.localPreviews.count
                state.localPreviews.removeAll { $0.sessionId == session && $0.operationId == operation }
                if count != state.localPreviews.count { publish() }
            }
            if state.localDrafts.contains(where: { $0.operationId == operation && $0.sessionId == session }) {
                state.localDrafts.removeAll { $0.operationId == operation && $0.sessionId == session }; publish()
            }
        }
        let fileLimits = state.fileLimits, imageLimits = state.imageLimits
        if !files.isEmpty {
            guard let fileLimits else { throw CFLFailure.invalidInput }
            try validate(files, limits: fileLimits)
        }
        guard active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == session else { throw CFLFailure.sessionChanged }
        if !images.isEmpty {
            guard let limits = state.imageLimits else { throw CFLFailure.invalidInput }
            try validate(images, limits: limits)
        }
        var refs: [CFLImageRef]?
        if !images.isEmpty {
            guard let limits = state.imageLimits else { throw CFLFailure.invalidInput }
            try validate(images, limits: limits)
            let previews = images.enumerated().map { index, image in
                CFLLocalImagePreview(sessionId: session, operationId: operation, originOperationId: operation, draftId: image.id, order: index, attachmentId: nil, data: image.preview)
            }
            state.localDrafts.append(CFLLocalDraft(sessionId: session, operationId: operation, text: text, images: previews)); publish()
            refs = try await upload(images, session: session, operation: operation)
            guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
                  state.connection == .online, state.sessionId == session, state.imageLimits == limits else { throw CFLFailure.sessionChanged }
            state.localPreviews.append(contentsOf: zip(previews, refs!).map { preview, ref in
                CFLLocalImagePreview(sessionId: session, operationId: operation, originOperationId: preview.originOperationId, draftId: preview.draftId, order: preview.order, attachmentId: ref.attachmentId, data: preview.data)
            })
        }
        if let sticker {
            refs = [try await stageSticker(sticker, session: session, operation: operation)]
            guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
                  state.connection == .online, state.sessionId == session else { throw CFLFailure.sessionChanged }
        }
        var fileRefs: [CFLFileRef]?
        if !files.isEmpty {
            guard state.fileLimits == fileLimits, state.sessionId == session, sessionRevision == revision else { throw CFLFailure.sessionChanged }
            fileRefs = try await uploadFileOperation(files, session: session, operation: operation, generation: current, revision: revision)
            guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
                  state.connection == .online, state.sessionId == session, state.fileLimits == fileLimits,
                  (images.isEmpty || state.imageLimits == imageLimits) else { throw CFLFailure.sessionChanged }
        }
        guard active, !disconnecting, generation == current, sessionRevision == revision, state.connection == .online, state.sessionId == session else { throw CFLFailure.sessionChanged }
        var entry = CFLPending(target: target, sessionId: session, operationId: operation, text: text, createdAt: Date(), dispatched: false, status: .unknown, images: refs, files: fileRefs)
        do { try await persist(entries + [entry]); beganPersistence = true }
        catch {
            guard loaded else { beganPersistence = true; throw CFLPendingStorageUncertain(pending: entry) }
            if entries.contains(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) {
                beganPersistence = true
                return (entry.operationId, .notDispatched)
            }
            throw error
        }
        if !images.isEmpty { state.localDrafts.removeAll { $0.operationId == operation && $0.sessionId == session }; publish() }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.connection == .online, state.sessionId == session else {
            if active && !disconnecting && generation == current && sessionRevision == revision && state.sessionId == session { setError(.sessionChanged); publish() }
            return (entry.operationId, .notDispatched)
        }
        entry.dispatched = true
        guard let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) else {
            setError(.storage); publish(); return (entry.operationId, .notDispatched)
        }
        var next = entries; next[index] = entry
        do { try await persist(next) }
        catch {
            if !loaded, let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) {
                // The dispatched marker may have committed; do not offer dismissal
                // until the store can be read again.
                entries[index].dispatched = true; showPending(); publish()
            }
            return (entry.operationId, .notDispatched)
        }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.connection == .online, state.sessionId == session else {
            if active && !disconnecting && generation == current && sessionRevision == revision && state.sessionId == session { setError(.sessionChanged); publish() }
            return (entry.operationId, .notDispatched)
        }
        submitting.insert(entry.operationId)
        scheduleDeadline()
        let previousError = errorRevision
        var outcome: CFLSendOutcome = .unknown
        do {
            let value = try await call(method: "submit", args: [submission(entry)])
            guard value != .null else { throw CFLFailure.protocolError }
            guard active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == session else { throw CFLFailure.sessionChanged }
            try await accept(value, entry: entry)
            if let latest = entries.first(where: { $0.target == target && $0.sessionId == session && $0.operationId == operation }) {
                if latest.status == .submitted { outcome = .submitted }
                else if latest.status == .failed { outcome = .failed }
            } else if state.sessionId == session && state.messages.contains(where: { $0.role == "user" && $0.operationId == operation }) {
                outcome = .submitted
            }
            clearError(since: previousError)
        } catch {
            if active && !disconnecting && generation == current && sessionRevision == revision && state.sessionId == session {
                setError((error as? CFLFailure) ?? .requestFailed); publish()
            }
        }
        submitting.remove(entry.operationId)
        requestReconcile()
        return (entry.operationId, outcome)
    }
    private func submission(_ pending: CFLPending) -> ChordJSON {
        var fields: [String: ChordJSON] = ["operationId": .string(pending.operationId), "text": .string(pending.text)]
        if let images = pending.images, !images.isEmpty {
            fields["images"] = .array(images.map { image in
                var value: [String: ChordJSON] = ["attachmentId": .string(image.attachmentId), "name": .string(image.name), "mediaType": .string(image.mediaType), "availability": .string(image.availability)]
                if let sticker = image.sticker { value["sticker"] = .object(["id": .string(sticker.id), "version": .string(sticker.version)]) }
                return .object(value)
            })
        }
        if let files = pending.files, !files.isEmpty {
            fields["files"] = .array(files.map { file in .object([
                "attachmentId": .string(file.attachmentId), "name": .string(file.name), "mediaType": .string(file.mediaType),
                "size": .number(Double(file.size)), "availability": .string(file.availability)]) })
        }
        return .object(fields)
    }
    /// Release previews after the caller no longer displays this operation.
    @discardableResult public func releasePreviews(sessionId: String, operationId: String) -> Bool {
        guard state.sessionId == sessionId,
              !entries.contains(where: { $0.target == target && $0.sessionId == sessionId && ($0.operationId == operationId || $0.retrySource == operationId) }),
              !state.localDrafts.contains(where: { $0.sessionId == sessionId && $0.operationId == operationId }) else { return false }
        let count = state.localPreviews.count
        state.localPreviews.removeAll { $0.sessionId == sessionId && $0.operationId == operationId }
        if count != state.localPreviews.count { publish(); return true }
        return false
    }
    /// Retry only a definitely failed, previously dispatched operation.
    /// The new attempt is saved before dispatch; an unknown outcome is only looked up.
    @discardableResult public func retryFailed(sessionId: String, operationId: String, expectedSessionRevision: Int) async throws -> String {
        guard !sending else { throw CFLFailure.requestFailed }
        sending = true; defer { sending = false }
        let current = generation
        try await load()
        guard active, !disconnecting, generation == current, state.connection == .online, state.sessionId == sessionId,
              sessionRevision == expectedSessionRevision else { throw CFLFailure.sessionChanged }
        let revision = sessionRevision
        try Task.checkCancellation()
        guard let sourceUUID = UUID(uuidString: operationId) else { throw CFLFailure.invalidInput }
        guard let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == operationId && $0.status == .failed && $0.dispatched }) else { throw CFLFailure.invalidInput }
        let original = entries[index], attempt = UUID().uuidString.lowercased()
        guard active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == sessionId,
              let sourceIndex = entries.firstIndex(of: original) else { throw CFLFailure.sessionChanged }
        usedSendOperations.insert(sourceUUID)
        usedSendOperations.insert(UUID(uuidString: attempt)!)
        var entry = CFLPending(target: target, sessionId: sessionId, operationId: attempt, text: original.text, createdAt: Date(), dispatched: false, status: .unknown, images: original.images, retrySource: operationId, files: original.files)
        var next = entries; next[sourceIndex] = entry
        do { try await persist(next) }
        catch {
            guard loaded else { throw CFLPendingStorageUncertain(pending: entry) }
            if entries.contains(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == attempt }) { return attempt }
            throw error
        }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == sessionId, state.connection == .online else { return attempt }
        guard let attemptIndex = entries.firstIndex(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == attempt }) else { throw CFLFailure.storage }
        entry.dispatched = true; next = entries; next[attemptIndex] = entry
        do { try await persist(next) } catch { return attempt }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == sessionId, state.connection == .online else { return attempt }
        submitting.insert(attempt); scheduleDeadline()
        let retry: ChordJSON = .object(["sessionId": .string(sessionId), "operationId": .string(operationId), "attemptId": .string(attempt)])
        do {
            let value = try await call(method: "retryFailed", args: [retry])
            guard active, !disconnecting, generation == current, sessionRevision == revision, state.sessionId == sessionId else { throw CFLFailure.sessionChanged }
            try await accept(value, entry: entry)
        } catch {
            if active && !disconnecting && generation == current && sessionRevision == revision && state.sessionId == sessionId {
                setError((error as? CFLFailure) ?? .requestFailed); publish()
            }
        }
        submitting.remove(attempt); requestReconcile()
        return attempt
    }
    private func accept(_ value: ChordJSON, entry: CFLPending) async throws {
        guard value != .null else { return }
        guard let fields = value.object, Set(fields.keys).subtracting(["retryImages", "retryFiles"]) == Set(["operationId", "state", "messageId", "turnId", "error"]) else { throw CFLFailure.protocolError }
        let receipt: CFLReceipt = try decode(CFLReceipt.self, value)
        guard receipt.operationId == entry.operationId, let status = CFLPendingStatus(rawValue: receipt.state), status != .unknown else { throw CFLFailure.protocolError }
        guard let index = entries.firstIndex(where: { $0.target == entry.target && $0.sessionId == entry.sessionId && $0.operationId == entry.operationId }) else { return }
        if entries[index].status == .submitted { requestRetirement(); return }
        guard state.sessionId == entry.sessionId else { throw CFLFailure.sessionChanged }
        var next = entries
        let acceptGeneration = generation, acceptRevision = sessionRevision
        var previewMapping: (source: String, refs: [String: CFLImageRef])?
        if let source = entries[index].retrySource, let originals = entries[index].images, !originals.isEmpty {
            guard let raw = fields["retryImages"]?.object, Set(raw.keys) == Set(["sessionId", "sourceOperationId", "images"]),
                  let rawImages = raw["images"]?.array, rawImages.allSatisfy({ item in
                      guard let fields = item.object, Set(fields.keys) == Set(["sourceAttachmentId", "ref"]), let ref = fields["ref"] else { return false }
                      return validImageWire(ref)
                  }),
                  let mapping = receipt.retryImages, mapping.sessionId == entry.sessionId, mapping.sourceOperationId == source,
                  mapping.images.count == originals.count, Set(originals.map(\.attachmentId)).count == originals.count,
                  Set(mapping.images.map(\.sourceAttachmentId)) == Set(originals.map(\.attachmentId)),
                  Set(mapping.images.map(\.ref.attachmentId)).count == originals.count,
                  mapping.images.allSatisfy({ $0.ref.valid && $0.ref.availability == "available" }) else { throw CFLFailure.protocolError }
            let refs = Dictionary(uniqueKeysWithValues: mapping.images.map { ($0.sourceAttachmentId, $0.ref) })
            guard originals.allSatisfy({ original in refs[original.attachmentId].map { $0.name == original.name && $0.mediaType == original.mediaType && $0.sticker == original.sticker } ?? false }) else { throw CFLFailure.protocolError }
            let previews = state.localPreviews.filter { $0.sessionId == entry.sessionId && $0.operationId == source }
            guard previews.isEmpty || (previews.count == originals.count && Set(previews.compactMap(\.attachmentId)) == Set(originals.map(\.attachmentId))) else { throw CFLFailure.protocolError }
            previewMapping = (source: source, refs: refs)
            next[index].images = originals.map { refs[$0.attachmentId]! }
        } else if fields["retryImages"] != nil { throw CFLFailure.protocolError }
        if let source = entries[index].retrySource, let originals = entries[index].files, !originals.isEmpty {
            guard let raw = fields["retryFiles"]?.object, Set(raw.keys) == Set(["sessionId", "sourceOperationId", "files"]),
                  let rawFiles = raw["files"]?.array, rawFiles.allSatisfy({ item in
                      guard let fields = item.object, Set(fields.keys) == Set(["sourceAttachmentId", "ref"]), let ref = fields["ref"] else { return false }
                      return validFileWire(ref)
                  }), let mapping = receipt.retryFiles, mapping.sessionId == entry.sessionId, mapping.sourceOperationId == source,
                  mapping.files.count == originals.count, Set(originals.map(\.attachmentId)).count == originals.count,
                  Set(mapping.files.map(\.sourceAttachmentId)) == Set(originals.map(\.attachmentId)),
                  Set(mapping.files.map { $0.ref.attachmentId }).count == originals.count,
                  mapping.files.allSatisfy({ $0.ref.valid && $0.ref.availability == "available" }) else { throw CFLFailure.protocolError }
            let refs = Dictionary(uniqueKeysWithValues: mapping.files.map { ($0.sourceAttachmentId, $0.ref) })
            guard originals.allSatisfy({ original in refs[original.attachmentId].map {
                $0.name.utf8.elementsEqual(original.name.utf8) && $0.mediaType.utf8.elementsEqual(original.mediaType.utf8) && $0.size == original.size
            } ?? false }) else { throw CFLFailure.protocolError }
            next[index].files = originals.map { refs[$0.attachmentId]! }
        } else if fields["retryFiles"] != nil { throw CFLFailure.protocolError }
        next[index].retrySource = nil; next[index].status = status
        try await persist(next)
        // Persistence yields the actor; a session change or newer preview update may
        // have happened. Apply only this mapping to the current previews afterward.
        if let mapping = previewMapping, active, !disconnecting, generation == acceptGeneration,
           sessionRevision == acceptRevision, state.sessionId == entry.sessionId {
            state.localPreviews = state.localPreviews.map { preview in
                guard preview.sessionId == entry.sessionId, preview.operationId == mapping.source,
                      let old = preview.attachmentId, let ref = mapping.refs[old] else { return preview }
                return CFLLocalImagePreview(sessionId: preview.sessionId, operationId: entry.operationId,
                    originOperationId: preview.originOperationId, draftId: preview.draftId, order: preview.order,
                    attachmentId: ref.attachmentId, data: preview.data)
            }
            publish()
        }
        if status == .submitted { requestRetirement() }
    }
    public func reconcile() async throws {
        let previousError = errorRevision, current = generation, revision = sessionRevision
        try await load()
        guard active, !disconnecting, generation == current else { throw CFLFailure.offline }
        finalized = finalized.filter { checks.contains($0) }
        try await reconcilePending()
        if current == generation && revision == sessionRevision && checks.isEmpty && submitting.isEmpty {
            clearError(since: previousError)
        }
    }
    private func reconcilePending() async throws {
        guard loaded else { throw CFLFailure.storage }
        guard state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        let current = generation, revision = sessionRevision
        let pending = entries.filter { $0.target == target && $0.sessionId == session && $0.status == .unknown && $0.dispatched }
        var firstError: Error?
        for entry in pending {
            guard state.connection == .online, generation == current, sessionRevision == revision, state.sessionId == session else { break }
            guard entries.contains(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId && $0.status == .unknown && $0.dispatched }) else { continue }
            let key = CheckKey(generation: current, sessionRevision: revision, session: session, operation: entry.operationId)
            let expired = Date().timeIntervalSince(entry.createdAt) >= 60
            if checks.contains(key) || (expired && finalized.contains(key)) || (!expired && submitting.contains(entry.operationId)) { continue }
            checks.insert(key)
            if expired { finalized.insert(key) }
            scheduleDeadline()
            do {
                guard generation == current, sessionRevision == revision, state.sessionId == session else { throw CFLFailure.sessionChanged }
                let finalization: ChordJSON
                if let source = entry.retrySource {
                    finalization = .object(["sessionId": .string(session), "retry": .object(["sessionId": .string(session), "operationId": .string(source), "attemptId": .string(entry.operationId)])])
                } else { finalization = .object(["sessionId": .string(session), "submission": submission(entry)]) }
                let value = try await call(method: expired ? "finalizeSubmission" : "lookup", args: [expired ? finalization : .string(entry.operationId)])
                if generation == current && sessionRevision == revision && state.sessionId == session {
                    try await accept(value, entry: entry)
                }
            } catch { if firstError == nil { firstError = error } }
            checks.remove(key)
            scheduleDeadline()
        }
        scheduleDeadline()
        if let firstError { throw firstError }
    }
    private func requestReconcile(publication: Bool = false) {
        guard loaded, state.connection == .online, let session = state.sessionId else { return }
        if publication {
            finalized = finalized.filter { checks.contains($0) }
        }
        deadlineTask?.cancel(); deadlineTask = nil
        let current = generation, revision = sessionRevision
        Task { [weak self] in
            guard let self else { return }
            await self.reconcileIfCurrent(generation: current, revision: revision, session: session)
        }
    }
    private func reconcileIfCurrent(generation current: Int, revision: Int, session: String) async {
        guard generation == current, sessionRevision == revision, state.sessionId == session else { return }
        try? await reconcilePending()
    }
    private func scheduleDeadline() {
        deadlineTask?.cancel(); deadlineTask = nil
        guard loaded, state.connection == .online, let session = state.sessionId else { return }
        let current = generation, revision = sessionRevision
        let candidates = entries.filter { entry in
            let key = CheckKey(generation: current, sessionRevision: revision, session: session, operation: entry.operationId)
            return entry.target == target && entry.sessionId == session && entry.status == .unknown && entry.dispatched && !checks.contains(key) && !finalized.contains(key)
        }
        guard let due = candidates.map({ $0.createdAt.addingTimeInterval(60) }).min() else { return }
        let delay = max(0, due.timeIntervalSinceNow)
        deadlineTask = Task { [weak self] in
            let bounded = min(delay, Double(UInt64.max / 1_000_000_000))
            do { try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000)) } catch { return }
            await self?.deadlineFired(generation: current, revision: revision, session: session)
        }
    }
    private func deadlineFired(generation current: Int, revision: Int, session: String) {
        guard generation == current, sessionRevision == revision, state.sessionId == session, state.connection == .online else { return }
        deadlineTask = nil
        requestReconcile()
    }
    public func stop(turnId: String) async throws -> Bool {
        guard state.connection == .online else { throw CFLFailure.offline }
        guard state.activeTurnId == turnId else { return false }
        let value = try await call(method: "stop", args: [.string(turnId)])
        guard let result = value.object, case .bool(let stopped) = result["stopped"] else { throw CFLFailure.protocolError }
        return stopped
    }
    /// Unknown submissions may only be dismissed if definitely undispatched.
    public func dismissPending(sessionId: String, operationId: String) async throws {
        let current = generation
        try await load()
        guard active, !disconnecting, generation == current else { throw CFLFailure.offline }
        guard let item = entries.first(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == operationId }),
              item.status != .unknown || !item.dispatched else { return }
        try await persist(entries.filter { !($0.target == target && $0.sessionId == sessionId && $0.operationId == operationId) })
    }
}
