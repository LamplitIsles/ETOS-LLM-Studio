import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor MemoryStore: CFLPendingStore {
    var entries: [CFLPending] = []
    var fail = false
    var failLoad = false
    var failSaveNumber: Int?
    var commitBeforeFailure = false
    var saveCount = 0
    var pauseSave = false
    var pausedSave: CheckedContinuation<Void, Never>?
    func load() throws -> [CFLPending] { if fail || failLoad { throw CFLFailure.storage }; return entries }
    func save(_ entries: [CFLPending]) async throws {
        saveCount += 1
        if pauseSave {
            pauseSave = false
            await withCheckedContinuation { pausedSave = $0 }
        }
        if fail { throw CFLFailure.storage }
        if saveCount == failSaveNumber {
            if commitBeforeFailure { self.entries = entries }
            throw CFLFailure.storage
        }
        self.entries = entries
    }
    func setFail() { fail = true }
    func injectSaveFailure(_ number: Int, afterCommit: Bool, unreadable: Bool = false) {
        failSaveNumber = number; commitBeforeFailure = afterCommit; failLoad = unreadable
    }
    func restoreReads() { failLoad = false }
    func setEntries(_ value: [CFLPending]) { entries = value }
    func pauseNextSave() { pauseSave = true }
    func saveIsPaused() -> Bool { pausedSave != nil }
    func resumeSave() { pausedSave?.resume(); pausedSave = nil }
}

actor CompletionFlag {
    private var done = false
    func complete() { done = true }
    func isComplete() -> Bool { done }
}

actor FakeSocket: CFLChatTransport {
    let snapshot: ChordJSON
    var queue: [String] = []
    var waiter: CheckedContinuation<String, Error>?
    var closed = false
    var sent: [(String, [ChordJSON])] = []
    var dropSubmit = false
    var holdSubmit = false
    var heldSubmitID: String?
    var dropRetry = false
    var holdRetry = false
    var heldRetryID: String?
    var failedSubmit = false
    var retryReceipt: ChordJSON = .null
    var lookupReceipt: ChordJSON = .null
    var holdLookup = false
    var heldLookupID: String?
    var historyPages: [String: ChordJSON] = [:]
    var holdHistory = false
    var heldHistory: (String, ChordJSON)?
    let earlyUpdate: ChordJSON?
    init(snapshot: ChordJSON, dropSubmit: Bool = false, lookupReceipt: ChordJSON = .null, earlyUpdate: ChordJSON? = nil, holdLookup: Bool = false) {
        self.snapshot = snapshot; self.dropSubmit = dropSubmit; self.lookupReceipt = lookupReceipt; self.earlyUpdate = earlyUpdate; self.holdLookup = holdLookup
    }
    func send(_ text: String) async throws {
        guard !closed, let call = try JSONDecoder().decode(ChordJSON.self, from: Data(text.utf8)).object,
              let id = call["id"]?.string, let command = call["call"]?.object,
              let method = command["member"]?.string, let args = command["args"]?.array else { throw CFLFailure.offline }
        sent.append((method, args))
        if method == "submit" && dropSubmit { await close(); return }
        if method == "submit" && holdSubmit { heldSubmitID = id; return }
        if method == "retryFailed" && dropRetry { await close(); return }
        if method == "retryFailed" && holdRetry { heldRetryID = id; return }
        if method == "lookup" && holdLookup { heldLookupID = id; return }
        let result: ChordJSON
        switch method {
        case "subscribe":
            if let earlyUpdate { enqueue(String(decoding: try JSONEncoder().encode(earlyUpdate), as: UTF8.self)) }
            result = snapshot
        case "submit":
            let operation = args[0].object!["operationId"]!
            result = .object(["operationId":operation,"state":.string(failedSubmit ? "failed" : "submitted"),"messageId":.null,"turnId":.null,"error":.null])
        case "retryFailed":
            if var fields = retryReceipt.object { fields["operationId"] = args[0].object?["attemptId"]; result = .object(fields) }
            else { result = retryReceipt }
        case "lookup", "finalizeSubmission": result = lookupReceipt
        case "stop": result = .object(["stopped":.bool(true)])
        case "history":
            result = historyPages[args[0].string ?? ""] ?? .object(["messages":.array([]),"before":.null])
            if holdHistory { heldHistory = (id, result); return }
        default: throw CFLFailure.protocolError
        }
        let frame = ChordJSON.object(["type":.string("result"),"id":.string(id),"result":result])
        let data = try JSONEncoder().encode(frame); enqueue(String(decoding: data, as: UTF8.self))
    }
    func enqueue(_ text: String) { if let waiter { self.waiter = nil; waiter.resume(returning: text) } else { queue.append(text) } }
    func receive() async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CFLFailure.offline }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: CFLFailure.offline); waiter = nil }
    func methods() -> [String] { sent.map { $0.0 } }
    func arguments(for method: String) -> [[ChordJSON]] { sent.filter { $0.0 == method }.map { $0.1 } }
    func setHistory(_ pages: [String: ChordJSON], hold: Bool = false) { historyPages = pages; holdHistory = hold }
    func setRetry(drop: Bool = false, hold: Bool = false, receipt: ChordJSON = .null) { dropRetry = drop; holdRetry = hold; retryReceipt = receipt }
    func retryIsHeld() -> Bool { heldRetryID != nil }
    func releaseRetry() throws {
        guard let id = heldRetryID, var fields = retryReceipt.object,
              let attempt = sent.last(where: { $0.0 == "retryFailed" })?.1.first?.object?["attemptId"] else { throw CFLFailure.protocolError }
        heldRetryID = nil; holdRetry = false; fields["operationId"] = attempt
        try emit(.object(["type": .string("result"), "id": .string(id), "result": .object(fields)]))
    }
    func setFailedSubmit() { failedSubmit = true }
    func setHoldSubmit() { holdSubmit = true }
    func submitIsHeld() -> Bool { heldSubmitID != nil }
    func setLookup(_ value: ChordJSON) { lookupReceipt = value }
    func historyIsHeld() -> Bool { heldHistory != nil }
    func releaseHistory() throws {
        guard let (id, result) = heldHistory else { throw CFLFailure.protocolError }
        heldHistory = nil; holdHistory = false
        try emit(.object(["type": .string("result"), "id": .string(id), "result": result]))
    }
    func emit(_ frame: ChordJSON) throws { enqueue(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)) }
    func releaseLookup() throws {
        guard let id = heldLookupID else { throw CFLFailure.protocolError }
        heldLookupID = nil; holdLookup = false
        try emit(.object(["type": .string("result"), "id": .string(id), "result": lookupReceipt]))
    }
}

actor SocketSequence {
    var sockets: [FakeSocket]
    init(_ sockets: [FakeSocket]) { self.sockets = sockets }
    func append(_ socket: FakeSocket) { sockets.append(socket) }
    func next() throws -> FakeSocket {
        guard !sockets.isEmpty else { throw CFLFailure.offline }
        return sockets.removeFirst()
    }
}

func historyMessage(_ number: Int) -> ChordJSON {
    .object(["id": .string("server-\(number)"), "role": .string("user"), "text": .string("message \(number)"),
             "createdAt": .number(Double(number)), "operationId": .null, "turnId": .null])
}

func historyPage(_ range: Range<Int>, before: String?) -> ChordJSON {
    .object(["messages": .array(range.map(historyMessage)), "before": before.map(ChordJSON.string) ?? .null])
}

func historySnapshot(_ range: Range<Int>, before: String?, session: String = "fixture-session", messages: [ChordJSON]? = nil) -> ChordJSON {
    let view: ChordJSON = .object([
        "version": .number(2), "sessionId": .string(session), "name": .string("Mica"), "activeTurnId": .null,
        "contextUsage": .null, "compaction": .null, "recovery": .array([]),
        "capabilities": .object(["text": .bool(true), "stop": .bool(true)]),
        "messages": .array(messages ?? range.map(historyMessage)), "before": before.map(ChordJSON.string) ?? .null,
    ])
    return .object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"), "instances": .array([
        .object(["members": .array([.object(["name": .string("view"), "kind": .string("state"), "sequence": .number(0),
            "ops": .array([.array([.string("r"), view])])])])])
    ])])
}

func timeline(_ change: ChordJSON, session: String = "fixture-session") -> ChordJSON {
    .object(["type": .string("timeline"), "sessionId": .string(session), "change": change])
}
func imageSlot(_ id: String, state: String) -> ChordJSON {
    var fields: [String: ChordJSON] = ["id": .string(id), "role": .string("agent"), "text": .string(""), "createdAt": .number(1),
                                        "operationId": .null, "turnId": .string("turn"), "imageState": .string(state)]
    if state == "ready" { fields["images"] = .array([.object(["attachmentId": .string("image"), "name": .string("image.png"), "mediaType": .string("image/png"), "availability": .string("available")])]) }
    return .object(fields)
}
func checkHistoryTimeout() async throws {
    let socket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
    await socket.setHistory(["c30": historyPage(0..<30, before: nil)], hold: true)
    let client = CFLChatClient(target: "history", store: MemoryStore(), requestTimeout: { method in
        try await Task.sleep(nanoseconds: method == "history" ? 200_000_000 : 30_000_000_000)
    }, transport: { socket })
    await client.connect()
    let old = Task { try await client.loadEarlier() }
    for _ in 0..<200 { if await socket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    let held = await socket.historyIsHeld(); precondition(held)
    try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("new-session")))
    for _ in 0..<200 { if await client.currentState().sessionId == "new-session" { break }; try await Task.sleep(nanoseconds: 1_000_000) }
    await socket.setHistory(["c30": historyPage(100..<130, before: nil)])
    try await client.loadEarlier()
    do { try await old.value; preconditionFailure("old history timed out successfully") } catch { }
    var current = await client.currentState()
    precondition(current.sessionId == "new-session" && current.connection == .online && current.messages.first?.id == "server-100")
    try await socket.releaseHistory()
    try await Task.sleep(nanoseconds: 20_000_000)
    current = await client.currentState()
    precondition(current.connection == .online && current.messages.first?.id == "server-100")
    _ = try await client.send("still connected")
    let methods = await socket.methods(); precondition(methods.filter { $0 == "submit" }.count == 1)
    await client.disconnect()

    let mutationSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil)), store = MemoryStore()
    await mutationSocket.setHoldSubmit()
    let mutation = CFLChatClient(target: "history", store: store, requestTimeout: { method in
        try await Task.sleep(nanoseconds: method == "submit" ? 100_000_000 : 30_000_000_000)
    }, transport: { mutationSocket })
    await mutation.connect()
    _ = try await mutation.send("unknown submit")
    let mutationState = await mutation.currentState(), mutationMethods = await mutationSocket.methods()
    precondition(mutationState.connection != .online && mutationState.pending.first?.status == .unknown && mutationMethods.filter { $0 == "submit" }.count == 1)
    await mutation.disconnect()

    let retrySocket = FakeSocket(snapshot: imageSnapshot()), retryStore = MemoryStore()
    await retrySocket.setFailedSubmit()
    let retry = CFLChatClient(target: "history", store: retryStore, requestTimeout: { method in
        try await Task.sleep(nanoseconds: method == "retryFailed" ? 100_000_000 : 30_000_000_000)
    }, transport: { retrySocket })
    await retry.connect()
    let source = try await retry.send("explicit retry")
    let revision = await retry.currentState().sessionRevision
    await retrySocket.setRetry(hold: true)
    let attempt = try await retry.retryFailed(sessionId: "A", operationId: source, expectedSessionRevision: revision)
    let retryState = await retry.currentState(), retryMethods = await retrySocket.methods()
    precondition(retryState.connection != .online && retryState.pending.first?.operationId == attempt && retryState.pending.first?.status == .unknown && retryMethods.filter { $0 == "retryFailed" }.count == 1)
    await retry.disconnect()
}

