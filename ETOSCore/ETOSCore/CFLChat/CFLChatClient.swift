import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single active CFL session. State and pending records retain server string identities.
public actor CFLChatClient {
    public typealias TransportFactory = @Sendable () async throws -> any CFLChatTransport
    private let target: String
    private let store: any CFLPendingStore
    private let transportFactory: TransportFactory
    private let imageHTTP: any CFLImageHTTP
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
    private var historyDirty = false
    private var historyErrorRevision: Int?
    private var historyTask: Task<Void, Never>?
    private var historyTaskID: UUID?
    private var historyPatches: [String: CFLMessage] = [:]
    private var historyPatchBytes = 0
    private var queuedTimeline: [ChordJSON] = []
    private var queuedTimelineBytes = 0
    private var queuedTimelineReset = false
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
    private var olderMessages: [CFLMessage] = []
    private var latestMessages: [CFLMessage] = []
    private var latestBefore: String?

    /// target is a stable, credential-free identifier for the connection; use one active client per store.
    public init(target: String, store: any CFLPendingStore, imageHTTP: any CFLImageHTTP = CFLImageURLSession.shared, transport: @escaping TransportFactory) {
        self.target = target; self.store = store; self.imageHTTP = imageHTTP; self.transportFactory = transport
    }
    init(target: String, store: any CFLPendingStore, requestTimeout: @escaping @Sendable (String) async throws -> Void, transport: @escaping TransportFactory) {
        self.target = target; self.store = store; self.imageHTTP = CFLImageURLSession.shared; self.transportFactory = transport; self.requestTimeout = requestTimeout
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
    private func publish() { for observer in observers.values { observer.yield(state) } }
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
        transport = socket; chord = ChordState(); subscribed = false; queuedUpdates = []; queuedTimeline = []; queuedTimelineBytes = 0; queuedTimelineReset = false
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, generation: current) }
        let snapshot = try await call(service: "$chord.service", method: "subscribe", args: [.string("view"), .string("lamplit.chat.v2"), .string("singleton")])
        guard generation == current else { throw CFLFailure.offline }
        try chord.hydrate(snapshot)
        subscribed = true
        for update in queuedUpdates {
            try chord.update(update)
            if update.object?["type"]?.string == "reset" { queuedTimelineReset = true }
        }
        queuedUpdates.removeAll()
        try applyView()
        state.connection = .online; publish()
        if state.historySyncFailed {
            state.historySyncFailed = false
            if let revision = historyErrorRevision { clearError(since: revision, only: .requestFailed) }
            historyErrorRevision = nil
            publish()
        }
        if queuedTimelineReset { requestHistorySync() }
        for event in queuedTimeline { try applyTimeline(event) }
        queuedTimeline = []; queuedTimelineBytes = 0; queuedTimelineReset = false
        requestHistorySync()
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
                        try chord.update(update); try applyView()
                        if update.object?["type"]?.string == "reset" {
                            historyPatches.removeAll(); historyPatchBytes = 0
                            requestHistorySync()
                        }
                        requestReconcile(publication: true)
                    }
                    else { guard queuedUpdates.count < 100 else { throw CFLFailure.protocolError }; queuedUpdates.append(update) }
                } else if type == "timeline" {
                    if subscribed { try applyTimeline(.object(frame)) }
                    else {
                        if queuedTimeline.count >= 100 || queuedTimelineBytes + data.count > 1_048_576 {
                            queuedTimeline = []; queuedTimelineBytes = 0; queuedTimelineReset = true
                        } else if !queuedTimelineReset { queuedTimeline.append(.object(frame)); queuedTimelineBytes += data.count }
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
        historyTask?.cancel(); historyTask = nil; historyTaskID = nil; historyPatches.removeAll(); historyPatchBytes = 0
        historyLoading = false; historyLoadingID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        checks.removeAll(); finalized.removeAll()
        let old = transport; transport = nil
        for continuation in calls.values { continuation.resume(throwing: CFLFailure.offline) }; calls.removeAll()
        for timer in timeouts.values { timer.cancel() }; timeouts.removeAll()
        subscribed = false; chord = ChordState(); queuedUpdates = []; queuedTimeline = []; queuedTimelineBytes = 0; queuedTimelineReset = false
        let failure: CFLFailure?
        if let authorization = error as? CFLAuthorizationError {
            switch authorization {
            case .authorizationRequired: failure = .accessDenied
            case .storage: failure = .storage
            default: failure = .offline
            }
        } else { failure = error as? CFLFailure }
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
    private func validMessageWire(_ raw: ChordJSON) -> Bool {
        guard let fields = raw.object,
              Set(fields.keys).isSubset(of: Set(["id", "role", "text", "createdAt", "operationId", "turnId", "images", "imageState", "textState", "voice", "source", "thinking"])),
              let id = fields["id"]?.string, !id.isEmpty, id.utf16.count <= 300,
              fields["role"]?.string != nil, fields["text"]?.string != nil,
              fields["operationId"] == .null || fields["operationId"]?.string != nil,
              fields["turnId"] == .null || fields["turnId"]?.string != nil else { return false }
        if let images = fields["images"] { guard let items = images.array, items.allSatisfy(validImageWire) else { return false } }
        if let imageState = fields["imageState"] { guard let value = imageState.string, CFLImageState(rawValue: value) != nil else { return false } }
        if let textState = fields["textState"] { guard let value = textState.string, CFLTextState(rawValue: value) != nil else { return false } }
        if let voice = fields["voice"] { guard let value = voice.object, Set(value.keys) == Set(["id"]), let id = value["id"]?.string, CFLVoiceRef(id: id).valid else { return false } }
        if let thinking = fields["thinking"], thinking.string == nil { return false }
        return true
    }
    private func applyView() throws {
        guard let value = chord.value, let fields = value.object,
              fields["activeTurnId"] != nil, fields["before"] != nil,
              let capabilities = fields["capabilities"]?.object,
              capabilities["text"] == .bool(true), capabilities["stop"] == .bool(true),
              fields["contextUsage"] != nil, fields["compaction"] != nil, fields["recovery"]?.array != nil else { throw CFLFailure.protocolError }
        let view = try decode(CFLView.self, value)
        guard view.version == 2, !view.sessionId.isEmpty, view.messages.count <= 30,
              let rawMessages = fields["messages"]?.array, rawMessages.allSatisfy(validMessageWire),
              Set(view.messages.map(\.id)).count == view.messages.count,
              view.messages.allSatisfy(\.valid) else { throw CFLFailure.protocolError }
        var imageLimits: CFLImageLimits?
        if let images = capabilities["images"], images != .bool(false) {
            let limits = try decode(CFLImageLimits.self, images)
            guard limits.valid else { throw CFLFailure.protocolError }
            imageLimits = limits
        }
        let changedSession = state.sessionId != view.sessionId
        if changedSession {
            sessionRevision += 1
            state.sessionRevision = sessionRevision
            historyTask?.cancel(); historyTask = nil; historyTaskID = nil
            historyLoading = false; historyLoadingID = nil
            deadlineTask?.cancel(); deadlineTask = nil
            checks.removeAll(); finalized.removeAll()
            historyDirty = false; historyPatches.removeAll(); historyPatchBytes = 0; state.historySyncFailed = false; historyErrorRevision = nil
            state.localDrafts.removeAll(); state.localPreviews.removeAll()
        }
        let latest = Set(view.messages.map(\.id))
        // Preserve a same-session window while paging back to prove continuity.
        let hasHistory = historyLoaded || !olderMessages.isEmpty || !latestMessages.isEmpty
        let overlaps = (olderMessages + latestMessages).contains { latest.contains($0.id) }
        // An empty projection has no IDs to establish continuity. Compare the
        // server's anchor, not the independently advanced history cursor.
        let emptyAnchorChanged = latestMessages.isEmpty && view.messages.isEmpty && latestBefore != view.before
        let lostContinuity = (hasHistory && !overlaps && (!view.messages.isEmpty || !latestMessages.isEmpty)) || emptyAnchorChanged
        if changedSession || (lostContinuity && !historyLoaded && olderMessages.isEmpty && latestMessages.isEmpty) {
            historyRevision += 1
            historyLoaded = false
            olderMessages = []; latestMessages = []; state.before = view.before
        } else if lostContinuity {
            historyRevision += 1
            historyDirty = true
        }
        var seen = Set<String>()
        olderMessages = (olderMessages + latestMessages.filter { !latest.contains($0.id) }).filter { !latest.contains($0.id) && seen.insert($0.id).inserted }
        latestMessages = view.messages
        latestBefore = view.before
        if olderMessages.isEmpty && !historyLoaded { state.before = view.before }
        state.messages = olderMessages + view.messages
        state.sessionId = view.sessionId; state.name = view.name; state.activeTurnId = view.activeTurnId; state.streamingReply = view.streamingReply; state.replyCompletedTurnId = view.replyCompletedTurnId
        state.imageLimits = imageLimits
        showPending(); publish(); requestRetirement()
        if historyDirty { requestHistorySync() }
    }
    private func applyTimeline(_ value: ChordJSON) throws {
        guard let frame = value.object, Set(frame.keys) == Set(["type", "sessionId", "change"]),
              frame["type"]?.string == "timeline", let session = frame["sessionId"]?.string, !session.isEmpty,
              let change = frame["change"]?.object, let type = change["type"]?.string else { throw CFLFailure.protocolError }
        guard session == state.sessionId else { return }
        if type == "structure" {
            guard Set(change.keys) == Set(["type"]) else { throw CFLFailure.protocolError }
            // The next history scan supersedes older deltas; retain later items.
            historyPatches.removeAll(); historyPatchBytes = 0
            requestHistorySync(); return
        }
        guard type == "item", Set(change.keys) == Set(["type", "message"]), let raw = change["message"] else { throw CFLFailure.protocolError }
        let message = try decode(CFLMessage.self, raw)
        guard validMessageWire(raw), message.valid else { throw CFLFailure.protocolError }
        if historyTask != nil || historyLoading {
            let size = try JSONEncoder().encode(raw).count
            if historyPatches.count >= 100 || historyPatchBytes + size > 1_048_576 {
                historyPatches.removeAll(); historyPatchBytes = 0; historyDirty = true
            } else { historyPatches[message.id] = message; historyPatchBytes += size }
        }
        var changed = false
        if let index = olderMessages.firstIndex(where: { $0.id == message.id }) { olderMessages[index] = message; changed = true }
        if let index = latestMessages.firstIndex(where: { $0.id == message.id }) { latestMessages[index] = message; changed = true }
        if changed { state.messages = olderMessages + latestMessages; publish() }
    }
    private func requestHistorySync() {
        guard historyLoaded || !olderMessages.isEmpty || historyLoading else { return }
        historyDirty = true
        guard active, !disconnecting, state.connection == .online, !historyLoading, historyTask == nil,
              !state.historySyncFailed, let session = state.sessionId else { return }
        let id = UUID(), current = generation, revision = sessionRevision
        historyTaskID = id
        historyTask = Task { [weak self] in await self?.syncHistory(id: id, generation: current, sessionRevision: revision, session: session) }
    }
    private func syncHistory(id: UUID, generation current: Int, sessionRevision version: Int, session: String) async {
        defer {
            if historyTaskID == id {
                historyTask = nil; historyTaskID = nil
                if historyDirty && !state.historySyncFailed { requestHistorySync() }
            }
        }
        while historyDirty && active && !disconnecting && generation == current && sessionRevision == version && state.sessionId == session {
            historyDirty = false
            let revision = historyRevision, boundary = olderMessages.first?.id, throughEnd = state.before == nil
            let startCursor = latestBefore, liveIDs = latestMessages.map(\.id)
            let knownCursor = state.before
            var cursor = startCursor, nextBefore = cursor
            var found = boundary == nil && knownCursor == startCursor
            var visited = Set<String>(), collected: [CFLMessage] = []
            do {
                while let currentCursor = cursor, throughEnd || !found {
                    guard visited.insert(currentCursor).inserted else { throw CFLFailure.protocolError }
                    let raw = try await call(method: "history", args: [.string(currentCursor)])
                    guard raw.object?["before"] != nil else { throw CFLFailure.protocolError }
                    let page = try decode(CFLPage.self, raw)
                    guard page.messages.count <= 30, raw.object?["messages"]?.array?.allSatisfy(validMessageWire) == true, page.messages.allSatisfy(\.valid),
                          Set(page.messages.map(\.id)).count == page.messages.count else { throw CFLFailure.protocolError }
                    guard active, !disconnecting, generation == current, sessionRevision == version, state.sessionId == session else { return }
                    if historyRevision != revision { historyDirty = true; break }
                    collected = page.messages + collected; nextBefore = page.before
                    if let boundary, page.messages.contains(where: { $0.id == boundary }) { found = true }
                    if boundary == nil && page.before == knownCursor { found = true }
                    cursor = page.before
                    if !throughEnd && found { break }
                }
                guard active, !disconnecting, generation == current, sessionRevision == version, state.sessionId == session else { return }
                if historyRevision != revision || latestBefore != startCursor || latestMessages.map(\.id) != liveIDs { historyDirty = true }
                if historyDirty { continue }
                if !found && !(boundary.map { id in latestMessages.contains(where: { $0.id == id }) } ?? false) { throw CFLFailure.protocolError }
                let latest = Set(latestMessages.map(\.id)); var seen = Set<String>()
                olderMessages = collected.compactMap { message in
                    guard !latest.contains(message.id), seen.insert(message.id).inserted else { return nil }
                    return historyPatches[message.id] ?? message
                }
                historyPatches.removeAll(); historyPatchBytes = 0
                state.before = nextBefore; state.messages = olderMessages + latestMessages
                state.historySyncFailed = false; publish(); requestRetirement()
            } catch {
                guard active, !disconnecting, generation == current, sessionRevision == version, state.sessionId == session else { return }
                historyDirty = true; state.historySyncFailed = true; setError(.requestFailed); historyErrorRevision = errorRevision; publish(); return
            }
        }
    }
    public func retryHistory() {
        state.historySyncFailed = false
        if let revision = historyErrorRevision { clearError(since: revision, only: .requestFailed) }
        historyErrorRevision = nil
        requestHistorySync(); publish()
    }
    public func loadEarlier() async throws {
        guard state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        let current = generation, sessionVersion = sessionRevision
        while let task = historyTask {
            await task.value
            try Task.checkCancellation()
            guard generation == current, sessionRevision == sessionVersion, state.sessionId == session else { throw CFLFailure.sessionChanged }
        }
        if state.historySyncFailed { throw CFLFailure.requestFailed }
        guard !historyLoading, let before = state.before else { return }
        let revision = historyRevision
        let loadingID = UUID()
        historyLoading = true; historyLoadingID = loadingID
        defer {
            if historyLoadingID == loadingID {
                historyLoading = false; historyLoadingID = nil
                if historyDirty { requestHistorySync() }
            }
        }
        let raw = try await call(method: "history", args: [.string(before)])
        try Task.checkCancellation()
        guard raw.object?["before"] != nil else { throw CFLFailure.protocolError }
        let page: CFLPage = try decode(CFLPage.self, raw)
        guard state.sessionId == session, generation == current, sessionRevision == sessionVersion,
              historyRevision == revision else { throw CFLFailure.sessionChanged }
        guard page.messages.count <= 30, raw.object?["messages"]?.array?.allSatisfy(validMessageWire) == true, page.messages.allSatisfy(\.valid), Set(page.messages.map(\.id)).count == page.messages.count else { throw CFLFailure.protocolError }
        let ids = Set(state.messages.map(\.id)); let added = page.messages.filter { !ids.contains($0.id) }.map { historyPatches[$0.id] ?? $0 }
        historyPatches.removeAll(); historyPatchBytes = 0
        olderMessages = added + olderMessages; state.messages = added + state.messages
        historyLoaded = true; state.before = page.before; publish(); requestRetirement()
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
    public func markdownImage(_ source: String, expectedSessionId: String, expectedSessionRevision: Int) async throws -> Data {
        guard active, !disconnecting, state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
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
        let request = try request(path: path, method: "GET")
        let (data, _) = try await imageResponse(request)
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision,
              state.sessionId == session, state.connection == .online else { throw CFLFailure.sessionChanged }
        return data
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
    /// Loads only an authenticated media ID from the currently connected origin.
    /// If a preview is absent, falls back to the bounded original; an absent
    /// original remains a failure. Discard results when the page disappears.
    public func media(_ ref: CFLImageRef, original: Bool = false,
                      expectedSessionId: String? = nil, expectedSessionRevision: Int? = nil) async throws -> Data {
        guard ref.valid, ref.availability == "available" else { throw CFLFailure.invalidInput }
        guard active, state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        guard expectedSessionId.map({ $0 == session }) ?? true,
              expectedSessionRevision.map({ $0 == sessionRevision }) ?? true else { throw CFLFailure.sessionChanged }
        try Task.checkCancellation()
        let current = generation, revision = sessionRevision
        func checkCurrent() throws {
            guard !Task.isCancelled, active, generation == current, sessionRevision == revision, state.sessionId == session,
                  state.connection == .online else { throw CFLFailure.sessionChanged }
        }
        let request = try request(path: "/api/chat/media/\(ref.attachmentId)/\(original ? "original" : "preview")", method: "GET")
        var (data, response) = try await imageResponse(request, allowNotFound: !original)
        try checkCurrent()
        var readOriginal = original
        if response.statusCode == 404 {
            let fallback = try self.request(path: "/api/chat/media/\(ref.attachmentId)/original", method: "GET")
            (data, response) = try await imageResponse(fallback)
            readOriginal = true
            try checkCurrent()
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map(String.init)?.lowercased()
        guard data.count <= (readOriginal ? 32 * 1024 * 1024 : 160_000), !data.isEmpty,
              let type, CFLImageLimits.types.contains(type), readOriginal || type == "image/jpeg" else { throw CFLFailure.protocolError }
        return data
    }
    /// Returns the locally durable operation ID, not an admission or reply receipt.
    /// After this returns, inspect pending state even if the connection was lost.
    /// CFLPendingStorageUncertain identifies an undispatched input whose first save
    /// could not be verified; preserve it until the store can be read again.
    @discardableResult public func send(_ text: String, images: [CFLPreparedImage] = [],
                                        expectedSessionId: String? = nil, expectedSessionRevision: Int? = nil) async throws -> String {
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
        guard (!trimmed.isEmpty || !images.isEmpty), trimmed != "/compact", text.utf16.count <= 16000 else { throw CFLFailure.invalidInput }
        let operation = UUID().uuidString.lowercased()
        defer {
            if state.localDrafts.contains(where: { $0.operationId == operation && $0.sessionId == session }) {
                state.localDrafts.removeAll { $0.operationId == operation && $0.sessionId == session }; publish()
            }
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
        var entry = CFLPending(target: target, sessionId: session, operationId: operation, text: text, createdAt: Date(), dispatched: false, status: .unknown, images: refs)
        do { try await persist(entries + [entry]) }
        catch {
            guard loaded else { throw CFLPendingStorageUncertain(pending: entry) }
            if entries.contains(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) {
                return entry.operationId
            }
            throw error
        }
        if !images.isEmpty { state.localDrafts.removeAll { $0.operationId == operation && $0.sessionId == session }; publish() }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.connection == .online, state.sessionId == session else {
            setError(.sessionChanged); publish(); return entry.operationId
        }
        entry.dispatched = true
        guard let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) else {
            setError(.storage); publish(); return entry.operationId
        }
        var next = entries; next[index] = entry
        do { try await persist(next) }
        catch {
            if !loaded, let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) {
                // The dispatched marker may have committed; do not offer dismissal
                // until the store can be read again.
                entries[index].dispatched = true; showPending(); publish()
            }
            return entry.operationId
        }
        guard !Task.isCancelled, active, !disconnecting, generation == current, sessionRevision == revision, state.connection == .online, state.sessionId == session else {
            setError(.sessionChanged); publish(); return entry.operationId
        }
        submitting.insert(entry.operationId)
        scheduleDeadline()
        let previousError = errorRevision
        do {
            let value = try await call(method: "submit", args: [submission(entry)])
            guard value != .null else { throw CFLFailure.protocolError }
            guard active, !disconnecting, generation == current else { throw CFLFailure.offline }
            try await accept(value, entry: entry)
            clearError(since: previousError)
        } catch {
            setError((error as? CFLFailure) ?? .requestFailed); publish()
        }
        submitting.remove(entry.operationId)
        requestReconcile()
        return entry.operationId
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
        guard UUID(uuidString: operationId) != nil else { throw CFLFailure.invalidInput }
        guard let index = entries.firstIndex(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == operationId && $0.status == .failed && $0.dispatched }) else { throw CFLFailure.invalidInput }
        let original = entries[index], attempt = UUID().uuidString.lowercased()
        var entry = CFLPending(target: target, sessionId: sessionId, operationId: attempt, text: original.text, createdAt: Date(), dispatched: false, status: .unknown, images: original.images, retrySource: operationId)
        var next = entries; next[index] = entry
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
        guard let fields = value.object, Set(fields.keys).subtracting(["retryImages"]) == Set(["operationId", "state", "messageId", "turnId", "error"]) else { throw CFLFailure.protocolError }
        let receipt: CFLReceipt = try decode(CFLReceipt.self, value)
        guard receipt.operationId == entry.operationId, let status = CFLPendingStatus(rawValue: receipt.state), status != .unknown else { throw CFLFailure.protocolError }
        guard let index = entries.firstIndex(where: { $0.target == entry.target && $0.sessionId == entry.sessionId && $0.operationId == entry.operationId }) else { return }
        if entries[index].status == .submitted { requestRetirement(); return }
        guard state.sessionId == entry.sessionId else { throw CFLFailure.sessionChanged }
        var next = entries
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
            state.localPreviews = state.localPreviews.map { preview in
                guard preview.sessionId == entry.sessionId, preview.operationId == source, let old = preview.attachmentId, let ref = refs[old] else { return preview }
                return CFLLocalImagePreview(sessionId: preview.sessionId, operationId: entry.operationId, originOperationId: preview.originOperationId, draftId: preview.draftId, order: preview.order, attachmentId: ref.attachmentId, data: preview.data)
            }
            next[index].images = originals.map { refs[$0.attachmentId]! }
        } else if fields["retryImages"] != nil { throw CFLFailure.protocolError }
        next[index].retrySource = nil; next[index].status = status
        try await persist(next)
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
        guard let item = entries.first(where: { $0.target == target && $0.sessionId == sessionId && $0.operationId == operationId }), item.status != .unknown || !item.dispatched else { return }
        try await persist(entries.filter { !($0.target == target && $0.sessionId == sessionId && $0.operationId == operationId) })
    }
}
