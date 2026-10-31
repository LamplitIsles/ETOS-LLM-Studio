import Foundation

/// A single active CFL session. State and pending records retain server string identities.
public actor CFLChatClient {
    public typealias TransportFactory = @Sendable () async throws -> any CFLChatTransport
    private let target: String
    private let store: any CFLPendingStore
    private let transportFactory: TransportFactory
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
    private var historyRevision = 0
    private var historyLoaded = false
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
    private var olderMessages: [CFLMessage] = []
    private var latestMessages: [CFLMessage] = []
    private var latestBefore: String?

    /// target is a stable, credential-free identifier for the connection; use one active client per store.
    public init(target: String, store: any CFLPendingStore, transport: @escaping TransportFactory) {
        self.target = target; self.store = store; self.transportFactory = transport
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
        transport = socket; chord = ChordState(); subscribed = false; queuedUpdates = []
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, generation: current) }
        let snapshot = try await call(service: "$chord.service", method: "subscribe", args: [.string("view"), .string("lamplit.chat.v2"), .string("singleton")])
        guard generation == current else { throw CFLFailure.offline }
        try chord.hydrate(snapshot)
        subscribed = true
        for update in queuedUpdates { try chord.update(update) }
        queuedUpdates.removeAll()
        try applyView()
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
                        try chord.update(update); try applyView()
                        requestReconcile(publication: true)
                    }
                    else { guard queuedUpdates.count < 100 else { throw CFLFailure.protocolError }; queuedUpdates.append(update) }
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
        deadlineTask?.cancel(); deadlineTask = nil
        checks.removeAll(); finalized.removeAll()
        let old = transport; transport = nil
        for continuation in calls.values { continuation.resume(throwing: CFLFailure.offline) }; calls.removeAll()
        for timer in timeouts.values { timer.cancel() }; timeouts.removeAll()
        subscribed = false; chord = ChordState(); queuedUpdates = []
        let failure = error as? CFLFailure
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
                catch { await self?.failCall(id, generation: current) }
            }
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                await self?.failCall(id, generation: current)
            }
        }
    }
    private func failCall(_ id: String, generation current: Int) async {
        guard current == generation, calls[id] != nil else { return }
        await disconnected(CFLFailure.offline, reconnect: true)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: ChordJSON) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw CFLFailure.protocolError }
    }
    private func applyView() throws {
        guard let value = chord.value, let fields = value.object,
              fields["activeTurnId"] != nil, fields["before"] != nil,
              let capabilities = fields["capabilities"]?.object,
              capabilities["text"] == .bool(true), capabilities["stop"] == .bool(true),
              fields["contextUsage"] != nil, fields["compaction"] != nil, fields["recovery"]?.array != nil else { throw CFLFailure.protocolError }
        let view = try decode(CFLView.self, value)
        guard view.version == 2, !view.sessionId.isEmpty, view.messages.count <= 30,
              view.messages.allSatisfy({ !$0.id.isEmpty && ["user", "agent", "notice"].contains($0.role) }) else { throw CFLFailure.protocolError }
        let changedSession = state.sessionId != view.sessionId
        if changedSession {
            sessionRevision += 1
            deadlineTask?.cancel(); deadlineTask = nil
            checks.removeAll(); finalized.removeAll()
        }
        let latest = Set(view.messages.map(\.id))
        // Only join windows when their server IDs prove they overlap. Otherwise
        // keep the new contiguous window and page backwards from its cursor.
        let hasHistory = historyLoaded || !olderMessages.isEmpty || !latestMessages.isEmpty
        let overlaps = (olderMessages + latestMessages).contains { latest.contains($0.id) }
        // An empty projection has no IDs to establish continuity. Compare the
        // server's anchor, not the independently advanced history cursor.
        let emptyAnchorChanged = latestMessages.isEmpty && view.messages.isEmpty && latestBefore != view.before
        let lostContinuity = (hasHistory && !overlaps && (!view.messages.isEmpty || !latestMessages.isEmpty)) || emptyAnchorChanged
        if changedSession || lostContinuity {
            historyRevision += 1
            historyLoaded = false
            olderMessages = []; latestMessages = []; state.before = view.before
        }
        var seen = Set<String>()
        olderMessages = (olderMessages + latestMessages.filter { !latest.contains($0.id) }).filter { !latest.contains($0.id) && seen.insert($0.id).inserted }
        latestMessages = view.messages
        latestBefore = view.before
        if olderMessages.isEmpty && !historyLoaded { state.before = view.before }
        state.messages = olderMessages + view.messages
        state.sessionId = view.sessionId; state.name = view.name; state.activeTurnId = view.activeTurnId; state.streamingReply = view.streamingReply; state.replyCompletedTurnId = view.replyCompletedTurnId
        showPending(); publish(); requestRetirement()
    }
    public func loadEarlier() async throws {
        guard state.connection == .online else { throw CFLFailure.offline }
        guard !historyLoading, let before = state.before, let session = state.sessionId else { return }
        let current = generation, revision = historyRevision, sessionVersion = sessionRevision
        historyLoading = true; defer { historyLoading = false }
        let raw = try await call(method: "history", args: [.string(before)])
        guard raw.object?["before"] != nil else { throw CFLFailure.protocolError }
        let page: CFLPage = try decode(CFLPage.self, raw)
        guard state.sessionId == session, generation == current, sessionRevision == sessionVersion,
              historyRevision == revision else { throw CFLFailure.sessionChanged }
        guard page.messages.count <= 30 else { throw CFLFailure.protocolError }
        let ids = Set(state.messages.map(\.id)); let added = page.messages.filter { !ids.contains($0.id) }
        olderMessages = added + olderMessages; state.messages = added + state.messages
        historyLoaded = true; state.before = page.before; publish(); requestRetirement()
    }
    /// Returns the locally durable operation ID, not an admission or reply receipt.
    /// After this returns, inspect pending state even if the connection was lost.
    /// CFLPendingStorageUncertain identifies an undispatched input whose first save
    /// could not be verified; preserve it until the store can be read again.
    @discardableResult public func send(_ text: String) async throws -> String {
        let current = generation
        try await load()
        guard active, !disconnecting, generation == current, state.connection == .online, let session = state.sessionId else { throw CFLFailure.offline }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/compact", text.unicodeScalars.count <= 16000 else { throw CFLFailure.invalidInput }
        var entry = CFLPending(target: target, sessionId: session, operationId: UUID().uuidString.lowercased(), text: text, createdAt: Date(), dispatched: false, status: .unknown)
        do { try await persist(entries + [entry]) }
        catch {
            guard loaded else { throw CFLPendingStorageUncertain(pending: entry) }
            if entries.contains(where: { $0.target == target && $0.sessionId == session && $0.operationId == entry.operationId }) {
                return entry.operationId
            }
            throw error
        }
        guard active, !disconnecting, generation == current, state.connection == .online, state.sessionId == session else {
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
        guard active, !disconnecting, generation == current, state.connection == .online, state.sessionId == session else {
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
        .object(["operationId": .string(pending.operationId), "text": .string(pending.text)])
    }
    private func accept(_ value: ChordJSON, entry: CFLPending) async throws {
        guard value != .null else { return }
        guard let fields = value.object, Set(fields.keys) == Set(["operationId", "state", "messageId", "turnId", "error"]) else { throw CFLFailure.protocolError }
        let receipt: CFLReceipt = try decode(CFLReceipt.self, value)
        guard receipt.operationId == entry.operationId, let status = CFLPendingStatus(rawValue: receipt.state), status != .unknown else { throw CFLFailure.protocolError }
        guard let index = entries.firstIndex(where: { $0.target == entry.target && $0.sessionId == entry.sessionId && $0.operationId == entry.operationId }) else { return }
        if entries[index].status == .submitted { requestRetirement(); return }
        var next = entries; next[index].status = status
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
                let value = try await call(method: expired ? "finalizeSubmission" : "lookup", args: [expired ? .object(["sessionId": .string(session), "submission": submission(entry)]) : .string(entry.operationId)])
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