func checkOrderedTimeline() async throws {
    var invalid = imageSlot("bad", state: "ready").object!; invalid.removeValue(forKey: "images")
    var nullImages = imageSlot("bad", state: "preparing").object!; nullImages["images"] = .null
    var badText = imageSlot("bad", state: "preparing").object!; badText["textState"] = .string("invented")
    for fields in [invalid, nullImages, badText] {
        let badSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, messages: [.object(fields)]))
        let bad = CFLChatClient(target: "history", store: MemoryStore(), transport: { badSocket })
        await bad.connect(); let value = await bad.currentState(); precondition(value.connection == .protocolError)
        await bad.disconnect()
    }
    let socket = FakeSocket(snapshot: historySnapshot(60..<90, before: "c60"))
    var oldest = (0..<30).map(historyMessage); oldest[3] = imageSlot("server-3", state: "preparing")
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(oldest), "before": .null])])
    let sockets = SocketSequence([socket])
    let client = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await sockets.next() })
    await client.connect(); try await client.loadEarlier(); try await client.loadEarlier()
    var current = await client.currentState()
    precondition(current.messages.count == 90 && current.messages[3].imageState == .preparing)
    let baseline = await socket.arguments(for: "history").count
    try await socket.emit(timeline(.object(["type": .string("item"), "message": imageSlot("server-3", state: "ready")])))
    for _ in 0..<200 { if await client.currentState().messages[3].imageState == .ready { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    current = await client.currentState(); precondition(current.messages[3].imageState == .ready && current.messages[3].images?.first?.attachmentId == "image")
    let afterItem = await socket.arguments(for: "history").count; precondition(afterItem == baseline)
    try await socket.emit(timeline(.object(["type": .string("item"), "message": imageSlot("not-loaded", state: "ready")])))
    try await Task.sleep(nanoseconds: 20_000_000)
    current = await client.currentState(); precondition(!current.messages.contains { $0.id == "not-loaded" })

    let inserted = historyMessage(1000)
    var shifted = Array(oldest.dropFirst()); shifted.insert(inserted, at: 1)
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(shifted), "before": .string("c0")]), "c0": historyPage(0..<1, before: nil)], hold: true)
    try await socket.emit(timeline(.object(["type": .string("structure")])))
    for _ in 0..<200 { if await socket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let held = await socket.historyIsHeld(); precondition(held)
    try await socket.emit(timeline(.object(["type": .string("item"), "message": imageSlot("server-3", state: "failed")])))
    var live = (60..<90).map(historyMessage); var changed = live[0].object!; changed["text"] = .string("new view while reading"); live[0] = .object(changed)
    try await socket.emit(update(sequence: 1, field: "messages", value: .array(live)))
    shifted[3] = imageSlot("server-3", state: "failed")
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(shifted), "before": .string("c0")]), "c0": historyPage(0..<1, before: nil)])
    try await socket.emit(timeline(.object(["type": .string("structure")])))
    try await socket.releaseHistory()
    for _ in 0..<300 {
        let value = await client.currentState()
        if value.messages.count == 91 && value.messages.contains(where: { $0.id == "server-3" && $0.imageState == .failed }) { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    current = await client.currentState()
    precondition(current.messages.count == 91 && current.messages[2].id == "server-1000" && current.messages[4].imageState == .failed && current.messages.first(where: { $0.id == "server-60" })?.text == "new view while reading" && !current.historySyncFailed)

    await socket.setHistory(["c60": historyPage(30..<60, before: nil)])
    try await socket.emit(timeline(.object(["type": .string("structure")])))
    for _ in 0..<200 { if await client.currentState().historySyncFailed { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    current = await client.currentState(); precondition(current.historySyncFailed && current.messages.count == 91)
    shifted[3] = imageSlot("server-3", state: "failed")
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(shifted), "before": .string("c0")]), "c0": historyPage(0..<1, before: nil)])
    let beforeRetry = await socket.arguments(for: "history").count
    await client.retryHistory()
    for _ in 0..<200 {
        let count = await socket.arguments(for: "history").count
        let value = await client.currentState()
        if count >= beforeRetry + 3 && !value.historySyncFailed { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let beforeReset = await socket.arguments(for: "history").count
    try await socket.emit(.object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object(["type": .string("reset"), "snapshot": historySnapshot(60..<90, before: "c60")])]))
    for _ in 0..<200 { if await socket.arguments(for: "history").count >= beforeReset + 3 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let resetCalls = await socket.arguments(for: "history").count; precondition(resetCalls >= beforeReset + 3)
    let next = FakeSocket(snapshot: historySnapshot(90..<120, before: "c90"))
    await next.setHistory(["c90": historyPage(60..<90, before: "c60"), "c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(shifted), "before": .string("c0")]), "c0": historyPage(0..<1, before: nil)])
    await sockets.append(next); await client.disconnect(); await client.connect()
    for _ in 0..<300 { if await client.currentState().messages.count == 121 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    current = await client.currentState()
    precondition(current.messages.count == 121 && current.messages[4].imageState == .failed && current.before == nil && !current.historySyncFailed)
    await client.disconnect()

    let serialSocket = FakeSocket(snapshot: historySnapshot(60..<90, before: "c60"))
    await serialSocket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": historyPage(0..<30, before: nil)])
    let serial = CFLChatClient(target: "history", store: MemoryStore(), transport: { serialSocket })
    await serial.connect(); try await serial.loadEarlier()
    await serialSocket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": historyPage(0..<30, before: nil)], hold: true)
    try await serialSocket.emit(timeline(.object(["type": .string("structure")])))
    for _ in 0..<200 { if await serialSocket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let beforeManual = await serialSocket.arguments(for: "history").count
    let manual = Task { try await serial.loadEarlier() }
    try await Task.sleep(nanoseconds: 20_000_000)
    let duringManual = await serialSocket.arguments(for: "history").count; precondition(duringManual == beforeManual)
    try await serialSocket.releaseHistory(); try await manual.value
    current = await serial.currentState(); precondition(current.messages.count == 90 && current.before == nil)
    await serial.disconnect()

    let cancelSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
    await cancelSocket.setHistory(["c30": historyPage(0..<30, before: nil)], hold: true)
    let cancelled = CFLChatClient(target: "history", store: MemoryStore(), transport: { cancelSocket })
    await cancelled.connect()
    let loading = Task { try await cancelled.loadEarlier() }
    for _ in 0..<200 { if await cancelSocket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    loading.cancel(); try await cancelSocket.releaseHistory()
    do { try await loading.value; preconditionFailure("cancelled page applied") } catch is CancellationError { }
    current = await cancelled.currentState(); precondition(current.messages.count == 30 && current.before == "c30")
    await cancelled.disconnect()

    // Neither a pending manual page nor an automatic reconciliation from the
    // previous session may block paging the new session or apply afterward.
    for automatic in [false, true] {
        let switchingSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
        await switchingSocket.setHistory(["c30": historyPage(0..<30, before: nil)])
        let switching = CFLChatClient(target: "history", store: MemoryStore(), transport: { switchingSocket })
        await switching.connect()
        if automatic { try await switching.loadEarlier() }
        await switchingSocket.setHistory(["c30": historyPage(0..<30, before: nil)], hold: true)
        let oldLoad: Task<Void, Error>?
        if automatic {
            oldLoad = nil
            try await switchingSocket.emit(timeline(.object(["type": .string("structure")])))
        } else {
            oldLoad = Task { try await switching.loadEarlier() }
        }
        for _ in 0..<200 { if await switchingSocket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let heldOld = await switchingSocket.historyIsHeld(); precondition(heldOld)
        try await switchingSocket.emit(update(sequence: 1, field: "sessionId", value: .string("new-session")))
        for _ in 0..<200 { if await switching.currentState().sessionId == "new-session" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        await switchingSocket.setHistory(["c30": historyPage(100..<130, before: nil)])
        try await switching.loadEarlier()
        current = await switching.currentState()
        precondition(current.sessionId == "new-session" && current.messages.first?.id == "server-100" && current.before == nil)
        try await switchingSocket.releaseHistory()
        if let oldLoad {
            do { try await oldLoad.value; preconditionFailure("old session page accepted") } catch CFLFailure.sessionChanged { }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        current = await switching.currentState()
        precondition(current.sessionId == "new-session" && current.messages.first?.id == "server-100" && current.before == nil)
        await switching.disconnect()
    }

    let brokenSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
    await brokenSocket.setHistory(["c30": historyPage(0..<30, before: nil)])
    let repairedSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
    await repairedSocket.setHistory(["c30": historyPage(0..<30, before: nil)])
    let recoverySockets = SocketSequence([brokenSocket, repairedSocket])
    let recovery = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await recoverySockets.next() })
    await recovery.connect(); try await recovery.loadEarlier()
    await brokenSocket.setHistory(["c30": historyPage(1..<30, before: nil)])
    try await brokenSocket.emit(timeline(.object(["type": .string("structure")])))
    for _ in 0..<200 { if await recovery.currentState().historySyncFailed { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    current = await recovery.currentState(); precondition(current.historySyncFailed && current.messages.count == 60)
    await recovery.disconnect(); await recovery.connect()
    for _ in 0..<200 {
        let calls = await repairedSocket.arguments(for: "history").count
        let value = await recovery.currentState()
        if calls > 0 && !value.historySyncFailed { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    current = await recovery.currentState(); precondition(!current.historySyncFailed && current.messages.count == 60)
    await recovery.disconnect()
}

func checkReminderSources() async throws {
    let image: ChordJSON = .object(["attachmentId": .string("fixture_image"), "name": .string("image.png"),
                                    "mediaType": .string("image/png"), "availability": .string("available")])
    let reminder: ChordJSON = .object(["kind": .string("reminder"), "reminderId": .string("r1"),
                                       "occurrenceId": .string("occ1")])
    func fixture(_ id: String, _ role: String, _ text: String, source: ChordJSON? = nil, images: [ChordJSON]? = nil) -> ChordJSON {
        var fields: [String: ChordJSON] = ["id": .string(id), "role": .string(role), "text": .string(text),
                                            "createdAt": .number(1), "operationId": .null, "turnId": .null]
        if let source { fields["source"] = source }
        if let images { fields["images"] = .array(images) }
        return .object(fields)
    }
    let current = [
        fixture("live-user", "user", "第一行\n第二行", source: reminder, images: [image]),
        fixture("emoji", "user", "⏰ 普通消息"),
        fixture("matrix", "user", "matrix", source: .object(["kind": .string("matrix"), "nested": .array([.bool(true)])])),
        fixture("future", "agent", "future", source: .object(["kind": .string("future"), "detail": .number(42)])),
        fixture("malformed", "user", "ordinary", source: .string("unexpected")),
        fixture("unknown-kind", "user", "ordinary", source: .object(["kind": .array([])])),
        fixture("null", "user", "ordinary", source: .null),
    ]
    let historical = fixture("history-agent", "agent", "历史提醒\n原文", source: reminder, images: [image])
    let socket = FakeSocket(snapshot: historySnapshot(0..<0, before: "older", messages: current))
    await socket.setHistory(["older": .object(["messages": .array([historical]), "before": .null])])
    let client = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { socket })
    await client.connect()
    var state = await client.currentState()
    precondition(state.connection == .online && state.messages.map(\.id) == ["live-user", "emoji", "matrix", "future", "malformed", "unknown-kind", "null"])
    precondition(state.messages.map(\.isReminder) == [true, false, false, false, false, false, false])
    precondition(state.messages[0].role == "user" && state.messages[0].text == "第一行\n第二行" && state.messages[0].images?.first?.attachmentId == "fixture_image")
    try await client.loadEarlier()
    state = await client.currentState()
    precondition(state.messages.first?.id == "history-agent" && state.messages.first?.role == "agent" && state.messages.first?.isReminder == true)
    precondition(state.messages.first?.text == "历史提醒\n原文" && state.messages.first?.images?.first?.attachmentId == "fixture_image")
    try await socket.emit(update(sequence: 1, field: "messages", value: .array(current + [fixture("live-agent", "agent", "新提醒", source: reminder)])))
    for _ in 0..<100 {
        if await client.currentState().messages.last?.id == "live-agent" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await client.currentState()
    precondition(state.messages.first?.id == "history-agent" && state.messages.last?.id == "live-agent" && state.messages.last?.isReminder == true)
    let methods = await socket.methods(); precondition(!methods.contains("submit"))
    await client.disconnect()
    print("CFL reminder source checks passed")
}

func checkHistoryWindows() async throws {
    let old = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let fresh = FakeSocket(snapshot: historySnapshot(70..<100, before: "before-70"))
    await fresh.setHistory([
        "before-70": historyPage(40..<70, before: "before-40"),
        "before-40": historyPage(10..<40, before: "before-10"),
        "before-10": historyPage(0..<10, before: nil),
    ])
    let sockets = SocketSequence([old, fresh])
    let client = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await sockets.next() })
    await client.connect(); await client.disconnect(); await client.connect()
    var state = await client.currentState()
    for _ in 0..<200 {
        state = await client.currentState()
        if state.messages.count == 100 && state.before == nil { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    state = await client.currentState()
    precondition(state.messages.map(\.id) == (0..<100).map { "server-\($0)" } && state.before == nil)
    let calls = await fresh.arguments(for: "history")
    precondition(calls == [[.string("before-70")], [.string("before-40")], [.string("before-10")]])
    let methods = await fresh.methods(); precondition(!methods.contains("submit"))
    await client.disconnect()

    // An unreachable boundary leaves both windows visible and can be retried.
    let failureOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let failureNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "before-70"))
    await failureNew.setHistory(["before-70": historyPage(40..<70, before: nil)])
    let failureSockets = SocketSequence([failureOld, failureNew])
    let failure = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await failureSockets.next() })
    await failure.connect(); await failure.disconnect(); await failure.connect()
    for _ in 0..<200 { if await failure.currentState().historySyncFailed { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    state = await failure.currentState()
    precondition(state.historySyncFailed && state.messages.map(\.id) == ((0..<30).map { "server-\($0)" } + (70..<100).map { "server-\($0)" }))
    await failureNew.setHistory(["before-70": historyPage(40..<70, before: "before-40"), "before-40": historyPage(10..<40, before: "before-10"), "before-10": historyPage(0..<10, before: nil)])
    await failure.retryHistory()
    for _ in 0..<200 { if await failure.currentState().messages.count == 100 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    state = await failure.currentState(); precondition(state.messages.map(\.id) == (0..<100).map { "server-\($0)" } && !state.historySyncFailed)
    await failure.disconnect()

    // A reconnect scan cannot block or overwrite a different session's page.
    let switchOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let switchNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "before-70"))
    await switchNew.setHistory(["before-70": historyPage(40..<70, before: "before-40")], hold: true)
    let switchSockets = SocketSequence([switchOld, switchNew])
    let switched = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await switchSockets.next() })
    await switched.connect(); await switched.disconnect(); await switched.connect()
    for _ in 0..<200 { if await switchNew.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let reconnectHeld = await switchNew.historyIsHeld(); precondition(reconnectHeld)
    try await switchNew.emit(update(sequence: 1, field: "sessionId", value: .string("another-session")))
    for _ in 0..<200 { if await switched.currentState().sessionId == "another-session" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await switchNew.setHistory(["before-70": historyPage(200..<230, before: nil)])
    try await switched.loadEarlier()
    try await switchNew.releaseHistory()
    try await Task.sleep(nanoseconds: 20_000_000)
    state = await switched.currentState()
    precondition(state.sessionId == "another-session" && state.messages.first?.id == "server-200" && state.messages.count == 60 && state.before == nil)
    await switched.disconnect()

    let overlappingOld = FakeSocket(snapshot: historySnapshot(30..<60, before: "before-30"))
    await overlappingOld.setHistory(["before-30": historyPage(0..<30, before: nil)])
    let overlappingNew = FakeSocket(snapshot: historySnapshot(50..<80, before: "before-50"))
    let overlapSockets = SocketSequence([overlappingOld, overlappingNew])
    let overlap = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await overlapSockets.next() })
    await overlap.connect(); try await overlap.loadEarlier(); await overlap.disconnect(); await overlap.connect()
    state = await overlap.currentState()
    precondition(state.messages.map(\.id) == (0..<80).map { "server-\($0)" } && state.before == nil)
    await overlap.disconnect()

    // Filtered native windows can be empty while still pointing to earlier history.
    let emptySocket = FakeSocket(snapshot: historySnapshot(0..<0, before: "empty"))
    await emptySocket.setHistory(["empty": historyPage(0..<0, before: "earlier"), "earlier": historyPage(0..<2, before: nil)])
    let empty = CFLChatClient(target: "history", store: MemoryStore(), transport: { emptySocket })
    await empty.connect(); try await empty.loadEarlier()
    try await emptySocket.emit(update(sequence: 1, field: "name", value: .string("Updated")))
    for _ in 0..<100 {
        if await empty.currentState().name == "Updated" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await empty.currentState(); precondition(state.name == "Updated" && state.before == "earlier")
    try await empty.loadEarlier()
    state = await empty.currentState()
    precondition(state.messages.map(\.id) == ["server-0", "server-1"] && state.before == nil)
    try await emptySocket.emit(update(sequence: 2, field: "name", value: .string("Updated again")))
    for _ in 0..<100 {
        if await empty.currentState().name == "Updated again" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await empty.currentState()
    precondition(state.name == "Updated again" && state.messages.map(\.id) == ["server-0", "server-1"] && state.before == nil)
    await empty.disconnect()

    let sameOld = FakeSocket(snapshot: historySnapshot(0..<0, before: "A"))
    await sameOld.setHistory(["A": historyPage(0..<0, before: "earlier")])
    let sameNew = FakeSocket(snapshot: historySnapshot(0..<0, before: "A"))
    await sameNew.setHistory(["A": historyPage(0..<0, before: "earlier"), "earlier": historyPage(0..<2, before: nil)])
    let sameSockets = SocketSequence([sameOld, sameNew])
    let sameAnchor = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await sameSockets.next() })
    await sameAnchor.connect(); try await sameAnchor.loadEarlier(); await sameAnchor.disconnect(); await sameAnchor.connect()
    state = await sameAnchor.currentState(); precondition(state.messages.isEmpty && state.before == "earlier")
    try await sameAnchor.loadEarlier()
    state = await sameAnchor.currentState()
    precondition(state.messages.map(\.id) == ["server-0", "server-1"] && state.before == nil)
    await sameAnchor.disconnect()

    // A new empty native window may hide visible messages between its new
    // anchor and the old history, even when the session is unchanged.
    let emptyOld = FakeSocket(snapshot: historySnapshot(0..<0, before: "A"))
    await emptyOld.setHistory(["A": historyPage(0..<2, before: "older")])
    let emptyNew = FakeSocket(snapshot: historySnapshot(0..<0, before: "B"))
    await emptyNew.setHistory(["B": historyPage(2..<4, before: "A"), "A": historyPage(0..<2, before: "older")])
    let emptySockets = SocketSequence([emptyOld, emptyNew])
    let reconnectedEmpty = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await emptySockets.next() })
    await reconnectedEmpty.connect(); try await reconnectedEmpty.loadEarlier()
    state = await reconnectedEmpty.currentState()
    precondition(state.messages.map(\.id) == ["server-0", "server-1"] && state.before == "older")
    await reconnectedEmpty.disconnect(); await reconnectedEmpty.connect()
    for _ in 0..<200 {
        state = await reconnectedEmpty.currentState()
        if state.messages.map(\.id) == ["server-0", "server-1", "server-2", "server-3"] { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    state = await reconnectedEmpty.currentState()
    precondition(state.sessionId == "fixture-session" && state.messages.map(\.id) == ["server-0", "server-1", "server-2", "server-3"] && state.before == "older")
    let emptyCalls = await emptyNew.arguments(for: "history")
    precondition(emptyCalls == [[.string("B")], [.string("A")]])
    await reconnectedEmpty.disconnect()

    // A changed empty anchor also invalidates a page already in flight, even
    // before the first history page has completed.
    let emptyRaceSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: "A"))
    await emptyRaceSocket.setHistory(["A": historyPage(0..<2, before: "older")], hold: true)
    let emptyRace = CFLChatClient(target: "history", store: MemoryStore(), transport: { emptyRaceSocket })
    await emptyRace.connect()
    let emptyLoad = Task { try await emptyRace.loadEarlier() }
    for _ in 0..<100 {
        if await emptyRaceSocket.historyIsHeld() { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let emptyHistoryHeld = await emptyRaceSocket.historyIsHeld(); precondition(emptyHistoryHeld)
    try await emptyRaceSocket.emit(update(sequence: 1, field: "before", value: .string("B")))
    for _ in 0..<100 {
        if await emptyRace.currentState().before == "B" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await emptyRace.currentState(); precondition(state.before == "B")
    try await emptyRaceSocket.releaseHistory()
    do { try await emptyLoad.value; preconditionFailure("stale empty-window history accepted") } catch CFLFailure.sessionChanged { }
    state = await emptyRace.currentState(); precondition(state.messages.isEmpty && state.before == "B")
    await emptyRace.disconnect()

    let racingSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "before-30"))
    await racingSocket.setHistory(["before-30": historyPage(0..<30, before: nil)], hold: true)
    let racing = CFLChatClient(target: "history", store: MemoryStore(), transport: { racingSocket })
    await racing.connect()
    let load = Task { try await racing.loadEarlier() }
    for _ in 0..<100 {
        if await racingSocket.historyIsHeld() { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let historyHeld = await racingSocket.historyIsHeld(); precondition(historyHeld)
    await racingSocket.setHistory(["before-70": historyPage(40..<70, before: "before-40"), "before-40": historyPage(10..<40, before: "before-10")])
    try await racingSocket.emit(.object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
        "type": .string("state"), "member": .string("view"), "sequence": .number(1),
        "ops": .array([.array([.string("s"), .array([.string("messages")]), .array((70..<100).map(historyMessage))]),
                       .array([.string("s"), .array([.string("before")]), .string("before-70")])])])]))
    for _ in 0..<100 {
        if await racing.currentState().messages.last?.id == "server-99" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await racingSocket.releaseHistory()
    do { try await load.value; preconditionFailure("stale history accepted") } catch CFLFailure.sessionChanged { }
    for _ in 0..<200 {
        state = await racing.currentState()
        if state.messages.map(\.id) == (10..<100).map({ "server-\($0)" }) { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    state = await racing.currentState()
    precondition(state.messages.map(\.id) == (10..<100).map { "server-\($0)" } && state.before == "before-10" && !state.historySyncFailed)
    await racing.disconnect()

    let sessionSocket = FakeSocket(snapshot: historySnapshot(30..<60, before: "before-30"))
    await sessionSocket.setHistory(["before-30": historyPage(0..<30, before: nil)], hold: true)
    let sessionClient = CFLChatClient(target: "history", store: MemoryStore(), transport: { sessionSocket })
    await sessionClient.connect()
    let oldSessionLoad = Task { try await sessionClient.loadEarlier() }
    for _ in 0..<100 {
        if await sessionSocket.historyIsHeld() { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let sessionHistoryHeld = await sessionSocket.historyIsHeld(); precondition(sessionHistoryHeld)
    try await sessionSocket.emit(update(sequence: 1, field: "sessionId", value: .string("another-session")))
    for _ in 0..<100 {
        if await sessionClient.currentState().sessionId == "another-session" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await sessionClient.currentState(); precondition(state.sessionId == "another-session")
    try await sessionSocket.emit(update(sequence: 2, field: "sessionId", value: .string("fixture-session")))
    for _ in 0..<100 {
        if await sessionClient.currentState().sessionId == "fixture-session" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    state = await sessionClient.currentState(); precondition(state.sessionId == "fixture-session")
    try await sessionSocket.releaseHistory()
    do { try await oldSessionLoad.value; preconditionFailure("old session history accepted") } catch CFLFailure.sessionChanged { }
    state = await sessionClient.currentState()
    precondition(state.messages.map(\.id) == (30..<60).map { "server-\($0)" } && state.before == "before-30")
    await sessionClient.disconnect()
}

func checkHistoryPatchOrdering() async throws {
    func text(_ number: Int, _ value: String, _ state: String) -> ChordJSON {
        var fields = historyMessage(number).object!
        fields["role"] = .string("agent"); fields["text"] = .string(value); fields["textState"] = .string(state)
        return .object(fields)
    }
    let socket = FakeSocket(snapshot: historySnapshot(60..<90, before: "c60"))
    var oldest = (0..<30).map(historyMessage)
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(oldest), "before": .null])])
    let client = CFLChatClient(target: "history", store: MemoryStore(), transport: { socket })
    await client.connect(); try await client.loadEarlier(); try await client.loadEarlier()
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(oldest), "before": .null])], hold: true)
    try await socket.emit(timeline(.object(["type": .string("structure")])))
    for _ in 0..<200 { if await socket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let held = await socket.historyIsHeld(); precondition(held)
    try await socket.emit(timeline(.object(["type": .string("item"), "message": text(3, "partial", "streaming")])))
    for _ in 0..<200 { if await client.currentState().messages[3].text == "partial" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    oldest[3] = text(3, "completed full text", "complete")
    await socket.setHistory(["c60": historyPage(30..<60, before: "c30"), "c30": .object(["messages": .array(oldest), "before": .null])])
    try await socket.emit(timeline(.object(["type": .string("structure")])))
    try await Task.sleep(nanoseconds: 20_000_000)
    try await socket.emit(timeline(.object(["type": .string("item"), "message": text(4, "later streaming", "streaming")])))
    for _ in 0..<200 { if await client.currentState().messages[4].text == "later streaming" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await socket.releaseHistory()
    for _ in 0..<200 { if await socket.arguments(for: "history").count >= 5 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let current = await client.currentState()
    precondition(current.messages.count == 90 && current.messages[3].text == "completed full text" && current.messages[3].textState == .complete)
    precondition(current.messages[4].text == "later streaming" && current.messages[4].textState == .streaming)
    await client.disconnect()
}

func update(sequence: Int, field: String, value: ChordJSON) -> ChordJSON {
    .object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
        "type": .string("state"), "member": .string("view"), "sequence": .number(Double(sequence)),
        "ops": .array([.array([.string("s"), .array([.string(field)]), value])]),
    ])])
}

func message(operation: String, role: String = "user") -> ChordJSON {
    .object(["id": .string("message-\(operation)-\(role)"), "role": .string(role), "text": .string("text"),
             "createdAt": .number(1), "operationId": .string(operation), "turnId": .null])
}

actor FakeImageHTTP: CFLImageHTTP {
    var requests: [URLRequest] = []
    var fail = false
    var hold = false
    var missingPreview = false
    var missingOriginal = false
    var status = 200
    var malformed = ""
    var continuation: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { continuation = $0 }; hold = false }
        if fail { throw CFLFailure.requestFailed }
        if request.url!.path == "/api/auth/status" {
            return (Data("{\"state\":\"signed_in\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if request.httpMethod == "GET" {
            let original = request.url!.path.hasSuffix("/original")
            let missing = original ? missingOriginal : missingPreview
            let response = HTTPURLResponse(url: request.url!, statusCode: missing ? 404 : status, httpVersion: nil,
                                           headerFields: ["Content-Type": original ? "image/png" : "image/jpeg"])!
            return (original ? Data([137, 80, 78, 71, 13, 10, 26, 10, 1]) : Data([255, 216, 255, 1]), response)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let images = payload["images"] as! [[String: Any]]
        var refs = images.enumerated().map { index, item in
            ["id": item["id"]!, "order": index, "ref": ["attachmentId": "stored_\(index)", "name": item["name"]!, "mediaType": item["mediaType"]!, "availability": "available"]] as [String : Any]
        }
        if malformed == "reordered" { refs.reverse() }
        if malformed == "duplicate" && refs.count > 1 { refs[1]["ref"] = refs[0]["ref"] }
        if malformed == "omitted" { refs.removeLast() }
        if malformed == "wrong-draft" { refs[0]["id"] = "wrong" }
        if malformed == "wrong-order" { refs[0]["order"] = 1 }
        if malformed == "extra-item" { refs[0]["extra"] = "bad" }
        var result: [String: Any] = ["sessionId": malformed == "session" ? "wrong" : payload["sessionId"]!, "operationId": malformed == "operation" ? UUID().uuidString : payload["operationId"]!, "images": refs]
        if malformed == "extra-top" { result["extra"] = "bad" }
        return (try JSONSerialization.data(withJSONObject: result), response)
    }
    func setFailure() { fail = true }
    func setStatus(_ value: Int) { status = value }
    func setMalformed(_ value: String) { malformed = value }
    func setMissing(preview: Bool, original: Bool = false) { missingPreview = preview; missingOriginal = original }
    func setHold() { hold = true }
    func isHeld() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func allRequests() -> [URLRequest] { requests }
}

final class ImageTestCredentials: CFLCredentialStore, @unchecked Sendable {
    func load(origin: String) throws -> CFLCredentials? {
        CFLCredentials(accessToken: "fixture-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture)
    }
    func save(_ credentials: CFLCredentials, origin: String) throws { }
}

actor FakeVoiceHTTP: CFLImageHTTP {
    var requests: [URLRequest] = []
    var status = 200
    var redirected = false
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { continuation = $0 }; hold = false }
        if request.url!.path == "/api/auth/status" {
            return (Data("{\"state\":\"signed_out\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let url = redirected ? URL(string: "https://outside.test/audio")! : request.url!
        return (Data("ID3".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!)
    }
    func setStatus(_ value: Int) { status = value }
    func setRedirected(_ value: Bool) { redirected = value }
    func setHold() { hold = true }
    func isHeld() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func allRequests() -> [URLRequest] { requests }
}

func checkVoiceMessages() async throws {
    let id = String(repeating: "a", count: 64)
    func message(_ messageId: String, _ audioId: String) -> ChordJSON {
        .object(["id": .string(messageId), "role": .string("agent"), "text": .string(""), "createdAt": .number(1),
                 "operationId": .null, "turnId": .null, "voice": .object(["id": .string(audioId)])])
    }
    let socket = FakeSocket(snapshot: historySnapshot(0..<0, before: "older", session: "A", messages: [message("live", id)]))
    await socket.setHistory(["older": .object(["messages": .array([message("old", id)]), "before": .null])])
    let http = FakeVoiceHTTP(), auth = CFLAuthorization(store: ImageTestCredentials(), http: http)
    try await auth.select(origin: "https://example.com")
    let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: CFLAuthorizedHTTP(authorization: auth, http: http), transport: { socket })
    await client.connect()
    let initial = await client.currentState()
    precondition(initial.messages.first?.voice?.id == id && initial.messages.first?.text == "")
    try await client.loadEarlier()
    let state = await client.currentState()
    precondition(state.messages.map(\.id) == ["old", "live"] && state.messages.allSatisfy { $0.voice?.id == id })
    let ref = state.messages[0].voice!
    let bytes = try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision)
    precondition(bytes == Data("ID3".utf8))
    let request = await http.allRequests().last!
    precondition(request.url?.absoluteString == "https://example.com/api/audio/\(id).mp3")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    for invalid in ["../secret", String(repeating: "A", count: 64), id + "\n"] {
        do { _ = try await client.voice(CFLVoiceRef(id: invalid), expectedSessionId: "A", expectedSessionRevision: state.sessionRevision); preconditionFailure() } catch CFLFailure.invalidInput { }
    }
    await http.setRedirected(true)
    do { _ = try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision); preconditionFailure() } catch CFLFailure.protocolError { }
    await http.setRedirected(false); await http.setStatus(404)
    do { _ = try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision); preconditionFailure() } catch CFLFailure.requestFailed { }
    await http.setStatus(200); await http.setHold()
    let cancelled = Task { try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision) }
    while !(await http.isHeld()) { await Task.yield() }
    cancelled.cancel(); await http.release()
    do { _ = try await cancelled.value; preconditionFailure() } catch { }
    await http.setHold()
    let stale = Task { try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision) }
    while !(await http.isHeld()) { await Task.yield() }
    try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await client.currentState().sessionId != "B" { await Task.yield() }
    await http.release()
    do { _ = try await stale.value; preconditionFailure() } catch CFLFailure.sessionChanged { }
    do { _ = try await client.voice(ref, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision); preconditionFailure() } catch CFLFailure.sessionChanged { }
    await client.disconnect()
    let deniedSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, session: "A", messages: [message("live", id)]))
    let deniedHTTP = FakeVoiceHTTP(), deniedAuth = CFLAuthorization(store: ImageTestCredentials(), http: deniedHTTP)
    try await deniedAuth.select(origin: "https://example.com")
    let deniedClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: CFLAuthorizedHTTP(authorization: deniedAuth, http: deniedHTTP), transport: { deniedSocket })
    await deniedClient.connect()
    let deniedState = await deniedClient.currentState()
    await deniedHTTP.setStatus(403)
    do { _ = try await deniedClient.voice(ref, expectedSessionId: "A", expectedSessionRevision: deniedState.sessionRevision); preconditionFailure() } catch CFLFailure.accessDenied { }
    await deniedClient.disconnect()
    let badSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: "older", session: "A", messages: [message("live", id)]))
    await badSocket.setHistory(["older": .object(["messages": .array([message("bad", "../invalid")]), "before": .null])])
    let badClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), transport: { badSocket })
    await badClient.connect()
    do { try await badClient.loadEarlier(); preconditionFailure() } catch CFLFailure.protocolError { }
    await badClient.disconnect()
    print("CFL voice message checks passed")
}

func checkMarkdownImages() async throws {
    let examples: [(String, CFLMarkdownImage)] = [
        ("work/a%20b.png", .workspace("work/a b.png")),
        ("work/a%2520b.png", .workspace("work/a%20b.png")),
        ("/目录/猫.jpg", .workspace("/目录/猫.jpg")),
        ("https://local.test/a.png", .external("https://local.test/a.png")),
        ("/api/image?id=1", .api("/api/image?id=1")),
        ("/API/image.png", .invalid), ("%2Fapi%2Fimage.png", .invalid),
        ("//host/image.png", .invalid), ("%FF.png", .invalid), ("a%00.png", .invalid),
        ("a\\b.png", .invalid), ("file:a.png", .invalid), ("a.png?x=1", .invalid), ("a.svg", .invalid)
    ]
    for (input, expected) in examples { precondition(CFLMarkdownImage.resolve(input) == expected, input) }
    let socket = FakeSocket(snapshot: imageSnapshot()), http = FakeImageHTTP(), store = MemoryStore()
    let auth = CFLAuthorization(store: ImageTestCredentials(), http: http)
    try await auth.select(origin: "https://example.com")
    let client = CFLChatClient(target: "https://example.com", store: store,
        imageHTTP: CFLAuthorizedHTTP(authorization: auth, http: http), transport: { socket })
    await client.connect()
    let state = await client.currentState()
    func read(_ source: String) async throws -> Data {
        try await client.markdownImage(source, expectedSessionId: "A", expectedSessionRevision: state.sessionRevision)
    }
    // The snapshot has no workspace image declaration; the server response decides readability.
    let workspaceData = try await read("work/a%2520b%20猫.png")
    precondition(workspaceData == Data([255, 216, 255, 1]))
    let requests = await http.allRequests()
    let request = requests.last!
    precondition(request.url?.absoluteString == "https://example.com/api/chat/workspace-image?path=work%2Fa%2520b%20%E7%8C%AB.png")
    precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
    precondition(request.value(forHTTPHeaderField: "Origin") == "https://example.com")
    _ = try await read("/api/image?id=1")
    for source in ["https://outside.test/a.png", "http://outside.test/a.png", "/api/../secret", "/api/%2e%2e/secret", "/api/%2F%2Fevil", "/api/a#fragment", "/api/%ff"] {
        do { _ = try await read(source); preconditionFailure(source) } catch CFLFailure.invalidInput { }
    }
    let requestCount = await http.allRequests().count
    precondition(requestCount == 2)
    await http.setStatus(404)
    do { _ = try await read("missing.png"); preconditionFailure() } catch CFLFailure.requestFailed { }
    await http.setStatus(403)
    do { _ = try await read("denied.png"); preconditionFailure() } catch CFLFailure.offline { }
    let denialRequests = await http.allRequests()
    precondition(denialRequests.suffix(2).map { $0.url!.path } == ["/api/chat/workspace-image", "/api/auth/status"])
    await http.setStatus(302)
    do { _ = try await read("/api/image"); preconditionFailure() } catch CFLFailure.requestFailed { }
    await http.setStatus(200)
    _ = try await read("missing.png") // The server can permit a later retry.
    _ = try await read("/api/image") // A failed read can be retried.
    await http.setHold()
    let late = Task { try await read("a.png") }
    while !(await http.isHeld()) { await Task.yield() }
    try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await client.currentState().sessionId != "B" { await Task.yield() }
    try await socket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    while await client.currentState().sessionId != "A" { await Task.yield() }
    await http.release()
    do { _ = try await late.value; preconditionFailure() } catch CFLFailure.sessionChanged { }
    let next = await client.currentState()
    await http.setHold()
    let cancelled = Task { try await client.markdownImage("a.png", expectedSessionId: "A", expectedSessionRevision: next.sessionRevision) }
    while !(await http.isHeld()) { await Task.yield() }
    cancelled.cancel(); await http.release()
    do { _ = try await cancelled.value; preconditionFailure() } catch { }
    await http.setHold()
    let disconnected = Task { try await client.markdownImage("/api/image", expectedSessionId: "A", expectedSessionRevision: next.sessionRevision) }
    while !(await http.isHeld()) { await Task.yield() }
    await client.disconnect()
    await http.release()
    do { _ = try await disconnected.value; preconditionFailure() } catch CFLFailure.sessionChanged { }
    print("CFL Markdown image checks passed")
}

actor FakeExternalImageHTTP: CFLImageHTTP {
    var requests: [URLRequest] = []
    var responseURL: URL?
    var status = 200
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { held = $0 }; hold = false }
        return (Data([1, 2, 3]), HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func last() -> URLRequest? { requests.last }
    func count() -> Int { requests.count }
    func setResponse(_ url: URL?, status: Int) { responseURL = url; self.status = status }
    func setHold() { hold = true }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
}

func checkExternalMarkdownImages() async throws {
    let fake = FakeExternalImageHTTP(), loader = CFLExternalImageLoader(http: fake)
    let bytes = try await loader.data(for: "https://127.0.0.1/image.png")
    precondition(bytes == Data([1, 2, 3]))
    let first = await fake.last()!
    precondition(first.httpMethod == "GET" && !first.httpShouldHandleCookies)
    for header in ["Authorization", "Cookie", "Referer", "Proxy-Authorization"] { precondition(first.value(forHTTPHeaderField: header) == nil) }
    for bad in ["http://127.0.0.1/image.png", "http://example.test/image.png", "file:///tmp/image.png", "https://user:password@example.test/a", "data:image/png;base64,AA=="] {
        do { _ = try await loader.data(for: bad); preconditionFailure(bad) } catch CFLFailure.invalidInput { }
    }
    precondition(CFLMarkdownImage.resolve("http://example.test/image.png") == .external("http://example.test/image.png"))
    let count = await fake.count(); precondition(count == 1)
    await fake.setResponse(URL(string: "https://other.test/redirected.png")!, status: 200)
    _ = try await loader.data(for: "https://example.test/image.png")
    await fake.setResponse(nil, status: 404)
    do { _ = try await loader.data(for: "https://example.test/image.png"); preconditionFailure() } catch CFLFailure.requestFailed { }
    await fake.setResponse(URL(string: "file:///tmp/image.png")!, status: 200)
    do { _ = try await loader.data(for: "https://example.test/image.png"); preconditionFailure() } catch CFLFailure.protocolError { }
    await fake.setResponse(URL(string: "http://example.test/image.png")!, status: 200)
    do { _ = try await loader.data(for: "https://example.test/image.png"); preconditionFailure() } catch CFLFailure.protocolError { }
    await fake.setResponse(nil, status: 200)
    await fake.setHold()
    let cancelled = Task { try await loader.data(for: "https://example.test/image.png") }
    while !(await fake.isHeld()) { await Task.yield() }
    cancelled.cancel(); await fake.release()
    do { _ = try await cancelled.value; preconditionFailure() } catch is CancellationError { }

    // Invoke the actual redirect delegate without starting a task or making a request.
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://example.test/image.png")!)
    let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    let delegate = CFLExternalImageDelegate()
    for destination in ["https://other.test/image.png", "https://localhost/image.png", "https://192.168.1.1/image.png"] {
        var proposed = URLRequest(url: URL(string: destination)!)
        for header in ["Authorization", "Cookie", "Referer", "Proxy-Authorization"] { proposed.setValue("secret", forHTTPHeaderField: header) }
        var redirected: URLRequest?
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { redirected = $0 }
        precondition(redirected?.url == proposed.url && redirected?.httpMethod == "GET" && redirected?.httpShouldHandleCookies == false)
        for header in ["Authorization", "Cookie", "Referer", "Proxy-Authorization"] { precondition(redirected?.value(forHTTPHeaderField: header) == nil) }
    }
    for destination in ["http://other.test/image.png", "http://localhost/image.png", "file:///tmp/image.png", "https://user:password@example.test/a"] {
        let proposed = URLRequest(url: URL(string: destination)!)
        var redirected: URLRequest? = proposed
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { redirected = $0 }
        precondition(redirected == nil)
    }
    print("CFL external Markdown image checks passed")
}

func imageSnapshot(before: String? = nil) -> ChordJSON {
    let limits: ChordJSON = .object(["mediaTypes": .array([.string("image/png")]), "maxImagesPerMessage": .number(2), "maxImageBytes": .number(100), "maxMessageImageBytes": .number(150)])
    let images: [ChordJSON] = (0..<7).map { .object(["attachmentId": .string("output_\($0)"), "name": .string("out.png"), "mediaType": .string("image/png"), "availability": .string($0 == 0 ? "missing" : "available")]) }
    let view: ChordJSON = .object(["version": .number(2), "sessionId": .string("A"), "name": .string("test"), "activeTurnId": .null,
        "contextUsage": .null, "compaction": .null, "recovery": .array([]), "capabilities": .object(["text": .bool(true), "stop": .bool(true), "images": limits]),
        "messages": .array([.object(["id": .string("agent"), "role": .string("agent"), "text": .string(""), "createdAt": .number(1), "operationId": .null, "turnId": .null, "images": .array(images)])]), "before": before.map(ChordJSON.string) ?? .null])
    return .object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"), "instances": .array([.object(["members": .array([.object(["name": .string("view"), "kind": .string("state"), "sequence": .number(0), "ops": .array([.array([.string("r"), view])])])])])])])
}

func retryReceipt(attempt: String, source: String, session: String = "A", old: [String] = ["stored_0", "stored_1"], new: [String] = ["retry_0", "retry_1"]) -> ChordJSON {
    .object(["operationId": .string(attempt), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null,
             "retryImages": .object(["sessionId": .string(session), "sourceOperationId": .string(source), "images": .array(zip(old, new).map { oldID, newID in
                .object(["sourceAttachmentId": .string(oldID), "ref": .object(["attachmentId": .string(newID), "name": .string("same.png"), "mediaType": .string("image/png"), "availability": .string("available")])])
             })])])
}

func checkRetryImages() async throws {
    let png = Data([137,80,78,71,13,10,26,10,1]), jpeg = Data([255,216,255,1])
    let images = ["one", "two"].map { CFLPreparedImage(id: $0, name: "same.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg) }
    let definiteSocket = FakeSocket(snapshot: imageSnapshot()), definiteStore = MemoryStore()
    await definiteSocket.setFailedSubmit()
    let definite = CFLChatClient(target: "https://example.com", store: definiteStore, imageHTTP: FakeImageHTTP(), transport: { definiteSocket })
    await definite.connect()
    let definiteSource = try await definite.send("failed then retry", images: images)
    let initialDefinite = await definite.currentState(), originalPreviewIDs = initialDefinite.localPreviews.map(\.id)
    var failedReceipt = retryReceipt(attempt: "unused", source: definiteSource).object!
    failedReceipt["state"] = .string("failed")
    await definiteSocket.setRetry(receipt: .object(failedReceipt))
    let firstAttempt = try await definite.retryFailed(sessionId: "A", operationId: definiteSource, expectedSessionRevision: initialDefinite.sessionRevision)
    let firstState = await definite.currentState()
    precondition(firstState.pending.first?.operationId == firstAttempt && firstState.pending.first?.status == .failed && firstState.pending.first?.images?.map(\.attachmentId) == ["retry_0", "retry_1"])
    precondition(firstState.localPreviews.map(\.operationId) == [firstAttempt, firstAttempt])
    await definiteSocket.setRetry(receipt: retryReceipt(attempt: "unused", source: firstAttempt, old: ["retry_0", "retry_1"], new: ["again_0", "again_1"]))
    let nextAttempt = try await definite.retryFailed(sessionId: "A", operationId: firstAttempt, expectedSessionRevision: initialDefinite.sessionRevision)
    let nextState = await definite.currentState()
    precondition(nextState.pending.first?.operationId == nextAttempt && nextState.pending.first?.status == .submitted && nextState.localPreviews.map(\.attachmentId) == ["again_0", "again_1"] && nextState.localPreviews.map(\.id) == originalPreviewIDs)
    let explicitCalls = await definiteSocket.methods(); precondition(explicitCalls.filter { $0 == "retryFailed" }.count == 2)
    await definite.disconnect()

    let switchingSocket = FakeSocket(snapshot: imageSnapshot()), switchingStore = MemoryStore()
    await switchingSocket.setFailedSubmit()
    let switching = CFLChatClient(target: "https://example.com", store: switchingStore, imageHTTP: FakeImageHTTP(), transport: { switchingSocket })
    await switching.connect(); let switchingSource = try await switching.send("switch", images: images)
    let switchingRevision = await switching.currentState().sessionRevision
    await switchingSocket.setRetry(hold: true, receipt: retryReceipt(attempt: "unused", source: switchingSource))
    let heldRetry = Task { try await switching.retryFailed(sessionId: "A", operationId: switchingSource, expectedSessionRevision: switchingRevision) }
    for _ in 0..<200 { if await switchingSocket.retryIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await switchingSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await switching.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await switchingSocket.releaseRetry(); _ = try await heldRetry.value
    let switched = await switching.currentState()
    precondition(switched.sessionId == "B" && switched.localPreviews.isEmpty && switched.pending.first?.status == .unknown)
    try await switchingSocket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    for _ in 0..<200 { if await switching.currentState().sessionId == "A" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    do { _ = try await switching.retryFailed(sessionId: "A", operationId: switchingSource, expectedSessionRevision: switchingRevision); preconditionFailure("stale session retried") } catch CFLFailure.sessionChanged { }
    let switchedCalls = await switchingSocket.methods(); precondition(switchedCalls.filter { $0 == "retryFailed" }.count == 1)
    await switching.disconnect()

    let socket = FakeSocket(snapshot: imageSnapshot()), sockets = SocketSequence([socket]), store = MemoryStore(), http = FakeImageHTTP()
    await socket.setFailedSubmit()
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { try await sockets.next() })
    await client.connect()
    let originalRevision = await client.currentState().sessionRevision
    let source = try await client.send("retry image", images: images)
    let failed = await client.currentState(); precondition(failed.pending.first?.status == .failed && failed.localPreviews.count == 2)
    await socket.setRetry(drop: true)
    let attempt = try await client.retryFailed(sessionId: "A", operationId: source, expectedSessionRevision: originalRevision)
    let saved = await store.entries
    precondition(saved.count == 1 && saved[0].operationId == attempt && saved[0].retrySource == source && saved[0].dispatched && saved[0].status == .unknown)
    let encoded = try JSONEncoder().encode(saved); precondition(!String(decoding: encoded, as: UTF8.self).contains(jpeg.base64EncodedString()))
    let receipt = retryReceipt(attempt: attempt, source: source)
    let restored = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, session: "A", messages: [message(operation: attempt)]), lookupReceipt: receipt)
    await sockets.append(restored)
    for _ in 0..<400 {
        let state = await client.currentState()
        if state.connection == .online && state.pending.isEmpty && state.localPreviews.first?.operationId == attempt { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let confirmed = await client.currentState()
    precondition(confirmed.connection == .online && confirmed.pending.isEmpty)
    precondition(confirmed.localPreviews.map(\.draftId) == ["one", "two"] && confirmed.localPreviews.map(\.attachmentId) == ["retry_0", "retry_1"] && confirmed.localPreviews.allSatisfy { $0.operationId == attempt && $0.data == jpeg })
    let oldMethods = await socket.methods(), newMethods = await restored.methods()
    precondition(oldMethods.filter { $0 == "retryFailed" }.count == 1 && !newMethods.contains("retryFailed") && !newMethods.contains("submit") && newMethods.contains("lookup"))
    let released = await client.releasePreviews(sessionId: "A", operationId: attempt); precondition(released)
    await client.disconnect()

    let originalRefs = [CFLImageRef(attachmentId: "stored_0", name: "same.png", mediaType: "image/png", availability: "available"), CFLImageRef(attachmentId: "stored_1", name: "same.png", mediaType: "image/png", availability: "available")]
    for bad in [retryReceipt(attempt: attempt, source: UUID().uuidString), retryReceipt(attempt: attempt, source: source, session: "B"),
                retryReceipt(attempt: attempt, source: source, old: ["stored_0", "stored_0"]), retryReceipt(attempt: attempt, source: source, new: ["retry_0", "retry_0"])] {
        let badStore = MemoryStore(), badSocket = FakeSocket(snapshot: imageSnapshot(), lookupReceipt: bad)
        await badStore.setEntries([CFLPending(target: "https://example.com", sessionId: "A", operationId: attempt, text: "retry", createdAt: Date(), dispatched: true, status: .unknown, images: originalRefs, retrySource: source)])
        let badClient = CFLChatClient(target: "https://example.com", store: badStore, imageHTTP: FakeImageHTTP(), transport: { badSocket })
        await badClient.connect(); try? await badClient.reconcile()
        let state = await badClient.currentState(), calls = await badSocket.methods()
        precondition(state.pending.first?.status == .unknown && !calls.contains("retryFailed") && !calls.contains("submit"))
        await badClient.disconnect()
    }
    let expiredStore = MemoryStore(), expiredSocket = FakeSocket(snapshot: imageSnapshot(), lookupReceipt: receipt)
    await expiredStore.setEntries([CFLPending(target: "https://example.com", sessionId: "A", operationId: attempt, text: "retry", createdAt: Date(timeIntervalSinceNow: -120), dispatched: true, status: .unknown, images: originalRefs, retrySource: source)])
    let expired = CFLChatClient(target: "https://example.com", store: expiredStore, imageHTTP: FakeImageHTTP(), transport: { expiredSocket })
    await expired.connect(); try await expired.reconcile()
    let calls = await expiredSocket.arguments(for: "finalizeSubmission")
    precondition(calls.count == 1 && calls[0][0].object?["retry"]?.object?["operationId"] == .string(source) && calls[0][0].object?["retry"]?.object?["attemptId"] == .string(attempt))
    let methods = await expiredSocket.methods(); precondition(!methods.contains("retryFailed") && !methods.contains("submit"))
    await expired.disconnect()
}

func checkImages() async throws {
    let legacy = Data("[{\"target\":\"x\",\"sessionId\":\"A\",\"operationId\":\"old\",\"text\":\"hello\",\"createdAt\":0,\"dispatched\":true,\"status\":\"unknown\"}]".utf8)
    let decodedLegacy = try JSONDecoder().decode([CFLPending].self, from: legacy)
    precondition(decodedLegacy.first?.images == nil)
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1]), jpeg = Data([255, 216, 255, 1])
    let first = CFLPreparedImage(id: "one", name: "same.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg)
    let second = CFLPreparedImage(id: "two", name: "same.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg)
    let socket = FakeSocket(snapshot: imageSnapshot()), http = FakeImageHTTP(), store = MemoryStore()
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
    await client.connect()
    let initial = await client.currentState()
    precondition(initial.imageLimits?.maxImagesPerMessage == 2 && initial.messages.first?.images?.count == 7 && initial.messages.first?.text == "")
    do { try await client.validateImages([first, second, first]); preconditionFailure("count accepted") } catch {}
    let operation = try await client.send("", images: [first, second], expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision)
    let submissions = await socket.arguments(for: "submit")
    let payload = submissions[0][0].object!
    precondition(payload["operationId"] == .string(operation) && payload["text"] == .string("") && payload["images"]?.array?.count == 2)
    let records = await store.entries
    precondition(records.first?.images?.map(\.attachmentId) == ["stored_0", "stored_1"])
    let retained = await client.currentState().localPreviews
    precondition(retained.map(\.draftId) == ["one", "two"] && retained.map(\.attachmentId) == ["stored_0", "stored_1"] && retained.allSatisfy { $0.operationId == operation && $0.sessionId == "A" && $0.data == jpeg })
    let requests = await http.allRequests()
    let upload = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
    precondition(upload["operationId"] as? String == operation && upload["sessionId"] as? String == "A" && requests[0].value(forHTTPHeaderField: "Origin") == "https://example.com")
    let uploaded = upload["images"] as! [[String: Any]]
    precondition(uploaded.map { $0["id"] as! String } == ["one", "two"])
    let available = initial.messages[0].images![1]
    let media = try await client.media(available, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision)
    precondition(media == jpeg)
    do { _ = try await client.media(initial.messages[0].images![0]); preconditionFailure("missing accepted") } catch {}
    await client.disconnect()

    let boundarySocket = FakeSocket(snapshot: imageSnapshot()), boundaryHTTP = FakeImageHTTP()
    let boundary = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: boundaryHTTP, transport: { boundarySocket })
    await boundary.connect()
    let a = await boundary.currentState()
    try await boundarySocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await boundary.currentState().sessionId != "B" { await Task.yield() }
    let b = await boundary.currentState()
    precondition(b.sessionRevision == a.sessionRevision + 1)
    do { _ = try await boundary.send("", images: [first], expectedSessionId: "A", expectedSessionRevision: a.sessionRevision); preconditionFailure("A sent to B") } catch CFLFailure.sessionChanged {}
    do { _ = try await boundary.media(available, expectedSessionId: "A", expectedSessionRevision: a.sessionRevision); preconditionFailure("A media loaded in B") } catch CFLFailure.sessionChanged {}
    try await boundarySocket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    while await boundary.currentState().sessionId != "A" { await Task.yield() }
    let nextA = await boundary.currentState()
    precondition(nextA.sessionRevision == b.sessionRevision + 1)
    do { _ = try await boundary.send("", images: [first], expectedSessionId: "A", expectedSessionRevision: a.sessionRevision); preconditionFailure("stale A sent") } catch CFLFailure.sessionChanged {}
    do { _ = try await boundary.media(available, expectedSessionId: "A", expectedSessionRevision: a.sessionRevision); preconditionFailure("stale A media loaded") } catch CFLFailure.sessionChanged {}
    let boundaryRequests = await boundaryHTTP.allRequests()
    let boundaryMethods = await boundarySocket.methods()
    precondition(boundaryRequests.isEmpty && !boundaryMethods.contains("submit"))
    _ = try await boundary.send("plain text")
    await boundary.disconnect()

    let fallbackSocket = FakeSocket(snapshot: imageSnapshot(before: "older")), fallbackHTTP = FakeImageHTTP()
    let historyRef: ChordJSON = .object(["attachmentId": .string("history_1"), "name": .string("history.png"), "mediaType": .string("image/png"), "availability": .string("available")])
    let historyMessage: ChordJSON = .object(["id": .string("older-agent"), "role": .string("agent"), "text": .string(""), "createdAt": .number(0), "operationId": .null, "turnId": .null, "images": .array([historyRef])])
    await fallbackSocket.setHistory(["older": .object(["messages": .array([historyMessage]), "before": .null])])
    let fallbackClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: fallbackHTTP, transport: { fallbackSocket })
    await fallbackClient.connect()
    let fallbackState = await fallbackClient.currentState()
    await fallbackHTTP.setMissing(preview: true)
    let original = try await fallbackClient.media(available, expectedSessionId: "A", expectedSessionRevision: fallbackState.sessionRevision)
    precondition(original == png)
    try await fallbackClient.loadEarlier()
    let historyState = await fallbackClient.currentState()
    let historyOriginal = try await fallbackClient.media(historyState.messages[0].images![0], expectedSessionId: "A", expectedSessionRevision: fallbackState.sessionRevision)
    precondition(historyOriginal == png)
    let fallbackRequests = await fallbackHTTP.allRequests()
    precondition(fallbackRequests.map { $0.url!.path } == ["/api/chat/media/output_1/preview", "/api/chat/media/output_1/original", "/api/chat/media/history_1/preview", "/api/chat/media/history_1/original"])
    await fallbackHTTP.setMissing(preview: true, original: true)
    do { _ = try await fallbackClient.media(available); preconditionFailure("missing original accepted") } catch CFLFailure.requestFailed {}
    await fallbackClient.disconnect()

    let staleMediaSocket = FakeSocket(snapshot: imageSnapshot()), staleMediaHTTP = FakeImageHTTP()
    let staleMediaClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: staleMediaHTTP, transport: { staleMediaSocket })
    await staleMediaClient.connect(); await staleMediaHTTP.setMissing(preview: true); await staleMediaHTTP.setHold()
    let staleMedia = Task { try await staleMediaClient.media(available) }
    while !(await staleMediaHTTP.isHeld()) { await Task.yield() }
    try await staleMediaSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await staleMediaClient.currentState().sessionId != "B" { await Task.yield() }
    await staleMediaHTTP.release()
    do { _ = try await staleMedia.value; preconditionFailure("stale preview retried") } catch CFLFailure.sessionChanged {}
    let staleMediaRequests = await staleMediaHTTP.allRequests()
    precondition(staleMediaRequests.count == 1 && staleMediaRequests[0].url!.path.hasSuffix("/preview"))
    await staleMediaClient.disconnect()

    let failingSocket = FakeSocket(snapshot: imageSnapshot()), failingHTTP = FakeImageHTTP()
    await failingHTTP.setFailure()
    let failingClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: failingHTTP, transport: { failingSocket })
    await failingClient.connect()
    do { _ = try await failingClient.send("text", images: [first]); preconditionFailure("failed upload sent") } catch {}
    let failedMethods = await failingSocket.methods()
    precondition(!failedMethods.contains("submit"))
    await failingClient.disconnect()

    let switchingSocket = FakeSocket(snapshot: imageSnapshot()), switchingHTTP = FakeImageHTTP()
    let switching = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: switchingHTTP, transport: { switchingSocket })
    await switching.connect(); await switchingHTTP.setHold()
    let send = Task { try await switching.send("text", images: [first]) }
    while !(await switchingHTTP.isHeld()) { await Task.yield() }
    let inFlight = await switching.currentState().localDrafts
    precondition(inFlight.count == 1 && inFlight[0].sessionId == "A" && inFlight[0].text == "text" && inFlight[0].images[0].draftId == "one" && inFlight[0].images[0].attachmentId == nil && inFlight[0].images[0].data == jpeg)
    try await switchingSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await switching.currentState().sessionId != "B" { await Task.yield() }
    try await switchingSocket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    while await switching.currentState().sessionId != "A" { await Task.yield() }
    await switchingHTTP.release()
    do { _ = try await send.value; preconditionFailure("stale upload sent") } catch {}
    let switchedMethods = await switchingSocket.methods()
    precondition(!switchedMethods.contains("submit"))
    let switchedDrafts = await switching.currentState().localDrafts; precondition(switchedDrafts.isEmpty)
    await switching.disconnect()

    for malformed in ["reordered", "duplicate", "omitted", "wrong-draft", "wrong-order", "extra-item", "extra-top", "session", "operation"] {
        let badSocket = FakeSocket(snapshot: imageSnapshot()), badHTTP = FakeImageHTTP()
        await badHTTP.setMalformed(malformed)
        let bad = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: badHTTP, transport: { badSocket })
        await bad.connect()
        do { _ = try await bad.send("", images: [first, second]); preconditionFailure("accepted \(malformed)") } catch CFLFailure.protocolError { }
        let badMethods = await badSocket.methods()
        precondition(!badMethods.contains("submit"))
        await bad.disconnect()
    }

    let lostSocket = FakeSocket(snapshot: imageSnapshot(), dropSubmit: true), pendingStore = MemoryStore()
    let lost = CFLChatClient(target: "https://example.com", store: pendingStore, imageHTTP: FakeImageHTTP(), transport: { lostSocket })
    await lost.connect()
    let lostOperation = try await lost.send("caption", images: [first])
    await lost.disconnect()
    let saved = await pendingStore.entries
    precondition(saved.count == 1 && saved[0].operationId == lostOperation && saved[0].dispatched && saved[0].images?.count == 1)
    var expired = saved[0]
    expired = CFLPending(target: expired.target, sessionId: expired.sessionId, operationId: expired.operationId, text: expired.text,
                         createdAt: Date(timeIntervalSinceNow: -120), dispatched: true, status: .unknown, images: expired.images)
    await pendingStore.setEntries([expired])
    let restoreSocket = FakeSocket(snapshot: imageSnapshot())
    let restored = CFLChatClient(target: "https://example.com", store: pendingStore, imageHTTP: FakeImageHTTP(), transport: { restoreSocket })
    await restored.connect(); try await restored.reconcile()
    let finalize = await restoreSocket.arguments(for: "finalizeSubmission")
    let restoredMethods = await restoreSocket.methods()
    precondition(!restoredMethods.contains("submit") && finalize.count == 1)
    let restoredSubmission = finalize[0][0].object?["submission"]?.object
    precondition(restoredSubmission?["operationId"] == .string(lostOperation) && restoredSubmission?["images"]?.array?.count == 1)
    await restored.disconnect()
    print("CFL image checks passed")
}

#if !CFL_SOURCE_CHECKS
@main
#endif
struct CFLChatChecks {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().elementsEqual(["--patch-only"]) { try await checkHistoryPatchOrdering(); print("CFL history patch ordering checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--timeout-only"]) { try await checkHistoryTimeout(); print("CFL history timeout checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--ordered-only"]) { try await checkOrderedTimeline(); print("CFL ordered timeline checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--retry-only"]) { try await checkRetryImages(); print("CFL retry image checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--voice-only"]) { try await checkVoiceMessages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--external-images-only"]) { try await checkExternalMarkdownImages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--markdown-images-only"]) { try await checkMarkdownImages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--reminders-only"]) { try await checkReminderSources(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--images-only"]) { try await checkImages(); return }
        try await checkReminderSources()
        try await checkOrderedTimeline()
        try await checkRetryImages()
        try await checkHistoryWindows()
        if CommandLine.arguments.dropFirst().elementsEqual(["--history-only"]) {
            print("CFL history window checks passed")
            return
        }
        precondition(CFLHTTPSOrigin.normalized(" https://example.com:8443/ ") == "https://example.com:8443")
        precondition(CFLHTTPSOrigin.normalized("HTTPS://EXAMPLE.COM:443/") == "https://example.com")
        precondition(CFLHTTPSOrigin.normalized("https://EXAMPLE.COM:08443") == "https://example.com:8443")
        precondition(CFLHTTPSOrigin.normalized("https://[2001:DB8:0:0:0:0:0:1]:443/") == "https://[2001:db8::1]")
        precondition(CFLHTTPSOrigin.normalized("") == "")
        for invalid in ["http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com/?token=secret", "https://example.com/#fragment", "https://example.com:", "https://example.com:0", "https://example.com:65536", "https://example.com:bad", "https://bad..example", "https://-bad.example", "https://[2001:db8::zz]", "https://999.1.1.1"] {
            precondition(CFLHTTPSOrigin.normalized(invalid) == nil)
        }
        let decoder = JSONDecoder()
        let frames = try decoder.decode([ChordJSON].self, from: Data(contentsOf: URL(fileURLWithPath: "swiftpm/RuntimeTests/Fixtures/cfl-chord-js.json")))
        let snapshot = frames[0].object!["result"]!
        var state = ChordState(); try state.hydrate(snapshot)
        for frame in frames.dropFirst() where frame.object?["type"]?.string == "update" { try state.update(frame.object!["update"]!) }
        let view = try decoder.decode(CFLView.self, from: JSONEncoder().encode(state.value!))
        precondition(view.sessionId == "fixture-session" && view.messages.first?.text == "hello")
        let deltas = try decoder.decode([ChordJSON].self, from: Data(contentsOf: URL(fileURLWithPath: "swiftpm/RuntimeTests/Fixtures/chord-delta-js.json")))
        let base = ChordJSON.object(["serviceId":.string("lamplit.chat.v2"),"mode":.string("singleton"),"instances":.array([.object(["members":.array([.object(["name":.string("view"),"kind":.string("state"),"sequence":.number(0),"ops":deltas[0].object!["wire"]!])])])])])
        var delta = ChordState(); try delta.hydrate(base)
        for (index, sample) in deltas.enumerated().dropFirst() {
            try delta.update(.object(["type":.string("state"),"member":.string("view"),"sequence":.number(Double(index)),"ops":sample.object!["wire"]!]))
            precondition(delta.value == sample.object!["expected"]!)
        }
        do { try delta.update(.object(["type":.string("state"),"member":.string("view"),"sequence":.number(99),"ops":.array([])])); preconditionFailure("gap accepted") } catch {}
        let early = frames.first { $0.object?["type"]?.string == "update" }!
        let earlySocket = FakeSocket(snapshot: snapshot, earlyUpdate: early)
        let earlyClient = CFLChatClient(target: "test-target", store: MemoryStore(), transport: { earlySocket })
        await earlyClient.connect()
        let earlyState = await earlyClient.currentState()
        guard let turn = earlyState.activeTurnId else { preconditionFailure("early update lost") }
        let staleStop = try await earlyClient.stop(turnId: "stale"); precondition(!staleStop)
        let activeStop = try await earlyClient.stop(turnId: turn); precondition(activeStop)
        let stopCalls = await earlySocket.arguments(for: "stop"); precondition(stopCalls == [[.string(turn)]])
        await earlyClient.disconnect()
        guard let root = ProcessInfo.processInfo.environment["ETOS_CFL_TEST_ROOT"] else { fatalError("test-owned root required") }
        let directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("pending-data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CFLFilePendingStore(file: directory.appendingPathComponent("pending.json"))
        let originsFile = directory.appendingPathComponent("origins.json")
        let oldOrigin = "https://old.example", newOrigin = "https://new.example"
        let originUnknown = CFLPending(target: oldOrigin, sessionId: "fixture-session", operationId: "old-unknown", text: "unconfirmed", createdAt: Date(), dispatched: true, status: .unknown)
        let originUnsent = CFLPending(target: oldOrigin, sessionId: "other-session", operationId: "old-unsent", text: "unsent", createdAt: Date(), dispatched: false, status: .unknown)
        let originFailed = CFLPending(target: oldOrigin, sessionId: "fixture-session", operationId: "old-failed", text: "failed", createdAt: Date(), dispatched: true, status: .failed)
        let originSubmitted = CFLPending(target: oldOrigin, sessionId: "fixture-session", operationId: "old-submitted", text: "submitted", createdAt: Date(), dispatched: true, status: .submitted)
        let ownFailed = CFLPending(target: newOrigin, sessionId: "fixture-session", operationId: "new-failed", text: "new", createdAt: Date(), dispatched: true, status: .failed)
        let originsStore = CFLFilePendingStore(file: originsFile)
        let oldEntries = [originUnknown, originUnsent, originFailed, originSubmitted]
        try await originsStore.save(oldEntries + [ownFailed])
        let originsSocket = FakeSocket(snapshot: snapshot)
        let originsClient = CFLChatClient(target: newOrigin, store: originsStore, transport: { originsSocket })
        await originsClient.connect()
        let originState = await originsClient.currentState()
        precondition(originState.pending == [ownFailed] && originState.otherTargetPending == oldEntries)
        try await originsClient.reconcile()
        try await originsClient.dismissPending(sessionId: originUnknown.sessionId, operationId: originUnknown.operationId)
        try await originsClient.dismissPending(sessionId: ownFailed.sessionId, operationId: ownFailed.operationId)
        let afterOwnMutation = await originsClient.currentState()
        precondition(afterOwnMutation.pending.isEmpty && afterOwnMutation.otherTargetPending == oldEntries)
        let originMethods = await originsSocket.methods()
        precondition(!originMethods.contains("submit") && !originMethods.contains("lookup") && !originMethods.contains("finalizeSubmission"))
        await originsClient.disconnect()
        let restartSocket = FakeSocket(snapshot: snapshot)
        let restartedOrigins = CFLChatClient(target: newOrigin, store: CFLFilePendingStore(file: originsFile), transport: { restartSocket })
        await restartedOrigins.connect()
        let restartedState = await restartedOrigins.currentState()
        precondition(restartedState.pending.isEmpty && restartedState.otherTargetPending == oldEntries)
        let restartMethods = await restartSocket.methods()
        precondition(!restartMethods.contains("submit") && !restartMethods.contains("lookup") && !restartMethods.contains("finalizeSubmission"))
        await restartedOrigins.disconnect()
        let first = FakeSocket(snapshot: snapshot, dropSubmit: true)
        let client = CFLChatClient(target: "test-target", store: store, transport: { first })
        await client.connect()
        let admittedLocally = try await client.send("unconfirmed")
        await client.disconnect()
        let saved = try await store.load(); precondition(saved.count == 1 && saved[0].operationId == admittedLocally && saved[0].text == "unconfirmed" && saved[0].dispatched && saved[0].status == .unknown)
        let receipt: ChordJSON = .object(["operationId":.string(saved[0].operationId),"state":.string("submitted"),"messageId":.null,"turnId":.null,"error":.null])
        let second = FakeSocket(snapshot: snapshot, lookupReceipt: receipt)
        let restored = CFLChatClient(target: "test-target", store: CFLFilePendingStore(file: directory.appendingPathComponent("pending.json")), transport: { second })
        await restored.connect(); try await restored.reconcile()
        for _ in 0..<100 {
            let current = try await store.load()
            if current.first?.status == .submitted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recovered = try await store.load(); precondition(recovered[0].status == .submitted && recovered[0].operationId == saved[0].operationId)
        let methods = await second.methods(); precondition(methods.contains("lookup") && !methods.contains("submit"))
        await restored.disconnect()
        let expiredFile = directory.appendingPathComponent("expired.json")
        let expiredStore = CFLFilePendingStore(file: expiredFile)
        let expired = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "22222222-2222-4222-8222-222222222222", text: "original", createdAt: Date(timeIntervalSinceNow: -120), dispatched: true, status: .unknown)
        let unrelated = CFLPending(target: "other-target", sessionId: "fixture-session", operationId: "33333333-3333-4333-8333-333333333333", text: "other", createdAt: expired.createdAt, dispatched: true, status: .unknown)
        try await expiredStore.save([expired, unrelated])
        let expiredSocket = FakeSocket(snapshot: snapshot)
        let expiredClient = CFLChatClient(target: "test-target", store: expiredStore, transport: { expiredSocket })
        await expiredClient.connect()
        for _ in 0..<100 {
            let calls = await expiredSocket.arguments(for: "finalizeSubmission")
            if !calls.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finalized = await expiredSocket.arguments(for: "finalizeSubmission")
        precondition(finalized.count == 1 && finalized[0][0].object?["sessionId"]?.string == "fixture-session")
        let submitted = finalized[0][0].object?["submission"]?.object
        precondition(submitted?["operationId"]?.string == expired.operationId && submitted?["text"]?.string == "original")
        let expiredMethods = await expiredSocket.methods(); precondition(!expiredMethods.contains("submit"))
        await expiredClient.disconnect()
        let eventStore = MemoryStore()
        let eventEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "44444444-4444-4444-8444-444444444444", text: "pending", createdAt: Date(), dispatched: true, status: .unknown)
        let undispatched = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "55555555-5555-4555-8555-555555555555", text: "unsent", createdAt: Date(timeIntervalSinceNow: -120), dispatched: false, status: .unknown)
        try await eventStore.save([eventEntry, undispatched])
        let eventSocket = FakeSocket(snapshot: snapshot)
        let eventClient = CFLChatClient(target: "test-target", store: eventStore, transport: { eventSocket })
        await eventClient.connect()
        try await Task.sleep(nanoseconds: 5_300_000_000)
        var calls = await eventSocket.methods()
        precondition(calls.filter { $0 == "lookup" }.count == 1 && !calls.contains("finalizeSubmission"))
        try await eventSocket.emit(update(sequence: 1, field: "name", value: .string("Updated")))
        try await Task.sleep(nanoseconds: 100_000_000)
        calls = await eventSocket.methods()
        precondition(calls.filter { $0 == "lookup" }.count == 2 && !calls.contains("submit"))
        await eventClient.disconnect()
        let reconnectedSocket = FakeSocket(snapshot: snapshot)
        let reconnectedClient = CFLChatClient(target: "test-target", store: eventStore, transport: { reconnectedSocket })
        await reconnectedClient.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        calls = await reconnectedSocket.methods()
        precondition(calls.filter { $0 == "lookup" }.count == 1 && !calls.contains("submit"))
        await reconnectedClient.disconnect()
        let concurrentStore = MemoryStore()
        try await concurrentStore.save([eventEntry])
        let concurrentSocket = FakeSocket(snapshot: snapshot, holdLookup: true)
        let concurrentClient = CFLChatClient(target: "test-target", store: concurrentStore, transport: { concurrentSocket })
        await concurrentClient.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await concurrentSocket.emit(update(sequence: 1, field: "name", value: .string("Changed")))
        try await Task.sleep(nanoseconds: 100_000_000)
        calls = await concurrentSocket.methods()
        precondition(calls.filter { $0 == "lookup" }.count == 1)
        try await concurrentSocket.releaseLookup()
        await concurrentClient.disconnect()
        let deadlineStore = MemoryStore()
        let deadlineEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "66666666-6666-4666-8666-666666666666", text: "deadline", createdAt: Date(timeIntervalSinceNow: -59.5), dispatched: true, status: .unknown)
        try await deadlineStore.save([deadlineEntry])
        let deadlineSocket = FakeSocket(snapshot: snapshot)
        let deadlineClient = CFLChatClient(target: "test-target", store: deadlineStore, transport: { deadlineSocket })
        await deadlineClient.connect()
        try await Task.sleep(nanoseconds: 800_000_000)
        calls = await deadlineSocket.methods()
        precondition(calls.filter { $0 == "lookup" }.count == 1 && calls.filter { $0 == "finalizeSubmission" }.count == 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        calls = await deadlineSocket.methods()
        precondition(calls.filter { $0 == "finalizeSubmission" }.count == 1 && !calls.contains("submit"))
        await deadlineClient.disconnect()
        let switchStore = MemoryStore()
        let switchEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "77777777-7777-4777-8777-777777777777", text: "switch", createdAt: Date(timeIntervalSinceNow: -59.5), dispatched: true, status: .unknown)
        try await switchStore.save([switchEntry])
        let lateReceipt: ChordJSON = .object(["operationId": .string(switchEntry.operationId), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])
        let switchSocket = FakeSocket(snapshot: snapshot, lookupReceipt: lateReceipt, holdLookup: true)
        let switchClient = CFLChatClient(target: "test-target", store: switchStore, transport: { switchSocket })
        await switchClient.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        try await switchSocket.emit(update(sequence: 1, field: "sessionId", value: .string("new-session")))
        try await Task.sleep(nanoseconds: 100_000_000)
        try await switchSocket.releaseLookup()
        try await Task.sleep(nanoseconds: 800_000_000)
        calls = await switchSocket.methods()
        precondition(!calls.contains("finalizeSubmission") && !calls.contains("submit"))
        let afterSwitch = try await switchStore.load()
        precondition(afterSwitch[0].status == .unknown)
        await switchClient.disconnect()
        let disconnectStore = MemoryStore()
        let disconnectEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "88888888-8888-4888-8888-888888888888", text: "disconnect", createdAt: Date(timeIntervalSinceNow: -59.5), dispatched: true, status: .unknown)
        try await disconnectStore.save([disconnectEntry])
        let disconnectSocket = FakeSocket(snapshot: snapshot)
        let disconnectClient = CFLChatClient(target: "test-target", store: disconnectStore, transport: { disconnectSocket })
        await disconnectClient.connect()
        await disconnectClient.disconnect()
        try await Task.sleep(nanoseconds: 800_000_000)
        calls = await disconnectSocket.methods()
        precondition(!calls.contains("finalizeSubmission") && !calls.contains("submit"))
        let failingStore = MemoryStore(); let third = FakeSocket(snapshot: snapshot)
        let blocked = CFLChatClient(target: "test-target", store: failingStore, transport: { third })
        await blocked.connect(); await failingStore.setFail()
        do { try await blocked.send("not dispatched"); preconditionFailure("failed store") } catch {}
        let blockedMethods = await third.methods(); precondition(!blockedMethods.contains("submit"))
        await blocked.disconnect()
        let errorStore = MemoryStore(); let errorSocket = FakeSocket(snapshot: snapshot)
        let errorClient = CFLChatClient(target: "test-target", store: errorStore, transport: { errorSocket })
        await errorClient.connect()
        await errorStore.injectSaveFailure(2, afterCommit: false)
        _ = try await errorClient.send("recover storage")
        let failedState = await errorClient.currentState(); precondition(failedState.error == .storage)
        try await errorClient.reconcile()
        let recoveredState = await errorClient.currentState(); precondition(recoveredState.error == nil)
        await errorClient.disconnect()
        let raceStore = MemoryStore(); let raceSocket = FakeSocket(snapshot: snapshot, holdLookup: true)
        let raceClient = CFLChatClient(target: "test-target", store: raceStore, transport: { raceSocket })
        await raceClient.connect()
        await raceStore.injectSaveFailure(2, afterCommit: true)
        _ = try await raceClient.send("pending lookup")
        let checking = Task { try await raceClient.reconcile() }
        for _ in 0..<100 {
            if await raceSocket.methods().contains("lookup") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await raceStore.injectSaveFailure(3, afterCommit: false)
        do { try await raceClient.send("new failure"); preconditionFailure("new failure missing") } catch CFLFailure.storage { }
        try await raceSocket.releaseLookup()
        try await checking.value
        let raceState = await raceClient.currentState(); precondition(raceState.error == .storage)
        await raceClient.disconnect()
        let retirementStore = MemoryStore()
        let submittedEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "retire", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        let unknownEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "unknown", text: "text", createdAt: Date(), dispatched: true, status: .unknown)
        let failedEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "failed", text: "text", createdAt: Date(), dispatched: true, status: .failed)
        let otherTarget = CFLPending(target: "other-target", sessionId: "fixture-session", operationId: "retire", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        let otherSession = CFLPending(target: "test-target", sessionId: "other-session", operationId: "retire", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        let agentOnly = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "agent-only", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        try await retirementStore.save([submittedEntry, unknownEntry, failedEntry, otherTarget, otherSession, agentOnly])
        let retirementSocket = FakeSocket(snapshot: snapshot)
        let retirementClient = CFLChatClient(target: "test-target", store: retirementStore, transport: { retirementSocket })
        await retirementClient.connect()
        let beforeEvidence = try await retirementStore.load(); precondition(beforeEvidence.count == 6)
        await retirementStore.injectSaveFailure(2, afterCommit: false)
        try await retirementSocket.emit(update(sequence: 1, field: "messages", value: .array([
            message(operation: "retire"), message(operation: "unknown"), message(operation: "failed"), message(operation: "agent-only", role: "agent"),
        ])))
        for _ in 0..<100 {
            if await retirementClient.currentState().error == .storage { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let afterFailedRetirement = try await retirementStore.load(); precondition(afterFailedRetirement.count == 6)
        try await retirementSocket.emit(update(sequence: 2, field: "name", value: .string("retry")))
        for _ in 0..<100 {
            if try await retirementStore.load().count == 5 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retained = try await retirementStore.load()
        precondition(retained.count == 5 && !retained.contains(submittedEntry))
        precondition(retained.contains(unknownEntry) && retained.contains(failedEntry) && retained.contains(otherTarget) && retained.contains(otherSession) && retained.contains(agentOnly))
        await retirementClient.disconnect()
        let lateStore = MemoryStore()
        let lateEntry = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "late-receipt", text: "text", createdAt: Date(), dispatched: true, status: .unknown)
        try await lateStore.save([lateEntry])
        let lateResult: ChordJSON = .object(["operationId": .string(lateEntry.operationId), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])
        let lateSocket = FakeSocket(snapshot: snapshot, lookupReceipt: lateResult, holdLookup: true)
        let lateClient = CFLChatClient(target: "test-target", store: lateStore, transport: { lateSocket })
        await lateClient.connect()
        for _ in 0..<100 {
            if await lateSocket.methods().contains("lookup") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await lateSocket.emit(update(sequence: 1, field: "messages", value: .array([message(operation: lateEntry.operationId)])))
        for _ in 0..<100 {
            if await lateClient.currentState().messages.contains(where: { $0.operationId == lateEntry.operationId }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let beforeReceipt = try await lateStore.load(); precondition(beforeReceipt == [lateEntry])
        try await lateSocket.releaseLookup()
        for _ in 0..<100 {
            if try await lateStore.load().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let afterReceipt = try await lateStore.load(); precondition(afterReceipt.isEmpty)
        let retirementMethods = await lateSocket.methods(); precondition(!retirementMethods.contains("submit"))
        await lateClient.disconnect()
        let concurrentRetireStore = MemoryStore()
        let firstRetire = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "first-retire", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        let secondRetire = CFLPending(target: "test-target", sessionId: "fixture-session", operationId: "second-retire", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
        try await concurrentRetireStore.save([firstRetire, secondRetire])
        let concurrentRetireSocket = FakeSocket(snapshot: snapshot)
        let concurrentRetireClient = CFLChatClient(target: "test-target", store: concurrentRetireStore, transport: { concurrentRetireSocket })
        await concurrentRetireClient.connect()
        await concurrentRetireStore.pauseNextSave()
        try await concurrentRetireSocket.emit(update(sequence: 1, field: "messages", value: .array([message(operation: firstRetire.operationId)])))
        for _ in 0..<100 {
            if await concurrentRetireStore.saveIsPaused() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let savePaused = await concurrentRetireStore.saveIsPaused(); precondition(savePaused)
        try await concurrentRetireSocket.emit(update(sequence: 2, field: "messages", value: .array([message(operation: firstRetire.operationId), message(operation: secondRetire.operationId)])))
        for _ in 0..<100 {
            if await concurrentRetireClient.currentState().messages.contains(where: { $0.operationId == secondRetire.operationId }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await concurrentRetireStore.resumeSave()
        for _ in 0..<100 {
            if try await concurrentRetireStore.load().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let concurrentRetained = try await concurrentRetireStore.load(); precondition(concurrentRetained.isEmpty)
        await concurrentRetireClient.disconnect()
        let drainStore = MemoryStore()
        let drainFirst = CFLPending(target: "old-target", sessionId: "fixture-session", operationId: "drain-first", text: "first", createdAt: Date(), dispatched: true, status: .submitted)
        let drainSecond = CFLPending(target: "old-target", sessionId: "fixture-session", operationId: "drain-second", text: "second", createdAt: Date(), dispatched: true, status: .submitted)
        try await drainStore.save([drainFirst, drainSecond])
        let drainSocket = FakeSocket(snapshot: snapshot)
        let oldClient = CFLChatClient(target: "old-target", store: drainStore, transport: { drainSocket })
        await oldClient.connect()
        await drainStore.pauseNextSave()
        try await drainSocket.emit(update(sequence: 1, field: "messages", value: .array([message(operation: drainFirst.operationId)])))
        for _ in 0..<100 {
            if await drainStore.saveIsPaused() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let retirementPaused = await drainStore.saveIsPaused(); precondition(retirementPaused)
        try await drainSocket.emit(update(sequence: 2, field: "messages", value: .array([message(operation: drainFirst.operationId), message(operation: drainSecond.operationId)])))
        for _ in 0..<100 {
            if await oldClient.currentState().messages.contains(where: { $0.operationId == drainSecond.operationId }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let disconnected = CompletionFlag()
        let disconnectTask = Task { await oldClient.disconnect(); await disconnected.complete() }
        for _ in 0..<100 {
            if await oldClient.currentState().connection == .offline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let returnedWhileWriting = await disconnected.isComplete(); precondition(!returnedWhileWriting)
        await drainStore.resumeSave()
        await disconnectTask.value
        let replacementSocket = FakeSocket(snapshot: snapshot)
        let replacement = CFLChatClient(target: "new-target", store: drainStore, transport: { replacementSocket })
        await replacement.connect()
        let replacementID = try await replacement.send("replacement input")
        let afterReplacement = try await drainStore.load()
        precondition(afterReplacement.contains(drainSecond) && !afterReplacement.contains(drainFirst))
        precondition(afterReplacement.contains(where: { $0.target == "new-target" && $0.operationId == replacementID && $0.text == "replacement input" }))
        do { try await oldClient.dismissPending(sessionId: "fixture-session", operationId: drainSecond.operationId); preconditionFailure("disconnected client wrote") } catch CFLFailure.offline { }
        await replacement.disconnect()
        let receiptDrainStore = MemoryStore()
        let receiptDrainEntry = CFLPending(target: "old-target", sessionId: "fixture-session", operationId: "drain-receipt", text: "original", createdAt: Date(), dispatched: true, status: .unknown)
        try await receiptDrainStore.save([receiptDrainEntry]); await receiptDrainStore.pauseNextSave()
        let drainReceipt: ChordJSON = .object(["operationId": .string(receiptDrainEntry.operationId), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])
        let receiptSocket = FakeSocket(snapshot: snapshot, lookupReceipt: drainReceipt)
        let receiptClient = CFLChatClient(target: "old-target", store: receiptDrainStore, transport: { receiptSocket })
        await receiptClient.connect()
        for _ in 0..<100 {
            if await receiptDrainStore.saveIsPaused() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let receiptPaused = await receiptDrainStore.saveIsPaused(); precondition(receiptPaused)
        let receiptDisconnected = CompletionFlag()
        let receiptDisconnectTask = Task { await receiptClient.disconnect(); await receiptDisconnected.complete() }
        for _ in 0..<100 {
            if await receiptClient.currentState().connection == .offline { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let receiptReturnedWhileWriting = await receiptDisconnected.isComplete(); precondition(!receiptReturnedWhileWriting)
        await receiptDrainStore.resumeSave()
        await receiptDisconnectTask.value
        let savedReceipt = try await receiptDrainStore.load()
        precondition(savedReceipt.count == 1 && savedReceipt[0].operationId == receiptDrainEntry.operationId && savedReceipt[0].status == .submitted)
        for afterCommit in [false, true] {
            let firstSaveStore = MemoryStore(); let socket = FakeSocket(snapshot: snapshot)
            let firstSaveClient = CFLChatClient(target: "test-target", store: firstSaveStore, transport: { socket })
            await firstSaveClient.connect()
            await firstSaveStore.injectSaveFailure(1, afterCommit: afterCommit)
            if afterCommit {
                let id = try await firstSaveClient.send("first save")
                let saved = try await firstSaveStore.load()
                precondition(saved.count == 1 && saved[0].operationId == id && saved[0].text == "first save" && !saved[0].dispatched)
                await firstSaveClient.disconnect()
                let restoredSocket = FakeSocket(snapshot: snapshot)
                let restoredClient = CFLChatClient(target: "test-target", store: firstSaveStore, transport: { restoredSocket })
                await restoredClient.connect()
                let restoredState = await restoredClient.currentState()
                precondition(restoredState.pending.first?.operationId == id && restoredState.pending.first?.text == "first save")
                try await restoredClient.dismissPending(sessionId: "fixture-session", operationId: id)
                let remaining = try await firstSaveStore.load(); precondition(remaining.isEmpty)
                let restoredMethods = await restoredSocket.methods()
                precondition(!restoredMethods.contains("submit") && !restoredMethods.contains("lookup") && !restoredMethods.contains("finalizeSubmission"))
                await restoredClient.disconnect()
            } else {
                do { try await firstSaveClient.send("first save"); preconditionFailure("first save should fail") } catch CFLFailure.storage { }
                let saved = try await firstSaveStore.load(); precondition(saved.isEmpty)
            }
            let methods = await socket.methods(); precondition(!methods.contains("submit"))
            await firstSaveClient.disconnect()
        }
        for committed in [false, true] {
        let uncertainStore = MemoryStore(); let uncertainSocket = FakeSocket(snapshot: snapshot)
        let uncertainClient = CFLChatClient(target: "test-target", store: uncertainStore, transport: { uncertainSocket })
        await uncertainClient.connect()
        await uncertainStore.injectSaveFailure(1, afterCommit: committed, unreadable: true)
        var uncertainID = ""
        do { try await uncertainClient.send("preserve original"); preconditionFailure("unreadable save") }
        catch let error as CFLPendingStorageUncertain {
            uncertainID = error.pending.operationId
            precondition(error.pending.text == "preserve original" && error.pending.sessionId == "fixture-session" && !error.pending.dispatched)
        }
        do { try await uncertainClient.send("do not overwrite"); preconditionFailure("unreadable store") } catch CFLFailure.storage { }
        await uncertainStore.restoreReads()
        try await uncertainClient.reconcile()
        let recoveredUncertain = await uncertainClient.currentState()
        precondition(recoveredUncertain.pending.count == (committed ? 1 : 0))
        if committed { precondition(recoveredUncertain.pending[0].operationId == uncertainID) }
        try await uncertainClient.dismissPending(sessionId: "fixture-session", operationId: uncertainID)
        let uncertainMethods = await uncertainSocket.methods(); precondition(!uncertainMethods.contains("submit") && !uncertainMethods.contains("lookup"))
        await uncertainClient.disconnect()
        }
        for afterCommit in [false, true] {
            let secondSaveStore = MemoryStore(); let socket = FakeSocket(snapshot: snapshot)
            let secondSaveClient = CFLChatClient(target: "test-target", store: secondSaveStore, transport: { socket })
            await secondSaveClient.connect()
            await secondSaveStore.injectSaveFailure(2, afterCommit: afterCommit)
            let id = try await secondSaveClient.send("second save")
            let saved = try await secondSaveStore.load()
            precondition(saved.count == 1 && saved[0].operationId == id && saved[0].text == "second save" && saved[0].dispatched == afterCommit)
            try await secondSaveClient.dismissPending(sessionId: "fixture-session", operationId: id)
            let remaining = try await secondSaveStore.load(); precondition(remaining.count == (afterCommit ? 1 : 0))
            let methods = await socket.methods(); precondition(!methods.contains("submit"))
            await secondSaveClient.disconnect()
        }
        let unreadableStore = MemoryStore(); let unreadableSocket = FakeSocket(snapshot: snapshot)
        let unreadableClient = CFLChatClient(target: "test-target", store: unreadableStore, transport: { unreadableSocket })
        await unreadableClient.connect()
        await unreadableStore.injectSaveFailure(2, afterCommit: true, unreadable: true)
        let unreadableID = try await unreadableClient.send("unreadable marker")
        let unreadableState = await unreadableClient.currentState()
        precondition(unreadableState.pending.first?.operationId == unreadableID && unreadableState.pending.first?.dispatched == true)
        do { try await unreadableClient.dismissPending(sessionId: "fixture-session", operationId: unreadableID); preconditionFailure("unreadable store") } catch CFLFailure.storage { }
        await unreadableStore.restoreReads()
        try await unreadableClient.dismissPending(sessionId: "fixture-session", operationId: unreadableID)
        let unreadableSaved = try await unreadableStore.load(); precondition(unreadableSaved.count == 1 && unreadableSaved[0].dispatched)
        let unreadableMethods = await unreadableSocket.methods(); precondition(!unreadableMethods.contains("submit"))
        await unreadableClient.disconnect()
        print("CFL Chord fixture and pending recovery checks passed")
    }
}
