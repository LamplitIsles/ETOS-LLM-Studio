import Foundation
import Dispatch
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
    func failNextSave(afterCommit: Bool) { failSaveNumber = saveCount + 1; commitBeforeFailure = afterCommit }
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
    var receiveError: CFLFailure = .offline
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
    let earlyFrames: [ChordJSON]
    init(snapshot: ChordJSON, dropSubmit: Bool = false, lookupReceipt: ChordJSON = .null, earlyUpdate: ChordJSON? = nil, holdLookup: Bool = false, earlyFrames: [ChordJSON] = []) {
        self.snapshot = snapshot; self.dropSubmit = dropSubmit; self.lookupReceipt = lookupReceipt; self.earlyUpdate = earlyUpdate; self.holdLookup = holdLookup; self.earlyFrames = earlyFrames
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
            for frame in earlyFrames { enqueue(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)) }
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
        if closed { throw receiveError }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: CFLFailure.offline); waiter = nil }
    func failReceive(_ error: CFLFailure) {
        receiveError = error; closed = true; waiter?.resume(throwing: error); waiter = nil
    }
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
    func releaseSubmit() throws {
        guard let id = heldSubmitID, let operation = sent.last(where: { $0.0 == "submit" })?.1.first?.object?["operationId"] else { throw CFLFailure.protocolError }
        heldSubmitID = nil; holdSubmit = false
        let receipt: ChordJSON = .object(["operationId": operation, "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])
        try emit(.object(["type": .string("result"), "id": .string(id), "result": receipt]))
    }
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

func historySnapshot(_ range: Range<Int>, before: String?, session: String = "fixture-session", messages: [ChordJSON]? = nil, preview: ChordJSON? = nil) -> ChordJSON {
    var fields: [String: ChordJSON] = [
        "version": .number(2), "sessionId": .string(session), "name": .string("Mica"), "activeTurnId": .null,
        "contextUsage": .null, "compaction": .null, "recovery": .array([]),
        "capabilities": .object(["text": .bool(true), "stop": .bool(true)]),
        "messages": .array(messages ?? range.map(historyMessage)), "before": before.map(ChordJSON.string) ?? .null,
    ]
    if let preview { fields["streamingReply"] = preview }
    let view: ChordJSON = .object(fields)
    return .object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"), "instances": .array([
        .object(["members": .array([.object(["name": .string("view"), "kind": .string("state"), "sequence": .number(0),
            "ops": .array([.array([.string("r"), view])])])])])
    ])])
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

func checkViewItemAndWindowContinuity() async throws {
    func waitForName(_ client: CFLChatClient, _ name: String) async throws -> CFLChatState {
        for _ in 0..<200 {
            let state = await client.currentState()
            if state.name == name { return state }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CFLFailure.requestFailed
    }
    var state: CFLChatState
    func text(_ id: String, _ value: String, _ status: String) -> ChordJSON {
        .object(["id": .string(id), "role": .string("agent"), "text": .string(value), "createdAt": .number(1),
                 "operationId": .null, "turnId": .string("turn"), "textState": .string(status),
                 "ends": .array(value.isEmpty ? [] : [.number(Double(value.utf16.count))])])
    }
    let a = text("a", "one", "complete"), b = text("b", "two", "streaming")
    let windowSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, messages: [a, b]))
    let window = CFLChatClient(target: "history", store: MemoryStore(), transport: { windowSocket })
    await window.connect()
    try await windowSocket.emit(update(sequence: 1, field: "messages", value: .array([a])))
    try await windowSocket.emit(update(sequence: 2, field: "name", value: .string("tail absent")))
    state = try await waitForName(window, "tail absent")
    precondition(state.messages.map(\.id) == ["a", "b"] && state.messages.last?.text == "two")
    let completeB = text("b", "two complete", "complete")
    try await windowSocket.emit(update(sequence: 3, field: "messages", value: .array([a, completeB])))
    try await windowSocket.emit(update(sequence: 4, field: "name", value: .string("tail restored")))
    state = try await waitForName(window, "tail restored")
    precondition(state.messages.map(\.id) == ["a", "b"] && state.messages.last?.text == "two complete" && state.messages.last?.textState == .complete)
    let c = text("c", "three", "complete")
    try await windowSocket.emit(update(sequence: 5, field: "messages", value: .array([completeB, c])))
    try await windowSocket.emit(update(sequence: 6, field: "name", value: .string("prefix slid")))
    state = try await waitForName(window, "prefix slid")
    precondition(state.messages.map(\.id) == ["a", "b", "c"])
    try await windowSocket.emit(update(sequence: 7, field: "messages", value: .array([c, completeB])))
    try await windowSocket.emit(update(sequence: 8, field: "name", value: .string("view reordered")))
    state = try await waitForName(window, "view reordered")
    precondition(state.messages.map(\.id) == ["a", "c", "b"])
    await window.disconnect()

    // Loaded history stays in place through a temporary omission and a real
    // prefix slide; the server's new cursor supplies the intervening page.
    let historySocket = FakeSocket(snapshot: historySnapshot(2..<4, before: "c2"))
    await historySocket.setHistory(["c2": historyPage(0..<2, before: nil), "c3": historyPage(0..<3, before: nil)])
    let history = CFLChatClient(target: "history", store: MemoryStore(), transport: { historySocket })
    await history.connect(); try await history.loadEarlier()
    try await historySocket.emit(update(sequence: 1, field: "messages", value: .array([historyMessage(2)])))
    try await historySocket.emit(update(sequence: 2, field: "name", value: .string("history tail absent")))
    state = try await waitForName(history, "history tail absent")
    precondition(state.messages.map(\.id) == (0..<4).map { "server-\($0)" })
    let slide: ChordJSON = .object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
        "type": .string("state"), "member": .string("view"), "sequence": .number(3),
        "ops": .array([.array([.string("s"), .array([.string("messages")]), .array([historyMessage(3), historyMessage(4)])]),
                       .array([.string("s"), .array([.string("before")]), .string("c3")])])])])
    try await historySocket.emit(slide)
    try await historySocket.emit(update(sequence: 4, field: "name", value: .string("history slid")))
    state = try await waitForName(history, "history slid")
    precondition(state.messages.map(\.id) == (0..<5).map { "server-\($0)" })
    await history.disconnect()
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
    // An in-flight history read is fenced by the session even with no item channel.
    let socket = FakeSocket(snapshot: historySnapshot(30..<60, before: "c30"))
    await socket.setHistory(["c30": historyPage(0..<30, before: nil)], hold: true)
    let client = CFLChatClient(target: "history", store: MemoryStore(), transport: { socket })
    await client.connect()
    let loading = Task { try await client.loadEarlier() }
    for _ in 0..<200 { if await socket.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let held = await socket.historyIsHeld(); precondition(held)
    try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("new-session")))
    for _ in 0..<200 { if await client.currentState().sessionId == "new-session" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await socket.releaseHistory()
    do { try await loading.value; preconditionFailure("old session page accepted") } catch CFLFailure.sessionChanged { }
    let current = await client.currentState()
    precondition(current.sessionId == "new-session" && current.messages.count == 30 && current.before == "c30")
    await client.disconnect()

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

func checkReplySourceContract() async throws {
    let rawText = "😀\nline\npartial"
    let preview: ChordJSON = .object(["id": .string("source-1"), "turnId": .string("turn"), "createdAt": .number(1),
                                      "text": .string(rawText), "ends": .array([.number(3), .number(8)])])
    func reply(_ id: String, _ text: String, _ ends: ChordJSON) -> ChordJSON {
        .object(["id": .string(id), "role": .string("agent"), "text": .string(text), "ends": ends,
                 "createdAt": .number(1), "operationId": .null, "turnId": .string("turn")])
    }
    let old = reply("older-reply", "first\n```\nx\n```\n", .array([.number(6), .number(16)]))
    let socket = FakeSocket(snapshot: historySnapshot(0..<0, before: "older", messages: [historyMessage(1), imageSlot("image-1", state: "ready")], preview: preview))
    await socket.setHistory(["older": .object(["messages": .array([old]), "before": .null])])
    let client = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { socket })
    await client.connect()
    var state = await client.currentState()
    precondition(state.connection == .online && state.streamingReply?.id == "source-1" && state.streamingReply?.text == rawText)
    let previewParts = try CFLReplySegments.texts(rawText, ends: state.streamingReply!.ends!)
    precondition(previewParts == ["😀\n", "line\n"])
    try await client.loadEarlier()
    state = await client.currentState()
    let history = state.messages.first!
    let historyParts = try CFLReplySegments.texts(history.text, ends: history.ends!)
    precondition(history.id == "older-reply" && historyParts == ["first\n", "```\nx\n```\n"])
    let complete = reply("source-1", rawText, .array([.number(3), .number(8), .number(15)]))
    let finalUpdate: ChordJSON = .object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
        "type": .string("state"), "member": .string("view"), "sequence": .number(1), "ops": .array([
            .array([.string("s"), .array([.string("messages")]), .array([historyMessage(1), imageSlot("image-1", state: "ready"), complete])]),
            .array([.string("d"), .array([.string("streamingReply")])])])])])
    try await socket.emit(finalUpdate)
    for _ in 0..<200 { if await client.currentState().messages.last?.id == "source-1" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    state = await client.currentState()
    let completed = state.messages.last!
    let completedParts = try CFLReplySegments.texts(completed.text, ends: completed.ends!)
    precondition(state.streamingReply == nil && completed.id == "source-1" && completedParts == ["😀\n", "line\n", "partial"])
    try await socket.emit(update(sequence: 2, field: "messages", value: .array([historyMessage(1), imageSlot("image-1", state: "failed"), complete])))
    for _ in 0..<200 { if await client.currentState().messages.first(where: { $0.id == "image-1" })?.imageState == .failed { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    state = await client.currentState()
    precondition(state.messages.first(where: { $0.id == "image-1" })?.imageState == .failed && state.messages.last?.id == "source-1")
    await client.disconnect()

    // Contract requires ends on ordinary replies and previews, including an empty array.
    var missing = reply("bad", rawText, .array([])).object!; missing.removeValue(forKey: "ends")
    let invalidEnds: [ChordJSON] = [.array([.number(1)]), .array([.number(3), .number(3)]),
                                     .array([.number(0)]), .array([.number(99)]), .array([.number(2.5)]), .null]
    for bad in [ChordJSON.object(missing)] + invalidEnds.map({ reply("bad", rawText, $0) }) {
        let badSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, messages: [bad]))
        let badClient = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { badSocket })
        await badClient.connect(); let badState = await badClient.currentState()
        precondition(badState.connection == .protocolError)
        await badClient.disconnect()
    }
    var badPreview = preview.object!; badPreview["ends"] = .array([.number(1)])
    let previewSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, preview: .object(badPreview)))
    let previewClient = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { previewSocket })
    await previewClient.connect(); let invalidPreview = await previewClient.currentState()
    precondition(invalidPreview.connection == .protocolError)
    await previewClient.disconnect()
    let historySocket = FakeSocket(snapshot: historySnapshot(0..<1, before: "bad"))
    await historySocket.setHistory(["bad": .object(["messages": .array([reply("bad", rawText, .array([.number(1)]))]), "before": .null])])
    let historyClient = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { historySocket })
    await historyClient.connect()
    do { try await historyClient.loadEarlier(); preconditionFailure("invalid history ends accepted") } catch CFLFailure.protocolError { }
    let afterBadPage = await historyClient.currentState()
    precondition(afterBadPage.messages.count == 1 && afterBadPage.before == "bad")
    await historyClient.disconnect()

    // The retired independent channel is not accepted as a second source of truth.
    let legacySocket = FakeSocket(snapshot: historySnapshot(0..<1, before: nil))
    let legacy = CFLChatClient(target: "fixture", store: MemoryStore(), transport: { legacySocket })
    await legacy.connect()
    try await legacySocket.emit(.object(["type": .string("timeline"), "sessionId": .string("fixture-session"),
                                         "change": .object(["type": .string("structure")])]))
    for _ in 0..<200 { if await legacy.currentState().connection == .protocolError { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let legacyState = await legacy.currentState(); precondition(legacyState.connection == .protocolError)
    await legacy.disconnect()
}

func checkHistoryWindows() async throws {
    let old = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let middle = FakeSocket(snapshot: historySnapshot(70..<100, before: "c70"))
    let fresh = FakeSocket(snapshot: historySnapshot(140..<170, before: "c140"))
    await fresh.setHistory([
        "c70": historyPage(40..<70, before: "c40"),
        "c40": historyPage(10..<40, before: "c10"),
        "c140": historyPage(110..<140, before: "c110"),
        "c110": historyPage(80..<110, before: "c80"),
    ])
    let sockets = SocketSequence([old, middle, fresh])
    let client = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await sockets.next() })
    await client.connect(); await client.disconnect(); await client.connect()
    var state = await client.currentState()
    precondition(state.historyGaps.count == 1 && state.historyGaps[0].afterId == "server-29" && state.historyGaps[0].beforeId == "server-70")
    let first = state.historyGaps[0].id
    await client.disconnect(); await client.connect()
    state = await client.currentState()
    precondition(state.historyGaps.count == 2 && state.historyGaps[1].afterId == "server-99" && state.historyGaps[1].beforeId == "server-140")
    let second = state.historyGaps[1].id
    let initialCalls = await fresh.arguments(for: "history"); precondition(initialCalls.isEmpty)
    await client.fillGap(id: first)
    state = await client.currentState()
    precondition(state.historyGaps.count == 2 && state.historyGaps[0].beforeId == "server-40" && state.historyGaps[0].status == .pending)
    let firstCalls = await fresh.arguments(for: "history"); precondition(firstCalls == [[.string("c70")]])
    await client.fillGap(id: first)
    state = await client.currentState()
    precondition(state.historyGaps.map(\.id) == [second] && state.messages.prefix(100).map(\.id) == (0..<100).map { "server-\($0)" })
    await client.fillGap(id: second); await client.fillGap(id: second)
    state = await client.currentState()
    precondition(state.historyGaps.isEmpty && state.messages.map(\.id) == (0..<170).map { "server-\($0)" } && state.before == nil)
    let methods = await fresh.methods(); precondition(!methods.contains("submit"))
    await client.disconnect()

    // Ordinary sliding overlap does not make a gap or fetch history on reconnect.
    let one = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let two = FakeSocket(snapshot: historySnapshot(20..<50, before: "c20"))
    let overlapSockets = SocketSequence([one, two])
    let overlap = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await overlapSockets.next() })
    await overlap.connect(); await overlap.disconnect(); await overlap.connect()
    let overlapping = await overlap.currentState(), overlapCalls = await two.arguments(for: "history")
    precondition(overlapping.historyGaps.isEmpty && overlapping.messages.count == 50 && overlapCalls.isEmpty)
    await overlap.disconnect()

    // An empty intermediate view must not erase the retained source window.
    let emptyOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let emptyMiddle = FakeSocket(snapshot: historySnapshot(0..<0, before: "empty"))
    let emptyNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "c70"))
    let emptySockets = SocketSequence([emptyOld, emptyMiddle, emptyNew])
    let empty = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await emptySockets.next() })
    await empty.connect(); await empty.disconnect(); await empty.connect()
    let emptyState = await empty.currentState(); precondition(emptyState.messages.count == 30 && emptyState.before == nil)
    await empty.disconnect(); await empty.connect()
    let afterEmpty = await empty.currentState()
    precondition(afterEmpty.historyGaps.count == 1 && afterEmpty.historyGaps[0].afterId == "server-29" && afterEmpty.historyGaps[0].beforeId == "server-70")
    await empty.disconnect()

    // A locally submitted source remains ineligible after its pending record is retired.
    let pendingStore = MemoryStore()
    let pending = CFLPending(target: "history", sessionId: "fixture-session", operationId: "q", text: "text", createdAt: Date(), dispatched: true, status: .submitted)
    await pendingStore.setEntries([pending])
    let q = message(operation: "q")
    let pendingOld = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, messages: (0..<29).map(historyMessage) + [q]))
    let pendingNew = FakeSocket(snapshot: historySnapshot(0..<0, before: "c70", messages: (70..<99).map(historyMessage) + [q]))
    let pendingSockets = SocketSequence([pendingOld, pendingNew])
    let pendingClient = CFLChatClient(target: "history", store: pendingStore, transport: { try await pendingSockets.next() })
    await pendingClient.connect()
    for _ in 0..<200 { if try await pendingStore.load().isEmpty { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let retired = try await pendingStore.load(); precondition(retired.isEmpty)
    await pendingClient.disconnect(); await pendingClient.connect()
    state = await pendingClient.currentState()
    precondition(state.historyGaps.count == 1 && state.historyGaps[0].afterId == "server-28" && state.historyGaps[0].beforeId == "server-70")
    let pendingMethods = await pendingNew.methods(); precondition(!pendingMethods.contains("submit"))
    await pendingClient.disconnect()

    // Error is specific to the gap; an explicit retry performs one more read.
    let badOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let badNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "bad"))
    await badNew.setHistory(["bad": .object(["messages": .array([])])])
    let badSockets = SocketSequence([badOld, badNew])
    let retry = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await badSockets.next() })
    await retry.connect(); await retry.disconnect(); await retry.connect()
    state = await retry.currentState(); let gap = state.historyGaps[0].id
    await retry.fillGap(id: gap)
    state = await retry.currentState(); precondition(state.historyGaps[0].status == .error && state.messages.count == 60)
    await badNew.setHistory(["bad": historyPage(40..<70, before: "next")])
    await retry.fillGap(id: gap)
    state = await retry.currentState(); precondition(state.historyGaps[0].status == .pending && state.messages.count == 90)
    await badNew.setHistory(["next": historyPage(0..<0, before: "advance"), "advance": historyPage(30..<40, before: "advance")])
    await retry.fillGap(id: gap)
    state = await retry.currentState(); precondition(state.historyGaps[0].status == .pending && state.historyGaps[0].beforeId == "server-40" && state.messages.count == 90)
    await retry.fillGap(id: gap)
    state = await retry.currentState(); precondition(state.historyGaps[0].status == .unavailable && state.messages.count == 100)
    await retry.disconnect()

    // The same gap is single-flight, and a response from the old session is discarded.
    let raceOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let raceNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "race"))
    await raceNew.setHistory(["race": historyPage(40..<70, before: "next")], hold: true)
    let raceSockets = SocketSequence([raceOld, raceNew])
    let race = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await raceSockets.next() })
    await race.connect(); await race.disconnect(); await race.connect()
    state = await race.currentState(); let raceID = state.historyGaps[0].id
    let flight = Task { await race.fillGap(id: raceID) }
    for _ in 0..<200 { if await raceNew.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await race.fillGap(id: raceID)
    let raceCalls = await raceNew.arguments(for: "history"); precondition(raceCalls.count == 1)
    try await raceNew.emit(update(sequence: 1, field: "sessionId", value: .string("other")))
    for _ in 0..<200 { if await race.currentState().sessionId == "other" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await raceNew.emit(update(sequence: 2, field: "sessionId", value: .string("fixture-session")))
    for _ in 0..<200 { if await race.currentState().sessionId == "fixture-session" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await raceNew.releaseHistory(); await flight.value
    state = await race.currentState()
    precondition(state.sessionId == "fixture-session" && state.historyGaps.isEmpty && state.messages.map(\.id) == (70..<100).map { "server-\($0)" })
    await race.disconnect()

    // Disconnect releases the old flight; it cannot mutate the same gap after reconnect.
    let connectionOld = FakeSocket(snapshot: historySnapshot(0..<30, before: nil))
    let connectionMiddle = FakeSocket(snapshot: historySnapshot(70..<100, before: "race"))
    let connectionNew = FakeSocket(snapshot: historySnapshot(70..<100, before: "race"))
    await connectionMiddle.setHistory(["race": historyPage(40..<70, before: "next")], hold: true)
    let connectionSockets = SocketSequence([connectionOld, connectionMiddle, connectionNew])
    let connection = CFLChatClient(target: "history", store: MemoryStore(), transport: { try await connectionSockets.next() })
    await connection.connect(); await connection.disconnect(); await connection.connect()
    state = await connection.currentState(); let connectionID = state.historyGaps[0].id
    let oldFlight = Task { await connection.fillGap(id: connectionID) }
    for _ in 0..<200 { if await connectionMiddle.historyIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await connection.disconnect(); await oldFlight.value; await connection.connect()
    try await connectionMiddle.releaseHistory()
    state = await connection.currentState()
    precondition(state.historyGaps.count == 1 && state.historyGaps[0].id == connectionID && state.historyGaps[0].status == .pending && state.messages.count == 60)
    let reconnectCalls = await connectionNew.arguments(for: "history"); precondition(reconnectCalls.isEmpty)
    await connection.disconnect()
}

func update(sequence: Int, field: String, value: ChordJSON) -> ChordJSON {
    .object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
        "type": .string("state"), "member": .string("view"), "sequence": .number(Double(sequence)),
        "ops": .array([.array([.string("s"), .array([.string(field)]), value])]),
    ])])
}

func message(operation: String, role: String = "user") -> ChordJSON {
    .object(["id": .string("message-\(operation)-\(role)"), "role": .string(role), "text": .string("text"),
             "createdAt": .number(1), "operationId": .string(operation), "turnId": .null,
             "ends": .array([.number(4)])])
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
    var headers: [String: String] = [:]
    var held: CheckedContinuation<Void, Never>?
    var hold = false
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { held = $0 }; hold = false }
        return (Data([1, 2, 3]), HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func last() -> URLRequest? { requests.last }
    func count() -> Int { requests.count }
    func setResponse(_ url: URL?, status: Int) { responseURL = url; self.status = status }
    func setHeaders(_ value: [String: String]) { headers = value }
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
    let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
    date.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    await fake.setHeaders(["Date": date.string(from: Date()), "Cache-Control": "max-age=3600, no-store"])
    let prohibited = try await loader.response(for: "https://example.test/private.png")
    precondition(prohibited.policy == .prohibited)
    await fake.setHeaders(["Date": date.string(from: Date()), "Cache-Control": "public, max-age=3600"])
    let allowed = try await loader.response(for: "https://example.test/public.png")
    guard case .until = allowed.policy else { preconditionFailure("explicit max-age") }
    let externalDisk = FakeMediaCache(), authority = FakeStickerHTTP(), externalSocket = FakeSocket(snapshot: imageSnapshot())
    let externalClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: authority,
                                       mediaCache: externalDisk, externalImageLoader: loader, transport: { externalSocket })
    await externalClient.connect(); let externalRevision = await externalClient.currentState().sessionRevision
    await fake.setHeaders([:])
    let ordinaryURL = "https://example.test/ordinary.png"
    let beforeOrdinary = await fake.count()
    let beforeOrdinaryPolicies = await externalDisk.expiryPolicies().count
    _ = try await externalClient.externalImage(ordinaryURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    _ = try await externalClient.externalImage(ordinaryURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    let afterOrdinary = await fake.count(); precondition(afterOrdinary == beforeOrdinary + 1)
    let ordinaryPolicies = await externalDisk.expiryPolicies()
    precondition(Array(ordinaryPolicies.dropFirst(beforeOrdinaryPolicies)) == [false, false])
    let restartSocket = FakeSocket(snapshot: imageSnapshot()), restartAuthority = FakeStickerHTTP()
    let restarted = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: restartAuthority,
                                  mediaCache: externalDisk, externalImageLoader: loader, transport: { restartSocket })
    await restarted.connect(); let restartedRevision = await restarted.currentState().sessionRevision
    _ = try await restarted.externalImage(ordinaryURL, expectedSessionId: "A", expectedSessionRevision: restartedRevision)
    let afterRestart = await fake.count(); precondition(afterRestart == afterOrdinary)
    await restarted.disconnect()
    let otherSocket = FakeSocket(snapshot: imageSnapshot()), otherAuthority = FakeStickerHTTP()
    let otherClient = CFLChatClient(target: "https://other.example", store: MemoryStore(), imageHTTP: otherAuthority,
                                    mediaCache: externalDisk, externalImageLoader: loader, transport: { otherSocket })
    await otherClient.connect(); let otherRevision = await otherClient.currentState().sessionRevision
    _ = try await otherClient.externalImage(ordinaryURL, expectedSessionId: "A", expectedSessionRevision: otherRevision)
    let afterOtherOrigin = await fake.count(); precondition(afterOtherOrigin == afterRestart + 1)
    await otherClient.disconnect()
    await fake.setHeaders(["Date": date.string(from: Date()), "Cache-Control": "public, max-age=3600"])
    let publicURL = "https://example.test/public.png"
    let beforePublic = await fake.count()
    _ = try await externalClient.externalImage(publicURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    _ = try await externalClient.externalImage(publicURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    let afterPublic = await fake.count(); precondition(afterPublic == beforePublic + 1)
    await fake.setHeaders(["Date": date.string(from: Date()), "Cache-Control": "no-store, max-age=3600"])
    let privateURL = "https://example.test/no-store.png"
    let beforePrivate = await fake.count(), beforePrivateWrites = await externalDisk.writeCount()
    _ = try await externalClient.externalImage(privateURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    _ = try await externalClient.externalImage(privateURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    let afterPrivate = await fake.count(); precondition(afterPrivate == beforePrivate + 2)
    let afterPrivateWrites = await externalDisk.writeCount(); precondition(afterPrivateWrites == beforePrivateWrites)
    let keys = await externalDisk.keys()
    precondition(!keys.contains { $0.contains(privateURL) })
    await fake.setHeaders(["Cache-Control": "no-cache"])
    let noCacheURL = "https://example.test/no-cache.png"
    let beforeNoCacheWrites = await externalDisk.writeCount()
    _ = try await externalClient.externalImage(noCacheURL, expectedSessionId: "A", expectedSessionRevision: externalRevision)
    let afterNoCacheWrites = await externalDisk.writeCount(); precondition(afterNoCacheWrites == beforeNoCacheWrites)
    let noCacheKeys = await externalDisk.keys()
    precondition(!noCacheKeys.contains { $0.contains(noCacheURL) })
    await externalClient.disconnect()
    await fake.setHeaders(["Date": date.string(from: Date()), "Cache-Control": "public, max-age=3600"])
    await fake.setResponse(URL(string: "https://other.test/redirected.png")!, status: 200)
    let redirect = try await loader.response(for: "https://example.test/image.png")
    precondition(redirect.policy == .prohibited)
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
    let goodDelegate = CFLExternalImageDelegate()
    let safeRedirect = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    goodDelegate.urlSession(session, task: task, willPerformHTTPRedirection: safeRedirect,
                            newRequest: URLRequest(url: URL(string: "https://other.test/safe.png")!)) { _ in }
    precondition(goodDelegate.cachedCopyPolicy() == .lastAccess)
    let finalResponse = HTTPURLResponse(url: URL(string: "https://other.test/safe.png")!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!
    precondition(CFLExternalImageLoader.cachePolicy(finalResponse, redirectPolicy: goodDelegate.cachedCopyPolicy()) == .lastAccess)
    for directive in ["no-store", "no-cache"] {
        let restricted = CFLExternalImageDelegate()
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Cache-Control": directive])!
        restricted.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: "https://other.test/safe.png")!)) { _ in }
        restricted.urlSession(session, task: task, willPerformHTTPRedirection: safeRedirect,
                              newRequest: URLRequest(url: URL(string: "https://other.test/final.png")!)) { _ in }
        precondition(restricted.cachedCopyPolicy() == .prohibited)
        precondition(CFLExternalImageLoader.cachePolicy(finalResponse, redirectPolicy: restricted.cachedCopyPolicy()) == .prohibited)
    }
    let limitedDelegate = CFLExternalImageDelegate()
    let limited = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil,
                                  headerFields: ["Cache-Control": "max-age=60"])!
    limitedDelegate.urlSession(session, task: task, willPerformHTTPRedirection: limited,
                               newRequest: URLRequest(url: URL(string: "https://other.test/safe.png")!)) { _ in }
    guard case .until(let deadline) = CFLExternalImageLoader.cachePolicy(finalResponse, redirectPolicy: limitedDelegate.cachedCopyPolicy()) else { preconditionFailure("redirect freshness") }
    precondition(deadline.timeIntervalSinceNow > 0 && deadline.timeIntervalSinceNow <= 60)
    print("CFL external Markdown image checks passed")
}

func imageSnapshot(before: String? = nil) -> ChordJSON {
    let limits: ChordJSON = .object(["mediaTypes": .array([.string("image/png")]), "maxImagesPerMessage": .number(2), "maxImageBytes": .number(100), "maxMessageImageBytes": .number(150)])
    let images: [ChordJSON] = (0..<7).map { .object(["attachmentId": .string("output_\($0)"), "name": .string("out.png"), "mediaType": .string("image/png"), "availability": .string($0 == 0 ? "missing" : "available")]) }
    let view: ChordJSON = .object(["version": .number(2), "sessionId": .string("A"), "name": .string("test"), "activeTurnId": .null,
        "contextUsage": .null, "compaction": .null, "recovery": .array([]), "capabilities": .object(["text": .bool(true), "stop": .bool(true), "images": limits]),
        "messages": .array([.object(["id": .string("agent"), "role": .string("agent"), "text": .string(""), "ends": .array([]), "createdAt": .number(1), "operationId": .null, "turnId": .null, "images": .array(images)])]), "before": before.map(ChordJSON.string) ?? .null])
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

    for committed in [false, true] {
        let failureStore = MemoryStore(), failureSocket = FakeSocket(snapshot: imageSnapshot())
        await failureSocket.setFailedSubmit()
        let failureClient = CFLChatClient(target: "https://example.com", store: failureStore, imageHTTP: FakeImageHTTP(), transport: { failureSocket })
        await failureClient.connect(); let failureSource = try await failureClient.send("failed", images: images)
        let failureRevision = await failureClient.currentState().sessionRevision
        await failureSocket.setRetry(hold: true, receipt: retryReceipt(attempt: "unused", source: failureSource))
        let task = Task { try await failureClient.retryFailed(sessionId: "A", operationId: failureSource, expectedSessionRevision: failureRevision) }
        for _ in 0..<200 { if await failureSocket.retryIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let retryHeld = await failureSocket.retryIsHeld(); precondition(retryHeld)
        await failureStore.failNextSave(afterCommit: committed)
        try await failureSocket.releaseRetry(); _ = try await task.value
        let afterFailure = await failureClient.currentState()
        precondition(afterFailure.localPreviews.map(\.operationId) == [failureSource, failureSource])
        precondition(afterFailure.localPreviews.map(\.attachmentId) == ["stored_0", "stored_1"])
        await failureClient.disconnect()
    }

    let persistRaceStore = MemoryStore(), persistRaceSocket = FakeSocket(snapshot: imageSnapshot())
    await persistRaceSocket.setFailedSubmit()
    let persistRace = CFLChatClient(target: "https://example.com", store: persistRaceStore, imageHTTP: FakeImageHTTP(), transport: { persistRaceSocket })
    await persistRace.connect(); let persistRaceSource = try await persistRace.send("failed", images: images)
    let persistRaceRevision = await persistRace.currentState().sessionRevision
    await persistRaceSocket.setRetry(hold: true, receipt: retryReceipt(attempt: "unused", source: persistRaceSource))
    let persistRaceTask = Task { try await persistRace.retryFailed(sessionId: "A", operationId: persistRaceSource, expectedSessionRevision: persistRaceRevision) }
    for _ in 0..<200 { if await persistRaceSocket.retryIsHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let retryHeld = await persistRaceSocket.retryIsHeld(); precondition(retryHeld)
    await persistRaceStore.pauseNextSave(); try await persistRaceSocket.releaseRetry()
    for _ in 0..<200 { if await persistRaceStore.saveIsPaused() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let saveHeld = await persistRaceStore.saveIsPaused(); precondition(saveHeld)
    try await persistRaceSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await persistRace.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await persistRaceStore.resumeSave(); _ = try await persistRaceTask.value
    let switchedDuringPersist = await persistRace.currentState()
    precondition(switchedDuringPersist.sessionId == "B" && switchedDuringPersist.localPreviews.isEmpty)
    await persistRace.disconnect()

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

func checkCallerSendIdentity() async throws {
    let operation = "12345678-1234-4234-8234-123456789abc"
    let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1]), jpeg = Data([255, 216, 255, 1])
    let image = CFLPreparedImage(id: "one", name: "same.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg)
    let socket = FakeSocket(snapshot: imageSnapshot()), http = FakeImageHTTP(), store = MemoryStore()
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
    await client.connect(); let revision = await client.currentState().sessionRevision
    do { _ = try await client.send("bad", operationId: "not-a-uuid", expectedSessionId: "A", expectedSessionRevision: revision); preconditionFailure("invalid operation") } catch CFLFailure.invalidInput { }
    await http.setHold()
    let send = Task { try await client.send("photo", images: [image], operationId: operation, expectedSessionId: "A", expectedSessionRevision: revision) }
    while !(await http.isHeld()) { await Task.yield() }
    let draft = await client.currentState().localDrafts.first
    precondition(draft?.operationId == operation && draft?.images.first?.originOperationId == operation)
    do { _ = try await client.send("duplicate", operationId: operation.uppercased(), expectedSessionId: "A", expectedSessionRevision: revision); preconditionFailure("in-flight duplicate") } catch CFLSendFailure.duplicateOperationId { }
    await http.release()
    let result = try await send.value
    let calls = await socket.arguments(for: "submit"), requests = await http.allRequests(), records = try await store.load()
    let upload = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
    precondition(result == .submitted && upload["operationId"] as? String == operation && calls.count == 1 && calls[0][0].object?["operationId"] == .string(operation))
    precondition(records.count == 1 && records[0].operationId == operation && records[0].dispatched && records[0].status == .submitted)
    do { _ = try await client.send("duplicate", operationId: operation, expectedSessionId: "A", expectedSessionRevision: revision); preconditionFailure("completed duplicate") } catch CFLSendFailure.duplicateOperationId { }
    let finalCalls = await socket.arguments(for: "submit"), finalRequests = await http.allRequests()
    precondition(finalCalls.count == 1 && finalRequests.count == 1)
    await client.disconnect()

    let observedSocket = FakeSocket(snapshot: historySnapshot(0..<0, before: nil, session: "A", messages: [message(operation: operation)]))
    let observed = CFLChatClient(target: "https://example.com", store: MemoryStore(), transport: { observedSocket })
    await observed.connect(); let observedRevision = await observed.currentState().sessionRevision
    do { _ = try await observed.send("duplicate", operationId: operation, expectedSessionId: "A", expectedSessionRevision: observedRevision); preconditionFailure("observed duplicate") } catch CFLSendFailure.duplicateOperationId { }
    let observedCalls = await observedSocket.arguments(for: "submit")
    precondition(observedCalls.isEmpty)
    await observed.disconnect()

    // A lost submit remains unknown and is looked up under the original ID.
    let lostStore = MemoryStore(), lostSocket = FakeSocket(snapshot: imageSnapshot(), dropSubmit: true), lostHTTP = FakeImageHTTP()
    let lost = CFLChatClient(target: "https://example.com", store: lostStore, imageHTTP: lostHTTP, transport: { lostSocket })
    await lost.connect(); let lostRevision = await lost.currentState().sessionRevision
    let unknown = try await lost.send("text", images: [image], operationId: operation, expectedSessionId: "A", expectedSessionRevision: lostRevision)
    let lostRecords = try await lostStore.load(), lostCalls = await lostSocket.arguments(for: "submit")
    precondition(unknown == .unknown && lostRecords.first?.operationId == operation && lostRecords.first?.dispatched == true && lostRecords.first?.images?.first?.attachmentId == "stored_0" && lostCalls.first?.first?.object?["operationId"] == .string(operation))
    await lost.disconnect()
    let receipt: ChordJSON = .object(["operationId": .string(operation), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])
    let restoredSocket = FakeSocket(snapshot: imageSnapshot(), lookupReceipt: receipt)
    let restored = CFLChatClient(target: "https://example.com", store: lostStore, transport: { restoredSocket })
    await restored.connect(); try await restored.reconcile()
    let restoredRevision = await restored.currentState().sessionRevision
    do { _ = try await restored.send("duplicate", operationId: operation, expectedSessionId: "A", expectedSessionRevision: restoredRevision); preconditionFailure("persisted duplicate") } catch CFLSendFailure.duplicateOperationId { }
    let lookups = await restoredSocket.arguments(for: "lookup"), restoredCalls = await restoredSocket.arguments(for: "submit")
    precondition(lookups.contains([.string(operation)]) && restoredCalls.isEmpty)
    await restored.disconnect()

    let failureSocket = FakeSocket(snapshot: imageSnapshot()), failureStore = MemoryStore()
    let failure = CFLChatClient(target: "https://example.com", store: failureStore, transport: { failureSocket })
    await failure.connect(); let failureRevision = await failure.currentState().sessionRevision
    await failureSocket.setFailedSubmit()
    let rejected = try await failure.send("rejected", operationId: operation, expectedSessionId: "A", expectedSessionRevision: failureRevision)
    precondition(rejected == .failed)
    await failure.disconnect()

    // A first-save error with unreadable storage is not a submitted operation.
    let uncertainSocket = FakeSocket(snapshot: imageSnapshot()), uncertainStore = MemoryStore()
    let uncertain = CFLChatClient(target: "https://example.com", store: uncertainStore, transport: { uncertainSocket })
    await uncertain.connect(); let uncertainRevision = await uncertain.currentState().sessionRevision
    await uncertainStore.injectSaveFailure(1, afterCommit: true, unreadable: true)
    do { _ = try await uncertain.send("saved?", operationId: operation, expectedSessionId: "A", expectedSessionRevision: uncertainRevision); preconditionFailure("uncertain save") }
    catch let error as CFLPendingStorageUncertain { precondition(error.pending.operationId == operation && !error.pending.dispatched) }
    let uncertainCalls = await uncertainSocket.arguments(for: "submit")
    precondition(uncertainCalls.isEmpty)
    await uncertain.disconnect()

    let saveSocket = FakeSocket(snapshot: imageSnapshot()), saveStore = MemoryStore()
    let saveClient = CFLChatClient(target: "https://example.com", store: saveStore, transport: { saveSocket })
    await saveClient.connect(); let saveRevision = await saveClient.currentState().sessionRevision
    await saveStore.injectSaveFailure(1, afterCommit: false)
    do { _ = try await saveClient.send("unsaved", operationId: operation, expectedSessionId: "A", expectedSessionRevision: saveRevision); preconditionFailure("failed save") } catch CFLFailure.storage { }
    let unsavedRecords = try await saveStore.load(), unsavedCalls = await saveSocket.arguments(for: "submit")
    precondition(unsavedRecords.isEmpty && unsavedCalls.isEmpty)
    await saveClient.disconnect()

    let uploadSocket = FakeSocket(snapshot: imageSnapshot()), uploadHTTP = FakeImageHTTP(), uploadStore = MemoryStore()
    let uploadClient = CFLChatClient(target: "https://example.com", store: uploadStore, imageHTTP: uploadHTTP, transport: { uploadSocket })
    await uploadClient.connect(); let uploadRevision = await uploadClient.currentState().sessionRevision
    await uploadHTTP.setFailure()
    do { _ = try await uploadClient.send("unsent image", images: [image], operationId: operation, expectedSessionId: "A", expectedSessionRevision: uploadRevision); preconditionFailure("failed upload") } catch CFLFailure.requestFailed { }
    let uploadRecords = try await uploadStore.load(), uploadCalls = await uploadSocket.arguments(for: "submit")
    precondition(uploadRecords.isEmpty && uploadCalls.isEmpty)
    await uploadClient.disconnect()

    let markerSocket = FakeSocket(snapshot: imageSnapshot()), markerStore = MemoryStore()
    let markerClient = CFLChatClient(target: "https://example.com", store: markerStore, transport: { markerSocket })
    await markerClient.connect(); let markerRevision = await markerClient.currentState().sessionRevision
    await markerStore.injectSaveFailure(2, afterCommit: false)
    let notDispatched = try await markerClient.send("saved before dispatch", operationId: operation, expectedSessionId: "A", expectedSessionRevision: markerRevision)
    let markerRecords = try await markerStore.load(), markerCalls = await markerSocket.arguments(for: "submit")
    precondition(notDispatched == .notDispatched && markerRecords.first?.operationId == operation && markerRecords.first?.dispatched == false && markerCalls.isEmpty)
    await markerClient.disconnect()

    let offlineSocket = FakeSocket(snapshot: imageSnapshot()), offlineStore = MemoryStore()
    let offline = CFLChatClient(target: "https://example.com", store: offlineStore, transport: { offlineSocket })
    await offline.connect(); let offlineRevision = await offline.currentState().sessionRevision
    await offlineSocket.close()
    while await offline.currentState().connection == .online { await Task.yield() }
    do { _ = try await offline.send("accepted before disconnect", operationId: operation, expectedSessionId: "A", expectedSessionRevision: offlineRevision); preconditionFailure("offline submit") } catch CFLFailure.offline { }
    let offlineRecords = try await offlineStore.load(), offlineCalls = await offlineSocket.arguments(for: "submit")
    precondition(offlineRecords.isEmpty && offlineCalls.isEmpty)
    await offline.disconnect()

    let staleSocket = FakeSocket(snapshot: imageSnapshot()), staleHTTP = FakeImageHTTP()
    let stale = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: staleHTTP, transport: { staleSocket })
    await stale.connect(); let staleRevision = await stale.currentState().sessionRevision
    await staleHTTP.setHold()
    let staleSend = Task { try await stale.send("stale", images: [image], operationId: operation, expectedSessionId: "A", expectedSessionRevision: staleRevision) }
    while !(await staleHTTP.isHeld()) { await Task.yield() }
    try await staleSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await stale.currentState().sessionId != "B" { await Task.yield() }
    await staleHTTP.release()
    do { _ = try await staleSend.value; preconditionFailure("stale upload submitted") } catch CFLFailure.sessionChanged { }
    let staleCalls = await staleSocket.arguments(for: "submit")
    precondition(staleCalls.isEmpty)
    await stale.disconnect()

    let lateSocket = FakeSocket(snapshot: imageSnapshot()), lateStore = MemoryStore()
    let late = CFLChatClient(target: "https://example.com", store: lateStore, transport: { lateSocket })
    await late.connect(); let lateRevision = await late.currentState().sessionRevision
    await lateSocket.setHoldSubmit()
    let lateSend = Task { try await late.send("late", operationId: operation, expectedSessionId: "A", expectedSessionRevision: lateRevision) }
    while !(await lateSocket.submitIsHeld()) { await Task.yield() }
    try await lateSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await late.currentState().sessionId != "B" { await Task.yield() }
    try await lateSocket.releaseSubmit()
    let lateOutcome = try await lateSend.value, lateState = await late.currentState(), lateRecords = try await lateStore.load()
    precondition(lateOutcome == .unknown && lateState.sessionId == "B" && lateState.error == nil && lateRecords.first?.sessionId == "A" && lateRecords.first?.status == .unknown && lateRecords.first?.dispatched == true)
    await late.disconnect()
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
    let historyMessage: ChordJSON = .object(["id": .string("older-agent"), "role": .string("agent"), "text": .string(""), "ends": .array([]), "createdAt": .number(0), "operationId": .null, "turnId": .null, "images": .array([historyRef])])
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

actor FakeStickerHTTP: CFLImageHTTP, CFLStickerCacheAuthority {
    let version = String(repeating: "a", count: 64)
    var requests: [URLRequest] = []
    var failStage = false
    var badStage = false
    var status = 200
    var offline = false
    var denied = false
    var scope = UUID()
    var hold = false
    var extraFavorite = false
    var favoriteRemoved = false
    var catalogHidden = false
    var catalogUnavailable = false
    var assistantFavorites: Set<String> = ["sticker_1"]
    var thumbnailData = Data([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80])
    var thumbnailETag = "\"thumb\""
    var continuation: CheckedContinuation<Void, Never>?
    var holdFavoritePage = false
    var heldFavoritePage: CheckedContinuation<Void, Never>?
    var holdPackPage = false
    var heldPackPage: CheckedContinuation<Void, Never>?
    func stickerThumbnailScope() throws -> UUID {
        if denied { throw CFLFailure.accessDenied }
        return scope
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if hold { await withCheckedContinuation { continuation = $0 }; hold = false }
        let path = request.url!.path
        if holdFavoritePage && path.hasSuffix("/favorites") && request.httpMethod == "GET" {
            holdFavoritePage = false
            await withCheckedContinuation { heldFavoritePage = $0 }
        }
        if holdPackPage && path.hasSuffix("/packs") && request.httpMethod == "GET" {
            holdPackPage = false
            await withCheckedContinuation { heldPackPage = $0 }
        }
        if offline { throw URLError(.notConnectedToInternet) }
        if path == "/api/auth/status" {
            return (Data("{\"state\":\"signed_in\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if status != 200 { return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["ETag": thumbnailETag])!) }
        if path.hasSuffix("/stage") && failStage { throw CFLFailure.offline }
        let item: [String: Any] = ["id": "sticker_1", "version": version, "name": "Wave", "tags": ["hello"], "mediaType": "image/gif", "available": !catalogUnavailable]
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let value: [String: Any]
        if path.hasSuffix("/packs") {
            value = ["packs": [["id": "pack_1", "name": "Pack", "description": "", "cover": item]], "nextCursor": "page_2"]
        } else if path.hasSuffix("/favorites/image") {
            value = ["sticker": item, "favorite": true]
        } else if path.hasSuffix("/favorites") && request.httpMethod == "POST" {
            favoriteRemoved = (body["favorite"] as? Bool) == false
            value = ["sticker": item, "favorite": body["favorite"]!]
        } else if path.hasSuffix("/stage") {
            value = ["sessionId": body["sessionId"]!, "operationId": badStage ? "wrong" : body["operationId"]!,
                     "image": ["attachmentId": "staged_1", "name": "Wave", "mediaType": "image/gif", "availability": "available", "sticker": body["sticker"]!]]
        } else if path.contains("/media/") {
            let original = path.hasSuffix("/original")
            let bytes = original ? Data("GIF89a".utf8) : thumbnailData
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": original ? "image/gif" : "image/webp", "ETag": thumbnailETag])!)
        } else {
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value
            let favorites = path.hasSuffix("/favorites")
            var items = (favorites ? favoriteRemoved : catalogHidden) ? [] : [item]
            if extraFavorite && path.hasSuffix("/favorites") {
                var other = item; other["id"] = "sticker_2"; items.append(other)
            }
            value = ["stickers": cursor == "page_2" ? [] : items, "nextCursor": cursor == "page_2" ? NSNull() as Any : "page_2" as Any]
        }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func allRequests() -> [URLRequest] { requests }
    func setFailStage() { failStage = true }
    func setBadStage() { badStage = true }
    func setStatus(_ value: Int) { status = value }
    func setOffline(_ value: Bool) { offline = value }
    func setExtraFavorite() { extraFavorite = true }
    func setCatalogHidden(_ value: Bool) { catalogHidden = value }
    func setCatalogUnavailable(_ value: Bool) { catalogUnavailable = value }
    func assistantFavoriteIDs() -> Set<String> { assistantFavorites }
    func setThumbnailData(_ data: Data) { thumbnailData = data; thumbnailETag = "\"thumb-updated\"" }
    func changeScope() { scope = UUID() }
    func setDenied(_ value: Bool) { denied = value }
    func setHold() { hold = true }
    func holdNextFavoritePage() { holdFavoritePage = true }
    func favoritePageIsHeld() -> Bool { heldFavoritePage != nil }
    func releaseFavoritePage() { heldFavoritePage?.resume(); heldFavoritePage = nil }
    func holdNextPackPage() { holdPackPage = true }
    func packPageIsHeld() -> Bool { heldPackPage != nil }
    func releasePackPage() { heldPackPage?.resume(); heldPackPage = nil }
    func isHeld() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}

actor FakeMediaCache: CFLMediaCache {
    private var entries: [String: Data] = [:]
    private var failed = false
    private var writes = 0
    private var policies: [Bool] = []
    private var pauseRead = false
    private var heldRead: CheckedContinuation<Void, Never>?
    func setFailed(_ value: Bool) { failed = value }
    func keys() -> [String] { Array(entries.keys) }
    func writeCount() -> Int { writes }
    func expiryPolicies() -> [Bool] { policies }
    func pauseNextRead() { pauseRead = true }
    func readIsHeld() -> Bool { heldRead != nil }
    func releaseRead() { heldRead?.resume(); heldRead = nil }
    func read(key: String) async throws -> Data? {
        if pauseRead { pauseRead = false; await withCheckedContinuation { heldRead = $0 } }
        if failed { throw CFLFailure.storage }
        return entries[key]
    }
    func write(_ data: Data, key: String, withoutExpiry: Bool) throws { if failed { throw CFLFailure.storage }; writes += 1; policies.append(withoutExpiry); entries[key] = data }
    func update(key: String, withoutExpiry: Bool, transform: @Sendable (Data?) -> Data?) throws {
        if failed { throw CFLFailure.storage }
        if let result = transform(entries[key]) { writes += 1; policies.append(withoutExpiry); entries[key] = result }
    }
    func remove(key: String) throws { if failed { throw CFLFailure.storage }; entries.removeValue(forKey: key) }
}

func checkOfflineStickerOriginal(_ sticker: CFLSticker) async throws {
    let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot()), disk = FakeMediaCache()
    let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, mediaCache: disk, transport: { socket })
    await client.connect(); let revision = await client.currentState().sessionRevision
    let thumbnail = try await client.stickerMedia(sticker, session: "A", revision: revision)
    _ = try await client.searchStickers("hello", session: "A", revision: revision)
    let original = try await client.stickerMedia(sticker, original: true, session: "A", revision: revision)
    precondition(original == Data("GIF89a".utf8))

    // Online cache hits return immediately and schedule one revalidation.
    let beforeOnline = await http.allRequests().count, beforeWrites = await disk.writeCount()
    await http.setHold()
    let onlineOriginal = try await client.stickerMedia(sticker, original: true, session: "A", revision: revision)
    precondition(onlineOriginal == original)
    while !(await http.isHeld()) { await Task.yield() }
    await http.release()
    while await disk.writeCount() == beforeWrites { await Task.yield() }
    let afterOnline = await http.allRequests().count; precondition(afterOnline == beforeOnline + 1)

    // A session change while a cached read is suspended must discard the data.
    await disk.pauseNextRead()
    let stale = Task { try await client.stickerMedia(sticker, original: true, session: "A", revision: revision) }
    while !(await disk.readIsHeld()) { await Task.yield() }
    try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await client.currentState().sessionId != "B" { await Task.yield() }
    await disk.releaseRead()
    do { _ = try await stale.value; preconditionFailure("stale original") } catch CFLFailure.sessionChanged { }
    try await socket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    while await client.currentState().sessionId != "A" { await Task.yield() }
    let currentRevision = await client.currentState().sessionRevision

    // A transport failure leaves the current session active but offline.
    await socket.close()
    while await client.currentState().connection != .offline { await Task.yield() }
    let before = await http.allRequests().count
    let offlineOriginal = try await client.stickerMedia(sticker, original: true, session: "A", revision: currentRevision)
    precondition(offlineOriginal == original)
    let offlineThumbnail = try await client.cachedStickerThumbnail(sticker, session: "A", revision: currentRevision)
    let offlinePage = try await client.cachedSearchStickers("hello", session: "A", revision: currentRevision)
    precondition(offlineThumbnail == thumbnail && offlinePage?.stickers.map(\.id) == [sticker.id])
    let missingObject: [String: Any] = ["id": "other_sticker", "version": String(repeating: "b", count: 64),
        "name": "Other", "tags": [String](), "mediaType": "image/gif", "available": true]
    let missing = try JSONDecoder().decode(CFLSticker.self, from: JSONSerialization.data(withJSONObject: missingObject))
    do { _ = try await client.stickerMedia(missing, original: true, session: "A", revision: currentRevision); preconditionFailure("offline miss") }
    catch CFLFailure.offline { }
    do { _ = try await client.stickerMedia(sticker, original: true, session: "B", revision: currentRevision); preconditionFailure("wrong session") }
    catch CFLFailure.sessionChanged { }
    do { _ = try await client.setStickerFavorite(sticker.id, favorite: false, session: "A", revision: currentRevision); preconditionFailure("offline favorite") }
    catch CFLFailure.offline { }
    do { _ = try await client.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: currentRevision); preconditionFailure("offline send") }
    catch CFLFailure.offline { }
    let after = await http.allRequests().count
    precondition(after == before)
    await client.disconnect()

    // A confirmed login failure blocks cache display without deleting the copy.
    let deniedHTTP = FakeStickerHTTP(), deniedSocket = FakeSocket(snapshot: imageSnapshot())
    let denied = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: deniedHTTP, mediaCache: disk, transport: { deniedSocket })
    await denied.connect(); let deniedRevision = await denied.currentState().sessionRevision
    let beforeDenied = Set(await disk.keys())
    await deniedHTTP.setDenied(true); await deniedSocket.failReceive(.accessDenied)
    while await denied.currentState().connection != .accessDenied { await Task.yield() }
    do { _ = try await denied.stickerMedia(sticker, original: true, session: "A", revision: deniedRevision); preconditionFailure("denied cached original") }
    catch CFLFailure.sessionChanged { }
    let afterDenied = Set(await disk.keys()); precondition(afterDenied == beforeDenied)
    await denied.disconnect()

    let restoredHTTP = FakeStickerHTTP(), restoredSocket = FakeSocket(snapshot: imageSnapshot())
    let restored = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: restoredHTTP, mediaCache: disk, transport: { restoredSocket })
    await restored.connect(); let restoredRevision = await restored.currentState().sessionRevision
    let afterLogin = try await restored.stickerMedia(sticker, original: true, session: "A", revision: restoredRevision)
    precondition(afterLogin == original)
    await restored.disconnect()
}

func checkConcurrentFavoritePages() async throws {
    do {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        await http.holdNextPackPage()
        let before = await http.allRequests().count
        let first = Task { try await client.stickerPacks(session: "A", revision: revision) }
        while !(await http.packPageIsHeld()) { await Task.yield() }
        let second = Task { try await client.stickerPacks(session: "A", revision: revision) }
        while await client.stickerPackWaiterCount(session: "A") != 2 { await Task.yield() }
        await http.releasePackPage()
        let a = try await first.value, b = try await second.value
        precondition(a == b && a.packs.count == 1)
        let after = await http.allRequests().count; precondition(after == before + 1)
        await client.disconnect()
    }
    // The panel loads visible favorites and favorite IDs simultaneously.
    do {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot()), disk = FakeMediaCache()
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, mediaCache: disk, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        await http.holdNextFavoritePage()
        let before = await http.allRequests().count
        let first = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while !(await http.favoritePageIsHeld()) { await Task.yield() }
        let second = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while await client.favoritePageWaiterCount(session: "A") != 2 { await Task.yield() }
        await http.releaseFavoritePage()
        let a = try await first.value, b = try await second.value
        precondition(a == b && a.stickers.map(\.id) == ["sticker_1"])
        let after = await http.allRequests().count; precondition(after == before + 1)
        let snapshot = try await client.cachedFavoriteSnapshot(session: "A", revision: revision)
        precondition(snapshot?.page == a)
        await client.disconnect()
    }
    // A confirmed mutation supersedes both waiters and their old snapshot.
    do {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot()), disk = FakeMediaCache()
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, mediaCache: disk, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        _ = try await client.favoriteStickers(session: "A", revision: revision)
        await http.holdNextFavoritePage()
        let first = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while !(await http.favoritePageIsHeld()) { await Task.yield() }
        let second = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while await client.favoritePageWaiterCount(session: "A") != 2 { await Task.yield() }
        _ = try await client.setStickerFavorite("sticker_1", favorite: false, session: "A", revision: revision)
        let afterMutation = try await client.cachedFavoriteSnapshot(session: "A", revision: revision)
        precondition(afterMutation?.needsRevalidation == true && afterMutation?.page.stickers.isEmpty == true)
        let newer = try await client.favoriteStickers(session: "A", revision: revision)
        precondition(newer.stickers.isEmpty)
        await http.releaseFavoritePage()
        do { _ = try await first.value; preconditionFailure("old favorite page") } catch CFLFailure.sessionChanged { }
        do { _ = try await second.value; preconditionFailure("old favorite page") } catch CFLFailure.sessionChanged { }
        let snapshot = try await client.cachedFavoriteSnapshot(session: "A", revision: revision)
        precondition(snapshot?.needsRevalidation == false && snapshot?.page.stickers.isEmpty == true)
        await client.disconnect()
    }
    // A changed session or login scope invalidates both callers and their write.
    for switchSession in [true, false] {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot()), disk = FakeMediaCache()
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, mediaCache: disk, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        await http.holdNextFavoritePage()
        let first = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while !(await http.favoritePageIsHeld()) { await Task.yield() }
        let second = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while await client.favoritePageWaiterCount(session: "A") != 2 { await Task.yield() }
        if switchSession {
            try await socket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
            while await client.currentState().sessionId != "B" { await Task.yield() }
        } else { await http.changeScope() }
        await http.releaseFavoritePage()
        do { _ = try await first.value; preconditionFailure("stale first page") } catch CFLFailure.sessionChanged { }
        do { _ = try await second.value; preconditionFailure("stale second page") } catch CFLFailure.sessionChanged { }
        if switchSession {
            try await socket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
            while await client.currentState().sessionId != "A" { await Task.yield() }
        }
        let currentRevision = await client.currentState().sessionRevision
        let snapshot = try await client.cachedFavoriteSnapshot(session: "A", revision: currentRevision)
        precondition(snapshot == nil)
        await client.disconnect()
    }
    // Cancellation of a single view leaves the shared fetch for the other view.
    do {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        await http.holdNextFavoritePage()
        let first = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while !(await http.favoritePageIsHeld()) { await Task.yield() }
        let second = Task { try await client.favoriteStickers(session: "A", revision: revision) }
        while await client.favoritePageWaiterCount(session: "A") != 2 { await Task.yield() }
        first.cancel(); await http.releaseFavoritePage()
        do { _ = try await first.value; preconditionFailure("cancelled view") } catch CFLFailure.sessionChanged { }
        let retained = try await second.value; precondition(retained.stickers.count == 1)
        await client.disconnect()
    }
}

func checkPersistentMedia(_ sticker: CFLSticker) async throws {
    let disk = FakeMediaCache(), http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
    await http.setExtraFavorite()
    let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, mediaCache: disk, transport: { socket })
    await client.connect(); let revision = await client.currentState().sessionRevision
    let first = try await client.favoriteStickers(session: "A", revision: revision)
    precondition(first.stickers.count == 2 && first.nextCursor == "page_2")
    _ = try await client.searchStickers("hello", session: "A", revision: revision)
    _ = try await client.stickerPackMembers("pack_1", session: "A", revision: revision)
    _ = try await client.stickerMedia(sticker, session: "A", revision: revision)
    let original = try await client.stickerMedia(sticker, original: true, session: "A", revision: revision)
    _ = try await client.setStickerFavorite(sticker.id, favorite: false, session: "A", revision: revision)
    let afterRemoval = try await client.cachedFavoriteSnapshot(session: "A", revision: revision)!
    precondition(afterRemoval.needsRevalidation && afterRemoval.page.stickers.map(\.id) == ["sticker_2"] && afterRemoval.page.nextCursor == "page_2")
    let groupAfterRemoval = try await client.cachedStickerPackMembers("pack_1", session: "A", revision: revision)
    let assistantAfterRemoval = await http.assistantFavoriteIDs()
    precondition(groupAfterRemoval?.stickers.map(\.id) == [sticker.id] && assistantAfterRemoval == [sticker.id])
    let requestsAfterRemoval = await http.allRequests()
    let humanPost = requestsAfterRemoval.last { $0.url?.path == "/api/stickers/favorites" && $0.httpMethod == "POST" }!
    let humanBody = try JSONSerialization.jsonObject(with: humanPost.httpBody!) as! [String: Any]
    precondition(Set(humanBody.keys) == Set(["sessionId", "stickerId", "favorite"]))
    _ = try await client.setStickerFavorite(sticker.id, favorite: true, session: "A", revision: revision)
    let afterAddition = try await client.cachedFavoriteSnapshot(session: "A", revision: revision)!
    precondition(afterAddition.needsRevalidation && afterAddition.page.stickers.map(\.id) == ["sticker_2"])
    await client.disconnect()

    // A new client and login scope for the same origin reuse the same bytes.
    let nextHTTP = FakeStickerHTTP(), nextSocket = FakeSocket(snapshot: imageSnapshot())
    let next = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: nextHTTP, mediaCache: disk, transport: { nextSocket })
    await next.connect(); let nextRevision = await next.currentState().sessionRevision
    let restored = try await next.cachedStickerThumbnail(sticker, session: "A", revision: nextRevision)
    precondition(restored == Data([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80]))
    let restoredPage = try await next.cachedFavoriteSnapshot(session: "A", revision: nextRevision)
    precondition(restoredPage?.page.stickers.map(\.id) == ["sticker_2"])
    await nextHTTP.setDenied(true)
    do { _ = try await next.cachedStickerThumbnail(sticker, session: "A", revision: nextRevision); preconditionFailure("denied display") } catch CFLFailure.accessDenied { }
    await nextHTTP.setDenied(false); await nextHTTP.changeScope()
    let afterLogin = try await next.cachedStickerThumbnail(sticker, session: "A", revision: nextRevision)
    precondition(afterLogin == restored)
    await nextHTTP.setStatus(403)
    do { _ = try await next.stickerMedia(sticker, session: "A", revision: nextRevision); preconditionFailure("forbidden") } catch CFLFailure.requestFailed { }
    await next.disconnect()

    let againHTTP = FakeStickerHTTP(), againSocket = FakeSocket(snapshot: imageSnapshot())
    let again = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: againHTTP, mediaCache: disk, transport: { againSocket })
    await again.connect(); let againRevision = await again.currentState().sessionRevision
    let afterForbidden = try await again.cachedStickerThumbnail(sticker, session: "A", revision: againRevision)
    precondition(afterForbidden == restored)
    await againHTTP.setStatus(404)
    let writesBeforeReadFailures = await disk.writeCount()
    do { _ = try await again.stickerMedia(sticker, session: "A", revision: againRevision); preconditionFailure("unavailable read") } catch CFLFailure.requestFailed { }
    do { _ = try await again.stickerMedia(sticker, original: true, session: "A", revision: againRevision, revalidate: true); preconditionFailure("original unavailable read") } catch CFLFailure.requestFailed { }
    let retainedOriginal = try await again.stickerMedia(sticker, original: true, session: "A", revision: againRevision)
    precondition(retainedOriginal == original)
    let missingObject: [String: Any] = ["id": "missing_sticker", "version": String(repeating: "b", count: 64), "name": "Missing", "tags": [String](), "mediaType": "image/gif", "available": true]
    let missing = try JSONDecoder().decode(CFLSticker.self, from: JSONSerialization.data(withJSONObject: missingObject))
    do { _ = try await again.stickerMedia(missing, session: "A", revision: againRevision); preconditionFailure("uncached unavailable read") } catch CFLFailure.requestFailed { }
    do { _ = try await again.stickerMedia(missing, original: true, session: "A", revision: againRevision); preconditionFailure("uncached original unavailable read") } catch CFLFailure.requestFailed { }
    let writesAfterReadFailures = await disk.writeCount()
    precondition(writesAfterReadFailures == writesBeforeReadFailures)
    await again.disconnect()
    let lastHTTP = FakeStickerHTTP(), lastSocket = FakeSocket(snapshot: imageSnapshot())
    let last = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: lastHTTP, mediaCache: disk, transport: { lastSocket })
    await last.connect(); let lastRevision = await last.currentState().sessionRevision
    let afterReadFailure = try await last.cachedStickerThumbnail(sticker, session: "A", revision: lastRevision)
    precondition(afterReadFailure == restored)
    let oldSearch = try await last.cachedSearchStickers("hello", session: "A", revision: lastRevision)
    precondition(oldSearch?.stickers.map(\.id) == [sticker.id] && oldSearch?.nextCursor == "page_2")
    var updatedBytes = restored!; updatedBytes.append(42)
    await lastHTTP.setThumbnailData(updatedBytes)
    let updated = try await last.stickerMedia(sticker, session: "A", revision: lastRevision)
    precondition(updated == updatedBytes)
    let updatedCache = try await last.cachedStickerThumbnail(sticker, session: "A", revision: lastRevision)
    precondition(updatedCache == updatedBytes)
    await lastHTTP.setCatalogHidden(true)
    let refreshed = try await last.searchStickers("hello", session: "A", revision: lastRevision)
    let refreshedCache = try await last.cachedSearchStickers("hello", session: "A", revision: lastRevision)
    let stillFavorite = try await last.cachedFavoriteSnapshot(session: "A", revision: lastRevision)
    precondition(refreshed.stickers.isEmpty && refreshedCache?.stickers.isEmpty == true && stillFavorite?.page.stickers.map(\.id) == ["sticker_2"])
    await lastHTTP.setCatalogHidden(false); await lastHTTP.setCatalogUnavailable(true)
    let unavailablePage = try await last.searchStickers("hello", session: "A", revision: lastRevision)
    let unavailable = unavailablePage.stickers[0]
    precondition(!unavailable.available)
    let beforeUnavailable = Set(await disk.keys())
    do { _ = try await last.cachedStickerThumbnail(unavailable, session: "A", revision: lastRevision); preconditionFailure("unavailable item") } catch CFLStickerThumbnailFailure.removed { }
    do { _ = try await last.sendSticker(unavailable, expectedSessionId: "A", expectedSessionRevision: lastRevision); preconditionFailure("unavailable send") } catch CFLFailure.invalidInput { }
    let afterUnavailable = Set(await disk.keys())
    let stillCached = try await last.cachedStickerThumbnail(sticker, session: "A", revision: lastRevision)
    precondition(beforeUnavailable == afterUnavailable && stillCached == updatedBytes)
    try await lastSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await last.currentState().sessionId != "B" { await Task.yield() }
    let bRevision = await last.currentState().sessionRevision
    let otherSession = try await last.cachedFavoriteSnapshot(session: "B", revision: bRevision)
    precondition(otherSession == nil)
    await last.disconnect()

    let otherHTTP = FakeStickerHTTP(), otherSocket = FakeSocket(snapshot: imageSnapshot())
    let other = CFLChatClient(target: "https://other.example", store: MemoryStore(), imageHTTP: otherHTTP, mediaCache: disk, transport: { otherSocket })
    await other.connect(); let otherRevision = await other.currentState().sessionRevision
    let unrelated = try await other.cachedFavoriteSnapshot(session: "A", revision: otherRevision)
    precondition(unrelated == nil)
    await disk.setFailed(true)
    let networkBytes = try await other.stickerMedia(sticker, session: "A", revision: otherRevision)
    precondition(networkBytes == restored)
    await other.disconnect()
}

func checkConcurrentStickerThumbnails(_ sticker: CFLSticker) async throws {
    let bytes = Data([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80])
    // Two views wait for one revalidation, including the conditional 304 path.
    for status in [200, 304, 403, 404] {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        if status != 200 { _ = try await client.stickerMedia(sticker, session: "A", revision: revision) }
        let before = await http.allRequests().count
        await http.setStatus(status); await http.setHold()
        let first = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while !(await http.isHeld()) { await Task.yield() }
        let second = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while await client.thumbnailWaiterCount(sticker, session: "A") != 2 { await Task.yield() }
        await http.release()
        if status == 200 || status == 304 {
            let a = try await first.value, b = try await second.value
            precondition(a == bytes && b == bytes)
        } else {
            do { _ = try await first.value; preconditionFailure("failed first waiter") } catch CFLFailure.requestFailed { }
            do { _ = try await second.value; preconditionFailure("failed second waiter") } catch CFLFailure.requestFailed { }
            let cached = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
            precondition(cached == bytes)
        }
        let requests = await http.allRequests()
        precondition(requests.count == before + 1)
        if status == 304 {
            precondition(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"thumb\"")
            await http.setStatus(403)
            do { _ = try await client.stickerMedia(sticker, session: "A", revision: revision); preconditionFailure("later read failure") } catch CFLFailure.requestFailed { }
            let cached = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
            precondition(cached == bytes)
        }
        await client.disconnect()
    }
    // An explicitly unavailable item cancels the old shared request, while
    // any existing copy remains usable if the directory later permits it.
    for status in [200, 304] {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        if status == 304 { _ = try await client.stickerMedia(sticker, session: "A", revision: revision) }
        await http.setStatus(status); await http.setHold()
        let first = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while !(await http.isHeld()) { await Task.yield() }
        let second = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while await client.thumbnailWaiterCount(sticker, session: "A") != 2 { await Task.yield() }
        let object: [String: Any] = ["id": sticker.id, "version": sticker.version, "name": sticker.name,
            "tags": sticker.tags, "mediaType": sticker.mediaType, "available": false]
        let unavailable = try JSONDecoder().decode(CFLSticker.self, from: JSONSerialization.data(withJSONObject: object))
        do { _ = try await client.cachedStickerThumbnail(unavailable, session: "A", revision: revision); preconditionFailure("unavailable item") } catch CFLStickerThumbnailFailure.removed { }
        await http.release()
        do { _ = try await first.value; preconditionFailure("stale first waiter") } catch CFLFailure.sessionChanged { }
        do { _ = try await second.value; preconditionFailure("stale second waiter") } catch CFLFailure.sessionChanged { }
        let cached = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
        precondition(cached == (status == 304 ? bytes : nil))
        await client.disconnect()
    }
    // Identity replacement while both callers are waiting invalidates the shared result.
    do {
        let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
        let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
        await client.connect(); let revision = await client.currentState().sessionRevision
        await http.setHold()
        let first = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while !(await http.isHeld()) { await Task.yield() }
        let second = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
        while await client.thumbnailWaiterCount(sticker, session: "A") != 2 { await Task.yield() }
        await http.changeScope(); await http.release()
        do { _ = try await first.value; preconditionFailure("old identity first") } catch CFLFailure.sessionChanged { }
        do { _ = try await second.value; preconditionFailure("old identity second") } catch CFLFailure.sessionChanged { }
        let cached = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
        precondition(cached == nil)
        await client.disconnect()
    }
    // A caller cancelling its own view must not cancel a second live waiter.
    let http = FakeStickerHTTP(), socket = FakeSocket(snapshot: imageSnapshot())
    let client = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: http, transport: { socket })
    await client.connect(); let revision = await client.currentState().sessionRevision
    await http.setHold()
    let first = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
    while !(await http.isHeld()) { await Task.yield() }
    let second = Task { try await client.stickerMedia(sticker, session: "A", revision: revision) }
    while await client.thumbnailWaiterCount(sticker, session: "A") != 2 { await Task.yield() }
    first.cancel(); await http.release()
    do { _ = try await first.value; preconditionFailure("cancelled caller") } catch CFLFailure.sessionChanged { }
    let live = try await second.value; precondition(live == bytes)
    await client.disconnect()
}

func checkStickers() async throws {
    try await checkConcurrentFavoritePages()
    let socket = FakeSocket(snapshot: imageSnapshot()), http = FakeStickerHTTP(), store = MemoryStore()
    let auth = CFLAuthorization(store: ImageTestCredentials(), http: http)
    try await auth.select(origin: "https://example.com")
    let client = CFLChatClient(target: "https://example.com", store: store,
        imageHTTP: CFLAuthorizedHTTP(authorization: auth, http: http), transport: { socket })
    await client.connect()
    let state = await client.currentState(), revision = state.sessionRevision
    let packs = try await client.stickerPacks(session: "A", revision: revision)
    precondition(packs.nextCursor == "page_2" && packs.packs[0].cover.id == "sticker_1")
    let members = try await client.stickerPackMembers("pack_1", session: "A", revision: revision)
    let sticker = members.stickers[0]
    try await checkOfflineStickerOriginal(sticker)
    try await checkConcurrentStickerThumbnails(sticker)
    try await checkPersistentMedia(sticker)
    let last = try await client.stickerPackMembers("pack_1", session: "A", revision: revision, cursor: members.nextCursor)
    precondition(last.stickers.isEmpty && last.nextCursor == nil)
    let search = try await client.searchStickers("hello & 波", session: "A", revision: revision)
    let favorites = try await client.favoriteStickers(session: "A", revision: revision)
    precondition(search.stickers == favorites.stickers)
    _ = try await client.setStickerFavorite(sticker.id, favorite: false, session: "A", revision: revision)
    let stickerImage = CFLImageRef(attachmentId: "staged_1", name: "Wave", mediaType: "image/gif", availability: "available", sticker: sticker.identity)
    _ = try await client.favoriteChatImage(stickerImage, session: "A", revision: revision)
    _ = try await client.favoriteChatImage(CFLImageRef(attachmentId: "image_1", name: "photo.png", mediaType: "image/png", availability: "available"), session: "A", revision: revision)
    let emptyCache = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
    precondition(emptyCache == nil)
    let preview = try await client.stickerMedia(sticker, session: "A", revision: revision)
    precondition(preview == Data([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80]))
    let cachedPreview = try await client.cachedStickerThumbnail(sticker, session: "A", revision: revision)
    precondition(cachedPreview == preview)
    await http.setStatus(304)
    let revalidated = try await client.stickerMedia(sticker, session: "A", revision: revision)
    precondition(revalidated == preview)
    let conditional = await http.allRequests().last!
    precondition(conditional.url!.path.hasSuffix("/thumbnail") && conditional.value(forHTTPHeaderField: "If-None-Match") == "\"thumb\"")
    await http.setStatus(200)
    let original = try await client.stickerMedia(sticker, original: true, session: "A", revision: revision)
    precondition(original == Data("GIF89a".utf8))
    let operation = try await client.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: revision)
    let requests = await http.allRequests()
    precondition(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && $0.value(forHTTPHeaderField: "Origin") == "https://example.com" })
    let searchRequest = requests.first { $0.url!.path.hasSuffix("/search") }!
    precondition(URLComponents(url: searchRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value == "hello & 波")
    let mutations = requests.filter { $0.httpMethod == "POST" }
    precondition(mutations.map { $0.url!.path } == ["/api/stickers/favorites", "/api/stickers/favorites", "/api/stickers/favorites/image", "/api/stickers/stage"])
    let favoriteBody = try JSONSerialization.jsonObject(with: mutations[1].httpBody!) as! [String: Any]
    precondition(favoriteBody["stickerId"] as? String == sticker.id && favoriteBody["imageId"] == nil)
    let imageBody = try JSONSerialization.jsonObject(with: mutations[2].httpBody!) as! [String: Any]
    precondition(imageBody["imageId"] as? String == "image_1" && (imageBody["tags"] as? [String]) == [])
    let stageBody = try JSONSerialization.jsonObject(with: mutations[3].httpBody!) as! [String: Any]
    let submissions = await socket.arguments(for: "submit"), saved = try await store.load()
    precondition(stageBody["operationId"] as? String == operation && submissions[0][0].object?["operationId"] == .string(operation))
    precondition(submissions[0][0].object?["text"] == .string("") && saved.first?.images?.first?.sticker == sticker.identity && saved.first?.dispatched == true)
    await client.disconnect()

    for malformed in [false, true] {
        let h = FakeStickerHTTP(), sock = FakeSocket(snapshot: imageSnapshot()), st = MemoryStore()
        if malformed { await h.setBadStage() } else { await h.setFailStage() }
        let c = CFLChatClient(target: "https://example.com", store: st, imageHTTP: h, transport: { sock })
        await c.connect(); let rev = await c.currentState().sessionRevision
        do { _ = try await c.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: rev); preconditionFailure("invalid stage accepted") } catch { }
        let sent = await sock.methods(), records = try await st.load(), reqs = await h.allRequests()
        precondition(!sent.contains("submit") && records.isEmpty && reqs.filter { $0.url!.path.hasSuffix("/stage") }.count == 1)
        await c.disconnect()
    }
    let cacheHTTP = FakeStickerHTTP(), cacheSocket = FakeSocket(snapshot: imageSnapshot())
    let cacheClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: cacheHTTP, transport: { cacheSocket })
    await cacheClient.connect(); let cacheRevision = await cacheClient.currentState().sessionRevision
    _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision)
    await cacheHTTP.setOffline(true)
    do { _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision); preconditionFailure("network accepted") } catch { }
    let retained = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(retained == preview)
    await cacheHTTP.setOffline(false); await cacheHTTP.setStatus(404)
    do { _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision); preconditionFailure("failed read accepted") } catch CFLFailure.requestFailed { }
    let after404 = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(after404 == preview)
    await cacheHTTP.setStatus(200)
    _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision)
    await cacheHTTP.setStatus(403)
    do { _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision); preconditionFailure("forbidden accepted") } catch CFLFailure.requestFailed { }
    let forbidden = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(forbidden == preview)
    await cacheHTTP.setStatus(200)
    _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision)
    await cacheHTTP.changeScope()
    let otherIdentity = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(otherIdentity == nil)
    await cacheHTTP.setStatus(304)
    do { _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision); preconditionFailure("304 without cache") } catch CFLFailure.protocolError { }
    await cacheHTTP.setStatus(200)
    await cacheHTTP.setHold()
    let staleThumbnail = Task { try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision) }
    while !(await cacheHTTP.isHeld()) { await Task.yield() }
    await cacheHTTP.changeScope(); await cacheHTTP.release()
    do { _ = try await staleThumbnail.value; preconditionFailure("old identity result") } catch CFLFailure.sessionChanged { }
    let afterRace = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(afterRace == nil)
    _ = try await cacheClient.stickerMedia(sticker, session: "A", revision: cacheRevision)
    await cacheHTTP.setDenied(true)
    do { _ = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision); preconditionFailure("revoked cache") } catch CFLFailure.accessDenied { }
    await cacheHTTP.setDenied(false)
    let afterRevocation = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision)
    precondition(afterRevocation == nil)
    try await cacheSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await cacheClient.currentState().sessionId != "B" { await Task.yield() }
    let nextRevision = await cacheClient.currentState().sessionRevision
    do { _ = try await cacheClient.cachedStickerThumbnail(sticker, session: "A", revision: cacheRevision); preconditionFailure("stale session cache") } catch CFLFailure.sessionChanged { }
    let otherSession = try await cacheClient.cachedStickerThumbnail(sticker, session: "B", revision: nextRevision)
    precondition(otherSession == nil)
    try await cacheSocket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    while await cacheClient.currentState().sessionId != "A" { await Task.yield() }
    let finalRevision = await cacheClient.currentState().sessionRevision
    // The process-local cache is bounded and evicts least-recently-used entries.
    for index in 0...128 {
        let object: [String: Any] = ["id": "item_\(index)", "version": sticker.version, "name": "Item", "tags": [String](), "mediaType": "image/gif", "available": true]
        let item = try JSONDecoder().decode(CFLSticker.self, from: JSONSerialization.data(withJSONObject: object))
        _ = try await cacheClient.stickerMedia(item, session: "A", revision: finalRevision)
    }
    let oldestData = try JSONSerialization.data(withJSONObject: ["id": "item_0", "version": sticker.version, "name": "Item", "tags": [String](), "mediaType": "image/gif", "available": true])
    let oldest = try JSONDecoder().decode(CFLSticker.self, from: oldestData)
    let evicted = try await cacheClient.cachedStickerThumbnail(oldest, session: "A", revision: finalRevision)
    precondition(evicted == nil)
    await cacheClient.disconnect()
    let deniedHTTP = FakeStickerHTTP(), deniedSocket = FakeSocket(snapshot: imageSnapshot())
    let denied = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: deniedHTTP, transport: { deniedSocket })
    await denied.connect(); let deniedRevision = await denied.currentState().sessionRevision
    await deniedHTTP.setStatus(403)
    do { _ = try await denied.stickerPacks(session: "A", revision: deniedRevision); preconditionFailure("unauthorized catalog") } catch CFLFailure.accessDenied { }
    do { _ = try await denied.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: deniedRevision); preconditionFailure("unauthorized send") } catch CFLFailure.accessDenied { }
    let deniedMethods = await deniedSocket.methods(); precondition(!deniedMethods.contains("submit"))
    await denied.disconnect()
    let staleHTTP = FakeStickerHTTP(), staleSocket = FakeSocket(snapshot: imageSnapshot())
    let staleClient = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: staleHTTP, transport: { staleSocket })
    await staleClient.connect(); let staleRevision = await staleClient.currentState().sessionRevision
    await staleHTTP.setHold()
    let pending = Task { try await staleClient.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: staleRevision) }
    while !(await staleHTTP.isHeld()) { await Task.yield() }
    try await staleSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    while await staleClient.currentState().sessionId != "B" { await Task.yield() }
    await staleHTTP.release()
    do { _ = try await pending.value; preconditionFailure("stale stage accepted") } catch CFLFailure.sessionChanged { }
    let staleMethods = await staleSocket.methods(); precondition(!staleMethods.contains("submit"))
    await staleClient.disconnect()

    // A lost submit is saved with its sticker identity. Recovery checks it and
    // never sends either the stage request or submit again.
    let lostStore = MemoryStore(), lostHTTP = FakeStickerHTTP()
    let lostSocket = FakeSocket(snapshot: imageSnapshot(), dropSubmit: true)
    let lost = CFLChatClient(target: "https://example.com", store: lostStore, imageHTTP: lostHTTP, transport: { lostSocket })
    await lost.connect(); let lostRevision = await lost.currentState().sessionRevision
    let lostOperation = try await lost.sendSticker(sticker, expectedSessionId: "A", expectedSessionRevision: lostRevision)
    await lost.disconnect()
    let lostRecords = try await lostStore.load()
    precondition(lostRecords.count == 1 && lostRecords[0].dispatched && lostRecords[0].images?.first?.sticker == sticker.identity)
    let old = lostRecords[0]
    await lostStore.setEntries([CFLPending(target: old.target, sessionId: old.sessionId, operationId: old.operationId,
        text: old.text, createdAt: Date(timeIntervalSinceNow: -120), dispatched: true, status: .unknown, images: old.images)])
    let restoreHTTP = FakeStickerHTTP(), restoreSocket = FakeSocket(snapshot: imageSnapshot())
    let restored = CFLChatClient(target: "https://example.com", store: lostStore, imageHTTP: restoreHTTP, transport: { restoreSocket })
    await restored.connect(); try await restored.reconcile()
    let restoreMethods = await restoreSocket.methods(), restoreRequests = await restoreHTTP.allRequests()
    let finalize = await restoreSocket.arguments(for: "finalizeSubmission")
    precondition(!restoreMethods.contains("submit") && restoreRequests.isEmpty && finalize.count == 1)
    let recovered = finalize[0][0].object?["submission"]?.object
    precondition(recovered?["operationId"] == .string(lostOperation) && recovered?["images"]?.array?.first?.object?["sticker"]?.object?["id"] == .string(sticker.id))
    await restored.disconnect()
    print("CFL sticker checks passed")
}

func fileWire(_ id: String, name: String = "note.txt", size: Int = 3, availability: String = "available") -> ChordJSON {
    .object(["attachmentId": .string(id), "name": .string(name), "mediaType": .string(""),
             "size": .number(Double(size)), "availability": .string(availability)])
}
func fileSnapshot(before: String? = nil) -> ChordJSON {
    let recovery: ChordJSON = .object(["sourceId": .string("source"), "operationId": .string("12345678-1234-4234-8234-123456789abc"),
        "text": .string("draft"), "images": .array([]), "files": .array([fileWire("missing", availability: "missing")]), "replacementEligible": .bool(true)])
    let msg: ChordJSON = .object(["id": .string("file-history"), "role": .string("user"), "text": .string(""), "createdAt": .number(1),
        "operationId": .null, "turnId": .null, "files": .array([fileWire("history")])])
    let view: ChordJSON = .object(["version": .number(2), "sessionId": .string("A"), "name": .string("test"), "activeTurnId": .null,
        "contextUsage": .null, "compaction": .null, "recovery": .array([recovery]),
        "capabilities": .object(["text": .bool(true), "stop": .bool(true),
            "images": .object(["mediaTypes": .array([.string("image/png")]), "maxImagesPerMessage": .number(2), "maxImageBytes": .number(100), "maxMessageImageBytes": .number(150)]),
            "files": .object(["maxFilesPerMessage": .number(2), "maxFileBytes": .number(5), "maxMessageFileBytes": .number(6)])]),
        "messages": .array([msg]), "before": before.map(ChordJSON.string) ?? .null])
    return .object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"), "instances": .array([.object(["members": .array([.object(["name": .string("view"), "kind": .string("state"), "sequence": .number(0), "ops": .array([.array([.string("r"), view])])])])])])])
}
final class BoundedAuthRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
    func take() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; let result = requests; requests = []; return result }
}

/// Isolated URLSession fake exercises the real bounded delegate, without a server.
final class BoundedFileURLProtocol: URLProtocol, @unchecked Sendable {
    static let authRequests = BoundedAuthRequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status = path == "/auth401" || path == "/denied" ? 401 : (path == "/auth403" ? 403 : (path == "/redirect" ? 302 : 200))
        let hasErrorBody = path == "/auth401" || path == "/auth403"
        if hasErrorBody { Self.authRequests.append(request) }
        let headers = hasErrorBody ? ["Content-Length": "257"] : (path == "/contentlong" ? ["Content-Length": "100"] : nil)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if hasErrorBody {
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 257))
        } else if status == 200 && path != "/empty" && path != "/contentlong" {
            client?.urlProtocol(self, didLoad: Data([1, 2]))
            client?.urlProtocol(self, didLoad: Data(path == "/oversized" ? [3, 4] : [3]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
actor BoundedAuthStatusHTTP: CFLImageHTTP {
    let state: String
    private var requests: [URLRequest] = []
    init(state: String) { self.state = state }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body = try JSONSerialization.data(withJSONObject: ["state": state])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func allRequests() -> [URLRequest] { requests }
}

/// Exercises URLSession's bounded upload/download delegate and the real auth wrapper.
func checkBoundedAuthErrorBodies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("etos-bounded-auth-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("upload")
    try Data([1, 2, 3]).write(to: source)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BoundedFileURLProtocol.self]
    let raw = CFLImageURLSession(boundedConfiguration: config)
    for status in [401, 403] {
        let url = URL(string: "https://example.com/auth\(status)")!
        var upload = URLRequest(url: url); upload.httpMethod = "PUT"
        let download = URLRequest(url: url)
        let directDestination = root.appendingPathComponent("direct-\(status)")
        guard FileManager.default.createFile(atPath: directDestination.path, contents: nil) else { throw CFLFailure.storage }
        _ = BoundedFileURLProtocol.authRequests.take()
        let (body, uploadResponse) = try await raw.uploadFile(for: upload, from: source, maximumResponseBytes: 0)
        precondition(body.isEmpty && (uploadResponse as? HTTPURLResponse)?.statusCode == status && uploadResponse.expectedContentLength == 257)
        let downloadResponse = try await raw.downloadFile(for: download, to: directDestination, maximumBytes: 1)
        let directBytes = try Data(contentsOf: directDestination)
        precondition((downloadResponse as? HTTPURLResponse)?.statusCode == status && downloadResponse.expectedContentLength == 257 && directBytes.isEmpty)
        let directRequests = BoundedFileURLProtocol.authRequests.take()
        precondition(directRequests.count == 2)
        for authState in ["signed_in", "setup"] {
            let authHTTP = BoundedAuthStatusHTTP(state: authState)
            let auth = CFLAuthorization(store: ImageTestCredentials(), http: authHTTP)
            try await auth.select(origin: "https://example.com")
            let authorized = CFLAuthorizedHTTP(authorization: auth, http: raw)
            let destination = root.appendingPathComponent("\(status)-\(authState)")
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CFLFailure.storage }
            do {
                _ = try await authorized.uploadFile(for: upload, from: source, maximumResponseBytes: 0)
                preconditionFailure("unauthorized upload accepted")
            } catch CFLFailure.offline { precondition(authState == "signed_in") }
              catch CFLFailure.accessDenied { precondition(authState == "setup") }
            do {
                _ = try await authorized.downloadFile(for: download, to: destination, maximumBytes: 1)
                preconditionFailure("unauthorized download accepted")
            } catch CFLFailure.offline { precondition(authState == "signed_in") }
              catch CFLFailure.accessDenied { precondition(authState == "setup") }
            let requests = BoundedFileURLProtocol.authRequests.take(), checks = await authHTTP.allRequests()
            let saved = try Data(contentsOf: destination)
            precondition(saved.isEmpty && requests.count == 2 && checks.count == 2)
            precondition(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && $0.value(forHTTPHeaderField: "Origin") == "https://example.com" })
            precondition(checks.allSatisfy { $0.url?.path == "/api/auth/status" })
        }
    }
}

actor FakeFileHTTP: CFLImageHTTP {
    var requests: [URLRequest] = []
    var malformed = ""
    var hold = false
    var downloadStatus = 200
    var downloadBytes = Data([1, 2, 3])
    var limits: [Int] = []
    var manifest: [String: Any]?
    var received: [String: Data] = [:]
    var continuation: CheckedContinuation<Void, Never>?
    let images = FakeImageHTTP()
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if request.url!.path == "/api/chat/images" { return try await images.data(for: request) }
        if request.url!.path == "/api/auth/status" {
            return (Data("{\"state\":\"signed_in\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if hold { await withCheckedContinuation { continuation = $0 }; hold = false }
        let path = request.url!.path
        let status = path.hasPrefix("/api/chat/files/") ? downloadStatus : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        if path.hasPrefix("/api/chat/files/") { return (downloadBytes, response) }
        if path == "/api/chat/file-operations", request.httpMethod == "POST" {
            manifest = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        }
        guard let manifest, let items = manifest["files"] as? [[String: Any]] else { throw CFLFailure.protocolError }
        if path.hasSuffix("/complete") {
            var refs = items.enumerated().map { index, item in
                ["id": item["id"]!, "order": index, "ref": ["attachmentId": "file_\(index)", "name": item["name"]!,
                    "mediaType": item["mediaType"]!, "size": item["size"]!, "availability": "available"]] as [String: Any]
            }
            if malformed == "order" { refs.reverse() }
            if malformed == "duplicate" && refs.count > 1 { refs[1]["ref"] = refs[0]["ref"] }
            if malformed == "size" { var ref = refs[0]["ref"] as! [String: Any]; ref["size"] = 4; refs[0]["ref"] = ref }
            if malformed == "extra" { refs[0]["extra"] = true }
            let result: [String: Any] = ["sessionId": malformed == "session" ? "B" : manifest["sessionId"]!,
                "operationId": malformed == "operation" ? UUID().uuidString : manifest["operationId"]!, "files": refs]
            return (try JSONSerialization.data(withJSONObject: result), response)
        }
        let uploaded = items.compactMap { item -> String? in
            guard let id = item["id"] as? String, received[id] != nil else { return nil }; return id
        }
        return (try JSONSerialization.data(withJSONObject: ["manifest": manifest, "uploaded": uploaded]), response)
    }
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return (Data(), response) }
        var buffer = CFLBoundedDataBuffer(maximumBytes: maximumBytes)
        for byte in bytes { try buffer.append(Data([byte])) }
        return (buffer.data, response)
    }
    func uploadFile(for request: URLRequest, from file: URL, maximumResponseBytes: Int) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let items = manifest?["files"] as? [[String: Any]],
              let item = items.first(where: { $0["id"] as? String == request.url!.lastPathComponent }) else { throw CFLFailure.protocolError }
        let bytes = try Data(contentsOf: file)
        guard bytes.count == item["size"] as? Int else { throw CFLFailure.protocolError }
        received[request.url!.lastPathComponent] = bytes
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
    func downloadFile(for request: URLRequest, to destination: URL, maximumBytes: Int) async throws -> URLResponse {
        limits.append(maximumBytes)
        let (bytes, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CFLFailure.protocolError }
        if (200...299).contains(http.statusCode) {
            guard bytes.count <= maximumBytes else { throw CFLFailure.protocolError }
            try bytes.write(to: destination)
        }
        return response
    }
    func setDownload(status: Int = 200, bytes: Data = Data([1, 2, 3])) { downloadStatus = status; downloadBytes = bytes }
    func allLimits() -> [Int] { limits }
    func setMalformed(_ value: String) { malformed = value }
    func setHold() { hold = true }
    func isHeld() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func allRequests() -> [URLRequest] { requests }
    func uploadedData() -> [String: Data] { received }
}
func fileRetryReceipt(attempt: String, source: String, session: String = "A", old: [String] = ["a", "b"], new: [String] = ["new_a", "new_b"], size: Int = 3) -> ChordJSON {
    .object(["operationId": .string(attempt), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null,
        "retryFiles": .object(["sessionId": .string(session), "sourceOperationId": .string(source), "files": .array(zip(old, new).map { oldID, newID in
            .object(["sourceAttachmentId": .string(oldID), "ref": fileWire(newID, size: size)])
        })])])
}
#if canImport(CryptoKit)
func checkFiles() async throws {
    let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("etos-single-file-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    let fixtureDirectory = testRoot.appendingPathComponent("snapshots", isDirectory: true)
    func fixture(_ bytes: Data, name: String, mediaType: String = "") throws -> CFLPreparedFile {
        let source = testRoot.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        return try CFLFileDraftStorage.copy(source: source, directory: fixtureDirectory, name: name, mediaType: mediaType)
    }
    let files = [try fixture(Data([1, 2, 3]), name: "note.txt"),
                 try fixture(Data(), name: "empty", mediaType: "application/example")]
    let socket = FakeSocket(snapshot: fileSnapshot(before: "older")), store = MemoryStore(), http = FakeFileHTTP()
    let historical: ChordJSON = .object(["id": .string("older-file"), "role": .string("user"), "text": .string(""), "createdAt": .number(1), "operationId": .null, "turnId": .null, "files": .array([fileWire("old", availability: "missing")])])
    await socket.setHistory(["older": .object(["messages": .array([historical]), "before": .null])])
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
    await client.connect(); let initial = await client.currentState()
    precondition(initial.fileLimits?.maxFilesPerMessage == 2 && initial.messages.first?.files?.first?.attachmentId == "history")
    precondition(initial.recovery.first?.files?.first?.availability == "missing")
    try await client.validateFiles(files)
    do { try await client.validateFiles(files + [files[0]]); preconditionFailure("file count") } catch CFLFailure.invalidInput { }
    let invalidID = CFLPreparedFile(id: "bad/path", name: files[0].name, mediaType: files[0].mediaType,
                                    ownedFile: files[0].ownedFileURL, size: files[0].size, sha256: files[0].sha256)
    let sixBytes = try fixture(Data(repeating: 1, count: 6), name: "six")
    let fourBytes = [try fixture(Data(repeating: 1, count: 4), name: "four-a"),
                     try fixture(Data(repeating: 1, count: 4), name: "four-b")]
    do { try await client.validateFiles([invalidID]); preconditionFailure("file id") } catch CFLFailure.invalidInput { }
    do { try await client.validateFiles([sixBytes]); preconditionFailure("file size") } catch CFLFailure.invalidInput { }
    do { try await client.validateFiles(fourBytes); preconditionFailure("aggregate") } catch CFLFailure.invalidInput { }
    let operation = try await client.send("", files: files, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision)
    let calls = await socket.arguments(for: "submit"), records = await store.entries, requests = await http.allRequests()
    precondition(calls.first?.first?.object?["files"]?.array?.count == 2 && records.first?.files?.map(\.attachmentId) == ["file_0", "file_1"])
    let manifest = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
    let declared = manifest["files"] as! [[String: Any]], uploaded = await http.uploadedData()
    precondition(requests.count == 4 && requests[0].url?.path == "/api/chat/file-operations" && requests[1].httpMethod == "PUT" && requests[2].httpMethod == "PUT" && requests[3].url!.path.hasSuffix("/complete"))
    precondition(manifest["operationId"] as? String == operation && declared.map { $0["id"] as! String } == files.map(\.id) && requests[0].value(forHTTPHeaderField: "Origin") == "https://example.com")
    precondition(declared.map { $0["name"] as! String } == files.map(\.name) && declared.map { $0["mediaType"] as! String } == files.map(\.mediaType) && declared.map { $0["size"] as! Int } == [3, 0])
    precondition(uploaded[files[0].id] == Data([1, 2, 3]) && uploaded[files[1].id] == Data())
    let local = try await client.downloadFile(initial.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision)
    let bytes = try Data(contentsOf: local); precondition(bytes == Data([1, 2, 3]))
    try FileManager.default.removeItem(at: local)
    do { _ = try await client.downloadFile(initial.recovery[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision); preconditionFailure("missing file") } catch CFLFailure.invalidInput { }
    let limits = await http.allLimits(); precondition(limits == [3])
    var bounded = CFLBoundedDataBuffer(maximumBytes: 3)
    try bounded.append(Data([1, 2])); try bounded.append(Data([3]))
    do { try bounded.append(Data([4])); preconditionFailure("oversized chunk retained") } catch CFLFailure.protocolError { }
    precondition(bounded.data == Data([1, 2, 3]))
    var zero = CFLBoundedDataBuffer(maximumBytes: 0)
    try zero.append(Data())
    do { try zero.append(Data([1])); preconditionFailure("empty file accepted bytes") } catch CFLFailure.protocolError { }
    await http.setDownload(bytes: Data([1, 2, 3, 4]))
    do { _ = try await client.downloadFile(initial.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision); preconditionFailure("oversized download") } catch CFLFailure.protocolError { }
    await http.setDownload(bytes: Data([1, 2]))
    do { _ = try await client.downloadFile(initial.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision); preconditionFailure("truncated download") } catch CFLFailure.protocolError { }
    await http.setDownload(status: 302)
    do { _ = try await client.downloadFile(initial.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: initial.sessionRevision); preconditionFailure("redirect accepted") } catch CFLFailure.requestFailed { }
    try await client.loadEarlier()
    let loaded = await client.currentState(); precondition(loaded.messages.contains { $0.files?.first?.availability == "missing" })
    await client.disconnect()

    let boundedConfig = URLSessionConfiguration.ephemeral
    boundedConfig.protocolClasses = [BoundedFileURLProtocol.self]
    let boundedHTTP = CFLImageURLSession(boundedConfiguration: boundedConfig)
    func boundedRequest(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://example.com/" + path)!) }
    let (boundedBytes, _) = try await boundedHTTP.boundedData(for: boundedRequest("valid"), maximumBytes: 3)
    precondition(boundedBytes == Data([1, 2, 3]))
    let downloadDestination = FileManager.default.temporaryDirectory.appendingPathComponent("etos-test-download-" + UUID().uuidString)
    precondition(FileManager.default.createFile(atPath: downloadDestination.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: downloadDestination) }
    _ = try await boundedHTTP.downloadFile(for: boundedRequest("valid"), to: downloadDestination, maximumBytes: 3)
    let streamed = try Data(contentsOf: downloadDestination); precondition(streamed == Data([1, 2, 3]))
    let oversizedDestination = FileManager.default.temporaryDirectory.appendingPathComponent("etos-test-download-" + UUID().uuidString)
    precondition(FileManager.default.createFile(atPath: oversizedDestination.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: oversizedDestination) }
    do { _ = try await boundedHTTP.downloadFile(for: boundedRequest("oversized"), to: oversizedDestination, maximumBytes: 3); preconditionFailure("oversized stream to disk") } catch CFLFailure.protocolError { }
    let partial = try Data(contentsOf: oversizedDestination); precondition(partial.count <= 3)
    let (emptyBytes, _) = try await boundedHTTP.boundedData(for: boundedRequest("empty"), maximumBytes: 0)
    precondition(emptyBytes.isEmpty)
    do { _ = try await boundedHTTP.boundedData(for: boundedRequest("oversized"), maximumBytes: 3); preconditionFailure("stream exceeded limit") } catch CFLFailure.protocolError { }
    do { _ = try await boundedHTTP.boundedData(for: boundedRequest("contentlong"), maximumBytes: 3); preconditionFailure("oversized content length") } catch CFLFailure.protocolError { }
    let delegate = CFLBoundedTransfer(maximumBytes: 3, configuration: nil)
    let redirectSession = URLSession(configuration: .ephemeral)
    let redirectTask = redirectSession.dataTask(with: boundedRequest("redirect"))
    let redirect = HTTPURLResponse(url: redirectTask.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example/"])!
    var redirected: URLRequest? = boundedRequest("valid")
    delegate.urlSession(redirectSession, task: redirectTask, willPerformHTTPRedirection: redirect,
                        newRequest: URLRequest(url: URL(string: "https://other.example/")!)) { redirected = $0 }
    precondition(redirected == nil); redirectSession.invalidateAndCancel()
    do { _ = try await FakeImageHTTP().boundedData(for: boundedRequest("valid"), maximumBytes: 3); preconditionFailure("unbounded transport used") } catch CFLFailure.requestFailed { }
    let (deniedBody, deniedResponse) = try await boundedHTTP.boundedData(for: boundedRequest("denied"), maximumBytes: 0)
    precondition(deniedBody.isEmpty && (deniedResponse as? HTTPURLResponse)?.statusCode == 401)
    let (_, redirectResponse) = try await boundedHTTP.boundedData(for: boundedRequest("redirect"), maximumBytes: 0)
    precondition((redirectResponse as? HTTPURLResponse)?.statusCode == 302)

    let authHTTP = FakeFileHTTP(), authSocket = FakeSocket(snapshot: fileSnapshot())
    let auth = CFLAuthorization(store: ImageTestCredentials(), http: authHTTP)
    try await auth.select(origin: "https://example.com")
    let authorized = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: CFLAuthorizedHTTP(authorization: auth, http: authHTTP), transport: { authSocket })
    await authorized.connect(); let authorizedState = await authorized.currentState()
    _ = try await authorized.downloadFile(authorizedState.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: authorizedState.sessionRevision)
    let authRequests = await authHTTP.allRequests(), authLimits = await authHTTP.allLimits()
    precondition(authLimits == [3] && authRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" && authRequests.last?.value(forHTTPHeaderField: "Origin") == "https://example.com")
    for status in [401, 403] {
        await authHTTP.setDownload(status: status)
        do { _ = try await authorized.downloadFile(authorizedState.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: authorizedState.sessionRevision); preconditionFailure("authorization failure accepted") } catch CFLFailure.offline { }
        let afterFailure = await authHTTP.allRequests()
        precondition(afterFailure.last?.url?.path == "/api/auth/status")
    }
    await authorized.disconnect()

    let png = Data([137,80,78,71,13,10,26,10,1]), jpeg = Data([255,216,255,1])
    let image = CFLPreparedImage(id: "image", name: "x.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg)
    let mixedSocket = FakeSocket(snapshot: fileSnapshot()), mixedHTTP = FakeFileHTTP(), mixedStore = MemoryStore()
    let mixed = CFLChatClient(target: "https://example.com", store: mixedStore, imageHTTP: mixedHTTP, transport: { mixedSocket })
    await mixed.connect(); _ = try await mixed.send("mixed", images: [image], files: files)
    let mixedCalls = await mixedSocket.arguments(for: "submit"), mixedEntries = await mixedStore.entries
    precondition(mixedCalls[0][0].object?["images"]?.array?.count == 1 && mixedCalls[0][0].object?["files"]?.array?.count == 2 && mixedEntries[0].files?.count == 2)
    await mixed.disconnect()

    // A known failed first save removes staged previews; a committed save
    // retains them and the complete file references for explicit recovery.
    for committed in [false, true] {
        let socket = FakeSocket(snapshot: fileSnapshot()), http = FakeFileHTTP(), store = MemoryStore()
        let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
        await client.connect(); await store.failNextSave(afterCommit: committed)
        do { _ = try await client.send("mixed", images: [image], files: files); precondition(committed) }
        catch CFLFailure.storage { precondition(!committed) }
        let state = await client.currentState(), saved = await store.entries, methods = await socket.methods()
        precondition((state.localPreviews.count == 1) == committed && (saved.first?.files?.count == 2) == committed && !methods.contains("submit"))
        await client.disconnect()
    }

    let capSocket = FakeSocket(snapshot: fileSnapshot()), capHTTP = FakeFileHTTP(), capStore = MemoryStore()
    let capClient = CFLChatClient(target: "https://example.com", store: capStore, imageHTTP: capHTTP, transport: { capSocket })
    await capClient.connect(); await capHTTP.setHold()
    let mixedPending = Task { try await capClient.send("mixed", images: [image], files: files) }
    for _ in 0..<200 { if await capHTTP.isHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let capHeld = await capHTTP.isHeld(), beforeChange = await capClient.currentState()
    precondition(capHeld && beforeChange.localPreviews.count == 1)
    let changedCapabilities: ChordJSON = .object(["text": .bool(true), "stop": .bool(true),
        "images": .object(["mediaTypes": .array([.string("image/png")]), "maxImagesPerMessage": .number(2), "maxImageBytes": .number(100), "maxMessageImageBytes": .number(150)]),
        "files": .object(["maxFilesPerMessage": .number(1), "maxFileBytes": .number(5), "maxMessageFileBytes": .number(6)])])
    try await capSocket.emit(update(sequence: 1, field: "capabilities", value: changedCapabilities))
    for _ in 0..<200 { if await capClient.currentState().fileLimits?.maxFilesPerMessage == 1 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await capHTTP.release()
    do { _ = try await mixedPending.value; preconditionFailure("changed capability accepted") } catch is CFLFileStagingUncertain { }
    let capState = await capClient.currentState(), capEntries = await capStore.entries, capMethods = await capSocket.methods()
    precondition(capState.localPreviews.isEmpty && capEntries.isEmpty && !capMethods.contains("submit"))
    await capClient.disconnect()

    let mixedRaceSocket = FakeSocket(snapshot: fileSnapshot()), mixedRaceHTTP = FakeFileHTTP(), mixedRaceStore = MemoryStore()
    let mixedRace = CFLChatClient(target: "https://example.com", store: mixedRaceStore, imageHTTP: mixedRaceHTTP, transport: { mixedRaceSocket })
    await mixedRace.connect(); await mixedRaceHTTP.setHold()
    let mixedRaceTask = Task { try await mixedRace.send("mixed", images: [image], files: files) }
    for _ in 0..<200 { if await mixedRaceHTTP.isHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let mixedHeld = await mixedRaceHTTP.isHeld(); precondition(mixedHeld)
    try await mixedRaceSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await mixedRace.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await mixedRaceSocket.emit(update(sequence: 2, field: "sessionId", value: .string("A")))
    for _ in 0..<200 { if await mixedRace.currentState().sessionId == "A" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await mixedRaceHTTP.release()
    do { _ = try await mixedRaceTask.value; preconditionFailure("mixed session changed") } catch is CFLFileStagingUncertain { }
    let mixedRaceState = await mixedRace.currentState(), mixedRaceEntries = await mixedRaceStore.entries, mixedRaceMethods = await mixedRaceSocket.methods()
    precondition(mixedRaceState.localPreviews.isEmpty && mixedRaceEntries.isEmpty && !mixedRaceMethods.contains("submit"))
    await mixedRace.disconnect()

    for fault in ["order", "duplicate", "size", "extra", "session", "operation"] {
        let badSocket = FakeSocket(snapshot: fileSnapshot()), badHTTP = FakeFileHTTP(), badStore = MemoryStore()
        await badHTTP.setMalformed(fault)
        let bad = CFLChatClient(target: "https://example.com", store: badStore, imageHTTP: badHTTP, transport: { badSocket })
        await bad.connect()
        do { _ = try await bad.send("", files: files); preconditionFailure("malformed upload accepted") } catch is CFLFileStagingUncertain { }
        let methods = await badSocket.methods(), entries = await badStore.entries
        precondition(!methods.contains("submit") && entries.isEmpty)
        await bad.disconnect()
    }
    let source = UUID().uuidString, attempt = UUID().uuidString
    let originals = ["a", "b"].map { CFLFileRef(attachmentId: $0, name: "note.txt", mediaType: "", size: 3, availability: "available") }
    // Extra fields from the abandoned snapshot design do not discard the
    // ordinary pending identity, admission marker, text or durable file refs.
    let persisted = CFLPending(target: "https://example.com", sessionId: "A", operationId: attempt, text: "kept", createdAt: Date(), dispatched: true, status: .unknown, retrySource: source, files: originals)
    let encoded = try JSONEncoder().encode(persisted)
    var oldFields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    oldFields["fileSnapshotRecords"] = [["id": "local-only", "filename": "unused"]]
    oldFields["fileStagingOperationId"] = source
    let decoded = try JSONDecoder().decode(CFLPending.self, from: JSONSerialization.data(withJSONObject: oldFields))
    let savedAgain = try JSONDecoder().decode(CFLPending.self, from: JSONEncoder().encode(decoded))
    precondition(savedAgain.operationId == attempt && savedAgain.text == "kept" && savedAgain.dispatched && savedAgain.status == .unknown && savedAgain.retrySource == source && savedAgain.files == originals)
    let good = fileRetryReceipt(attempt: attempt, source: source)
    let badReceipts: [ChordJSON] = [fileRetryReceipt(attempt: attempt, source: source, session: "B"),
        fileRetryReceipt(attempt: attempt, source: source, old: ["a", "a"]), fileRetryReceipt(attempt: attempt, source: source, new: ["x", "x"]),
        fileRetryReceipt(attempt: attempt, source: source, size: 4),
        .object(["operationId": .string(attempt), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null])]
    for receipt in [good] + badReceipts {
        let retryStore = MemoryStore(), retrySocket = FakeSocket(snapshot: fileSnapshot(), lookupReceipt: receipt)
        await retryStore.setEntries([CFLPending(target: "https://example.com", sessionId: "A", operationId: attempt, text: "x", createdAt: Date(), dispatched: true, status: .unknown, retrySource: source, files: originals)])
        let retry = CFLChatClient(target: "https://example.com", store: retryStore, imageHTTP: FakeFileHTTP(), transport: { retrySocket })
        await retry.connect(); try? await retry.reconcile()
        let result = await retry.currentState(), methods = await retrySocket.methods()
        if receipt == good { precondition(result.pending.first?.files?.map(\.attachmentId) == ["new_a", "new_b"] && result.pending.first?.status == .submitted) }
        else { precondition(result.pending.first?.status == .unknown && result.pending.first?.files == originals) }
        precondition(!methods.contains("submit") && !methods.contains("retryFailed"))
        await retry.disconnect()
    }
    let identitySocket = FakeSocket(snapshot: fileSnapshot()), identityHTTP = FakeFileHTTP(), identityStore = MemoryStore()
    let identity = CFLChatClient(target: "https://example.com", store: identityStore, imageHTTP: identityHTTP, transport: { identitySocket })
    await identity.connect(); let identityRevision = await identity.currentState().sessionRevision
    let identityID = UUID().uuidString.lowercased()
    _ = try await identity.send("", files: [files[0]], operationId: identityID, expectedSessionId: "A", expectedSessionRevision: identityRevision)
    do { _ = try await identity.send("changed", files: [files[1]], operationId: identityID, expectedSessionId: "A", expectedSessionRevision: identityRevision); preconditionFailure("operation reused") } catch CFLSendFailure.duplicateOperationId { }
    let identityMethods = await identitySocket.methods(); precondition(identityMethods.filter { $0 == "submit" }.count == 1)
    await identity.disconnect()

    let explicitSocket = FakeSocket(snapshot: fileSnapshot()), explicitStore = MemoryStore()
    await explicitSocket.setFailedSubmit()
    let explicit = CFLChatClient(target: "https://example.com", store: explicitStore, imageHTTP: FakeFileHTTP(), transport: { explicitSocket })
    await explicit.connect(); let explicitRevision = await explicit.currentState().sessionRevision
    let failedID = try await explicit.send("", files: [files[0]])
    let mapped: ChordJSON = .object(["operationId": .string("placeholder"), "state": .string("submitted"), "messageId": .null, "turnId": .null, "error": .null,
        "retryFiles": .object(["sessionId": .string("A"), "sourceOperationId": .string(failedID), "files": .array([
            .object(["sourceAttachmentId": .string("file_0"), "ref": fileWire("replacement")])])])])
    await explicitSocket.setRetry(receipt: mapped)
    let retryID = try await explicit.retryFailed(sessionId: "A", operationId: failedID, expectedSessionRevision: explicitRevision)
    let explicitState = await explicit.currentState(), explicitCalls = await explicitSocket.arguments(for: "retryFailed")
    precondition(retryID != failedID && explicitState.pending.first?.files?.first?.attachmentId == "replacement" && explicitState.pending.first?.status == .submitted)
    precondition(explicitCalls.count == 1 && explicitCalls[0][0].object?["attemptId"] == .string(retryID))
    await explicit.disconnect()

    let unknownStore = MemoryStore(), unknownSocket = FakeSocket(snapshot: fileSnapshot(), dropSubmit: true), sockets = SocketSequence([unknownSocket]), unknownHTTP = FakeFileHTTP()
    let unknown = CFLChatClient(target: "https://example.com", store: unknownStore, imageHTTP: unknownHTTP, transport: { try await sockets.next() })
    await unknown.connect(); let unknownID = try await unknown.send("uncertain", files: [files[0]])
    let saved = await unknownStore.entries
    precondition(saved.first?.operationId == unknownID && saved.first?.dispatched == true && saved.first?.files?.first?.attachmentId == "file_0")
    let restoredSocket = FakeSocket(snapshot: fileSnapshot())
    await sockets.append(restoredSocket)
    for _ in 0..<400 { if await restoredSocket.methods().contains("lookup") { break }; try await Task.sleep(nanoseconds: 10_000_000) }
    let restoredMethods = await restoredSocket.methods(), stagingRequests = await unknownHTTP.allRequests()
    precondition(restoredMethods.contains("lookup") && !restoredMethods.contains("submit") && !restoredMethods.contains("retryFailed"))
    precondition(stagingRequests.count == 3 && stagingRequests[0].url?.path == "/api/chat/file-operations" && stagingRequests[1].httpMethod == "PUT" && stagingRequests[2].url!.path.hasSuffix("/complete"))
    await unknown.disconnect()

    let raceSocket = FakeSocket(snapshot: fileSnapshot()), raceHTTP = FakeFileHTTP(), raceStore = MemoryStore()
    let race = CFLChatClient(target: "https://example.com", store: raceStore, imageHTTP: raceHTTP, transport: { raceSocket })
    await race.connect(); let revision = await race.currentState().sessionRevision; await raceHTTP.setHold()
    let pending = Task { try await race.send("", files: files, expectedSessionId: "A", expectedSessionRevision: revision) }
    for _ in 0..<200 { if await raceHTTP.isHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let uploadHeld = await raceHTTP.isHeld(); precondition(uploadHeld)
    try await raceSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await race.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await raceHTTP.release()
    do { _ = try await pending.value; preconditionFailure("stale upload") } catch is CFLFileStagingUncertain { }
    let raceMethods = await raceSocket.methods(), raceEntries = await raceStore.entries
    precondition(!raceMethods.contains("submit") && raceEntries.isEmpty)
    await race.disconnect()
    let downloadSocket = FakeSocket(snapshot: fileSnapshot()), downloadHTTP = FakeFileHTTP()
    let download = CFLChatClient(target: "https://example.com", store: MemoryStore(), imageHTTP: downloadHTTP, transport: { downloadSocket })
    await download.connect(); let downloadState = await download.currentState(); await downloadHTTP.setHold()
    let reading = Task { try await download.downloadFile(downloadState.messages[0].files![0], directory: testRoot, expectedSessionId: "A", expectedSessionRevision: downloadState.sessionRevision) }
    for _ in 0..<200 { if await downloadHTTP.isHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let downloadHeld = await downloadHTTP.isHeld(); precondition(downloadHeld)
    try await downloadSocket.emit(update(sequence: 1, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await download.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await downloadHTTP.release()
    do { _ = try await reading.value; preconditionFailure("stale download") } catch CFLFailure.sessionChanged { }
    await download.disconnect()
    print("CFL file checks passed")
}

#endif

#if canImport(CryptoKit)
actor FakeStreamingFileHTTP: CFLImageHTTP {
    var manifest: [String: Any] = [:]
    var received: [String] = []
    var requests: [String] = []
    var authorizationHeaders: [String] = []
    var loseUpload = false
    var loseReserve = false
    var cancelUpload = false
    var loseComplete = false
    var badManifest = false
    var holdUpload = false
    var uploadContinuation: CheckedContinuation<Void, Never>?
    var maxChunk = 0
    var totalUploaded = 0
    var retiredPhase: String?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw CFLFailure.requestFailed }
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let path = request.url!.path; requests.append("\(request.httpMethod ?? "GET") \(path)")
        if let authorization = request.value(forHTTPHeaderField: "Authorization") { authorizationHeaders.append(authorization) }
        if (retiredPhase == "reserve" && path == "/api/chat/file-operations") || (retiredPhase == "complete" && path.hasSuffix("/complete")) {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!)
        }
        if path == "/api/chat/file-operations" {
            manifest = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if loseReserve { throw CFLFailure.offline }
        }
        let items = manifest["files"] as! [[String: Any]]
        var returnedManifest = manifest
        if badManifest { returnedManifest["sessionId"] = "wrong-session" }
        var status: [String: Any] = ["manifest": returnedManifest, "uploaded": received]
        let result: [String: Any] = ["sessionId": manifest["sessionId"]!, "operationId": manifest["operationId"]!, "files": items.enumerated().map { index, item in
            ["id": item["id"]!, "order": index, "ref": ["attachmentId": "stream_\(index)", "name": item["name"]!, "mediaType": item["mediaType"]!, "size": item["size"]!, "availability": "available"]] as [String: Any]
        }]
        if path.hasSuffix("/complete") {
            if loseComplete { throw CFLFailure.offline }
            status = result
        }
        let data = try JSONSerialization.data(withJSONObject: status)
        guard data.count <= maximumBytes else { throw CFLFailure.protocolError }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func uploadFile(for request: URLRequest, from file: URL, maximumResponseBytes: Int) async throws -> (Data, URLResponse) {
        requests.append("PUT \(request.url!.path)")
        if let authorization = request.value(forHTTPHeaderField: "Authorization") { authorizationHeaders.append(authorization) }
        if retiredPhase == "upload" { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!) }
        let id = request.url!.lastPathComponent
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var count = 0
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            count += chunk.count; maxChunk = max(maxChunk, chunk.count)
            await Task.yield()
        }
        totalUploaded += count
        let items = manifest["files"] as! [[String: Any]]
        guard let item = items.first(where: { $0["id"] as? String == id }), item["size"] as? Int == count else { throw CFLFailure.protocolError }
        received.append(id)
        if holdUpload { await withCheckedContinuation { uploadContinuation = $0 }; holdUpload = false }
        if loseUpload { throw CFLFailure.offline }
        if cancelUpload { throw CancellationError() }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
    func downloadFile(for request: URLRequest, to destination: URL, maximumBytes: Int) async throws -> URLResponse {
        guard maximumBytes >= 3 else { throw CFLFailure.protocolError }
        try Data([1, 2, 3]).write(to: destination)
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    func setLost() { loseUpload = true }
    func setLostReserve() { loseReserve = true }
    func setRetired(_ phase: String) { retiredPhase = phase }
    func setCancelled() { cancelUpload = true }
    func setLostComplete() { loseComplete = true }
    func setBadManifest() { badManifest = true }
    func setHoldUpload() { holdUpload = true }
    func isUploadHeld() -> Bool { uploadContinuation != nil }
    func releaseUpload() { uploadContinuation?.resume(); uploadContinuation = nil }
    func transferCounts() -> (Int, Int) { (maxChunk, totalUploaded) }
    func allRequests() -> [String] { requests }
    func allAuthorizationHeaders() -> [String] { authorizationHeaders }
}

final class FileRefreshCredentials: CFLCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value = CFLCredentials(accessToken: "initial", refreshToken: "initial-refresh", expiresAt: .distantFuture)
    func load(origin: String) throws -> CFLCredentials? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func save(_ credentials: CFLCredentials, origin: String) throws {
        lock.lock(); defer { lock.unlock() }
        value = credentials
    }
}

actor FileRefreshHTTP: CFLImageHTTP {
    private var count = 0
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        count += 1
        let body = try JSONSerialization.data(withJSONObject: ["access_token": "refreshed-\(count)",
            "refresh_token": "refresh-\(count)", "expires_in": 3600, "token_type": "Bearer"])
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
func checkFileCopyCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("etos-copy-cancel-test-" + UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = directory.appendingPathComponent("keep")
    try Data([9]).write(to: sentinel)
    let empty = root.appendingPathComponent("empty")
    try Data().write(to: empty)
    let start = DispatchSemaphore(value: 0)
    let alreadyCancelled = Task.detached {
        start.wait()
        return try CFLFileDraftStorage.copy(source: empty, directory: directory, name: "empty", mediaType: "", maximumBytes: 0)
    }
    alreadyCancelled.cancel(); start.signal()
    do { _ = try await alreadyCancelled.value; preconditionFailure("cancelled empty copy returned") } catch is CancellationError { }
    let afterEmpty = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    precondition(afterEmpty == ["keep"])

    // Pause after a real write, then cancel before the next read or EOF check.
    // Exercise both a partial multi-chunk copy and cancellation at the last chunk.
    for count in [3, 131_073] {
        let source = root.appendingPathComponent("source-\(count)")
        try Data(repeating: 7, count: count).write(to: source)
        let wrote = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let copying = Task.detached {
            try CFLFileDraftStorage.copy(source: source, directory: directory, name: "fixture", mediaType: "",
                                         maximumBytes: count, didCopyChunk: { _ in wrote.signal(); resume.wait() })
        }
        var observedWrite = false
        for _ in 0..<400 {
            if wrote.wait(timeout: .now()) == .success { observedWrite = true; break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard observedWrite else { copying.cancel(); resume.signal(); _ = try? await copying.value; throw CFLFailure.requestFailed }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(entries.count == 2 && entries.contains("keep"))
        let partial = directory.appendingPathComponent(entries.first { $0 != "keep" }!)
        let partialSize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(partialSize == min(count, 64 * 1024))
        copying.cancel(); resume.signal()
        do { _ = try await copying.value; preconditionFailure("cancelled copy returned") } catch is CancellationError { }
        let afterCancellation = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(afterCancellation == ["keep"])
    }
    let source = root.appendingPathComponent("budget")
    try Data([1, 2, 3]).write(to: source)
    do { _ = try CFLFileDraftStorage.copy(source: source, directory: directory, name: "budget", mediaType: "", maximumBytes: 2); preconditionFailure("copy exceeded remaining budget") } catch CFLFailure.invalidInput { }
    let allowed = try CFLFileDraftStorage.copy(source: source, directory: directory, name: "budget", mediaType: "", maximumBytes: 3)
    precondition(allowed.size == 3)
    try CFLFileDraftStorage.remove(allowed)
    let afterBudget = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    precondition(afterBudget == ["keep"])
}

func checkStreamingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("etos-file-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    precondition(CFLFileRef(attachmentId: "max", name: "n", mediaType: "", size: 100_000_000, availability: "missing").valid)
    precondition(!CFLFileRef(attachmentId: "max", name: "n", mediaType: "", size: 100_000_001, availability: "available").valid)
    let source = root.appendingPathComponent("fixture")
    try Data([1, 2, 3]).write(to: source)
    let draft = try CFLFileDraftStorage.copy(source: source, directory: root.appendingPathComponent("snapshots"), name: "a", mediaType: "")
    let emptySource = root.appendingPathComponent("empty"); try Data().write(to: emptySource)
    let empty = try CFLFileDraftStorage.copy(source: emptySource, directory: root.appendingPathComponent("snapshots"), name: "empty", mediaType: "")
    precondition(draft.size == 3 && empty.size == 0)
    try Data([9, 9, 9]).write(to: source)
    let originalSnapshot = try Data(contentsOf: draft.ownedFileURL)
    precondition(originalSnapshot == Data([1, 2, 3]))
    // Even a small advertised capability uses the same file-backed streaming protocol.
    let smallSocket = FakeSocket(snapshot: fileSnapshot()), smallHTTP = FakeFileHTTP(), smallStore = MemoryStore()
    let small = CFLChatClient(target: "https://example.com", store: smallStore, imageHTTP: smallHTTP, transport: { smallSocket })
    await small.connect(); _ = try await small.send("", files: [draft, empty])
    let smallRequests = await smallHTTP.allRequests(), smallBytes = await smallHTTP.uploadedData(), smallPending = await smallStore.entries
    precondition(smallRequests.count == 4 && smallRequests[0].url?.path == "/api/chat/file-operations" && smallRequests[1].httpMethod == "PUT" && smallRequests[2].httpMethod == "PUT" && smallRequests[3].url!.path.hasSuffix("/complete"))
    precondition(smallBytes[draft.id] == Data([1, 2, 3]) && smallBytes[empty.id] == Data() && smallPending.first?.files?.map(\.size) == [3, 0])
    await small.disconnect()
    let socket = FakeSocket(snapshot: fileSnapshot()), http = FakeStreamingFileHTTP(), store = MemoryStore()
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
    await client.connect()
    let capabilities: ChordJSON = .object(["text": .bool(true), "stop": .bool(true), "files": .object([
        "maxFilesPerMessage": .number(6), "maxFileBytes": .number(100_000_000), "maxMessageFileBytes": .number(200_000_000)])])
    try await socket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await client.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let bound = await client.currentState(); precondition(bound.fileLimits?.maxFileBytes == 100_000_000)
    let hundred = CFLPreparedFile(id: "hundred", name: "n", mediaType: "", ownedFile: source, size: 100_000_000, sha256: "fake")
    let hundred2 = CFLPreparedFile(id: "hundred2", name: "n", mediaType: "", ownedFile: source, size: 100_000_000, sha256: "fake")
    let extra = CFLPreparedFile(id: "extra", name: "n", mediaType: "", ownedFile: source, size: 1, sha256: "fake")
    try await client.validateFiles([hundred, hundred2])
    let six = (0..<6).map { CFLPreparedFile(id: "zero-\($0)", name: "n", mediaType: "", ownedFile: source, size: 0, sha256: "fake") }
    try await client.validateFiles(six)
    do { try await client.validateFiles(six + [extra]); preconditionFailure("file count exceeded") } catch CFLFailure.invalidInput { }
    do { try await client.validateFiles([hundred, hundred2, extra]); preconditionFailure("aggregate exceeded") } catch CFLFailure.invalidInput { }
    let tooBig = CFLPreparedFile(id: "big", name: "n", mediaType: "", ownedFile: source, size: 100_000_001, sha256: "fake")
    do { try await client.validateFiles([tooBig]); preconditionFailure("single file exceeded") } catch CFLFailure.invalidInput { }
    _ = try await client.send("", files: [draft, empty])
    let calls = await socket.arguments(for: "submit"), requests = await http.allRequests(), entries = await store.entries
    precondition(calls.count == 1 && entries.first?.files?.map(\.size) == [3, 0])
    precondition(requests.count == 4 && requests[0] == "POST /api/chat/file-operations" && requests[3].hasSuffix("/complete"))
    let local = try await client.downloadFile(bound.messages[0].files![0], directory: root, expectedSessionId: "A", expectedSessionRevision: bound.sessionRevision)
    let localBytes = try Data(contentsOf: local); precondition(localBytes == Data([1, 2, 3]))
    try FileManager.default.removeItem(at: local)
    await client.disconnect()
    let tampered = try CFLFileDraftStorage.copy(source: source, directory: root.appendingPathComponent("snapshots"), name: "tampered", mediaType: "")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tampered.ownedFileURL.path)
    try Data([5, 5, 5]).write(to: tampered.ownedFileURL)
    let tamperSocket = FakeSocket(snapshot: fileSnapshot()), tamperHTTP = FakeStreamingFileHTTP(), tamperStore = MemoryStore()
    let tamperClient = CFLChatClient(target: "https://example.com", store: tamperStore, imageHTTP: tamperHTTP, transport: { tamperSocket })
    await tamperClient.connect(); try await tamperSocket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await tamperClient.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    do { _ = try await tamperClient.send("", files: [tampered]); preconditionFailure("tampered snapshot") } catch CFLFailure.invalidInput { }
    let truncated = try CFLFileDraftStorage.copy(source: source, directory: root.appendingPathComponent("snapshots"), name: "short", mediaType: "")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: truncated.ownedFileURL.path)
    try Data([5, 5]).write(to: truncated.ownedFileURL)
    do { _ = try await tamperClient.send("", files: [truncated]); preconditionFailure("truncated snapshot") } catch CFLFailure.invalidInput { }
    let tamperRequests = await tamperHTTP.allRequests(), tamperMethods = await tamperSocket.methods()
    precondition(tamperRequests.isEmpty && !tamperMethods.contains("submit"))
    await tamperClient.disconnect(); try CFLFileDraftStorage.remove(tampered); try CFLFileDraftStorage.remove(truncated)
    let lostSocket = FakeSocket(snapshot: fileSnapshot()), lostHTTP = FakeStreamingFileHTTP(), lostStore = MemoryStore()
    let lost = CFLChatClient(target: "https://example.com", store: lostStore, imageHTTP: lostHTTP, transport: { lostSocket })
    await lost.connect(); try await lostSocket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await lost.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await lostHTTP.setLost()
    do { _ = try await lost.send("", files: [draft]); preconditionFailure("unknown upload") }
    catch is CFLFileStagingUncertain { }
    let lostRequests = await lostHTTP.allRequests(), lostCalls = await lostSocket.methods(), remaining = await lostStore.entries
    precondition(!lostRequests.contains(where: { $0.hasPrefix("GET ") }) && !lostCalls.contains("submit") && remaining.isEmpty)
    precondition(FileManager.default.fileExists(atPath: draft.ownedFileURL.path))
    await lost.disconnect()
    let reserveSocket = FakeSocket(snapshot: fileSnapshot()), reserveHTTP = FakeStreamingFileHTTP(), reserveStore = MemoryStore()
    await reserveHTTP.setLostReserve()
    let reserve = CFLChatClient(target: "https://example.com", store: reserveStore, imageHTTP: reserveHTTP, transport: { reserveSocket })
    await reserve.connect()
    do { _ = try await reserve.send("", files: [draft]); preconditionFailure("lost reservation response accepted") } catch is CFLFileStagingUncertain { }
    let reserveRequests = await reserveHTTP.allRequests(), reserveMethods = await reserveSocket.methods(), reserveEntries = await reserveStore.entries
    precondition(reserveRequests == ["POST /api/chat/file-operations"] && !reserveMethods.contains("submit") && reserveEntries.isEmpty)
    await reserve.disconnect()
    for completeLost in [false, true] {
        let failureSocket = FakeSocket(snapshot: fileSnapshot()), failureHTTP = FakeStreamingFileHTTP(), failureStore = MemoryStore()
        let failure = CFLChatClient(target: "https://example.com", store: failureStore, imageHTTP: failureHTTP, transport: { failureSocket })
        await failure.connect(); try await failureSocket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
        for _ in 0..<200 { if await failure.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        if completeLost { await failureHTTP.setLostComplete() } else { await failureHTTP.setCancelled() }
        do { _ = try await failure.send("", files: [draft]); preconditionFailure("unknown staging") }
        catch is CFLFileStagingUncertain { }
        catch is CancellationError { precondition(!completeLost) }
        let methods = await failureSocket.methods(), retained = await failureStore.entries
        precondition(!methods.contains("submit") && retained.isEmpty && FileManager.default.fileExists(atPath: draft.ownedFileURL.path))
        await failure.disconnect()
    }
    let malformedSocket = FakeSocket(snapshot: fileSnapshot()), malformedHTTP = FakeStreamingFileHTTP(), malformedStore = MemoryStore()
    let malformed = CFLChatClient(target: "https://example.com", store: malformedStore, imageHTTP: malformedHTTP, transport: { malformedSocket })
    await malformed.connect(); try await malformedSocket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await malformed.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await malformedHTTP.setBadManifest()
    do { _ = try await malformed.send("", files: [draft]); preconditionFailure("bad manifest") } catch is CFLFileStagingUncertain { }
    let malformedRequests = await malformedHTTP.allRequests(), malformedMethods = await malformedSocket.methods()
    precondition(!malformedRequests.contains(where: { $0.hasPrefix("PUT ") }) && !malformedMethods.contains("submit"))
    await malformed.disconnect()
    for phase in ["reserve", "upload", "complete"] {
        let socket = FakeSocket(snapshot: fileSnapshot()), http = FakeStreamingFileHTTP(), store = MemoryStore()
        await http.setRetired(phase)
        let retired = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
        await retired.connect()
        do { _ = try await retired.send("", files: [draft]); preconditionFailure("retired staging accepted") } catch is CFLFileOperationRetired { }
        let methods = await socket.methods(), saved = await store.entries, requests = await http.allRequests()
        precondition(!methods.contains("submit") && saved.isEmpty && !requests.contains(where: { $0.hasPrefix("GET ") }))
        await retired.disconnect()
    }
    let raceSocket = FakeSocket(snapshot: fileSnapshot()), raceHTTP = FakeStreamingFileHTTP(), raceStore = MemoryStore()
    let race = CFLChatClient(target: "https://example.com", store: raceStore, imageHTTP: raceHTTP, transport: { raceSocket })
    await race.connect(); try await raceSocket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await race.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await raceHTTP.setHoldUpload()
    let sending = Task { try await race.send("", files: [draft]) }
    for _ in 0..<200 { if await raceHTTP.isUploadHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let held = await raceHTTP.isUploadHeld(); precondition(held)
    try await raceSocket.emit(update(sequence: 2, field: "sessionId", value: .string("B")))
    for _ in 0..<200 { if await race.currentState().sessionId == "B" { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    await raceHTTP.releaseUpload()
    do { _ = try await sending.value; preconditionFailure("session changed") } catch is CFLFileStagingUncertain { }
    let raceMethods = await raceSocket.methods(), raceEntries = await raceStore.entries
    precondition(!raceMethods.contains("submit") && raceEntries.isEmpty && FileManager.default.fileExists(atPath: draft.ownedFileURL.path))
    await race.disconnect()

    // A slow file upload must not delay switching clients. Once disconnected,
    // the old upload cannot persist or submit after the replacement writes.
    let switchStore = MemoryStore()
    let retained = CFLPending(target: "https://example.com", sessionId: "A",
        operationId: "11111111-1111-4111-8111-111111111111", text: "keep",
        createdAt: Date(), dispatched: true, status: .failed)
    try await switchStore.save([retained])
    let oldSocket = FakeSocket(snapshot: fileSnapshot()), oldHTTP = FakeStreamingFileHTTP()
    let oldClient = CFLChatClient(target: "https://example.com", store: switchStore, imageHTTP: oldHTTP, transport: { oldSocket })
    await oldClient.connect(); await oldHTTP.setHoldUpload()
    let oldSend = Task { try await oldClient.send("old", files: [draft]) }
    for _ in 0..<200 { if await oldHTTP.isUploadHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let oldHeld = await oldHTTP.isUploadHeld(); precondition(oldHeld)
    let switchCompleted = CompletionFlag()
    let oldDisconnect = Task { await oldClient.disconnect(); await switchCompleted.complete() }
    for _ in 0..<200 { if await switchCompleted.isComplete() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let disconnectedBeforeUpload = await switchCompleted.isComplete()
    if !disconnectedBeforeUpload { await oldHTTP.releaseUpload() }
    precondition(disconnectedBeforeUpload)
    await oldDisconnect.value
    let newSocket = FakeSocket(snapshot: fileSnapshot())
    let newClient = CFLChatClient(target: "https://other.example", store: switchStore, transport: { newSocket })
    await newClient.connect()
    let newID = try await newClient.send("new")
    await oldHTTP.releaseUpload()
    do { _ = try await oldSend.value; preconditionFailure("disconnected upload dispatched") } catch is CFLFileStagingUncertain { }
    let switchedEntries = try await switchStore.load(), oldMethods = await oldSocket.methods()
    precondition(switchedEntries.contains(retained))
    precondition(switchedEntries.contains(where: { $0.target == "https://other.example" && $0.operationId == newID && $0.text == "new" }))
    precondition(!oldMethods.contains("submit"))
    await newClient.disconnect()

    // Token rotation after connection and during upload must not invalidate the
    // same authenticated session or duplicate its submit.
    let refreshSocket = FakeSocket(snapshot: fileSnapshot()), refreshHTTP = FakeStreamingFileHTTP(), refreshStore = MemoryStore()
    let authorization = CFLAuthorization(store: FileRefreshCredentials(), http: FileRefreshHTTP())
    try await authorization.select(origin: "https://example.com")
    let refreshClient = CFLChatClient(target: "https://example.com", store: refreshStore,
        imageHTTP: CFLAuthorizedHTTP(authorization: authorization, http: refreshHTTP), transport: { refreshSocket })
    await refreshClient.connect()
    _ = try await authorization.accessToken(forceRefresh: true)
    await refreshHTTP.setHoldUpload()
    let refreshedSend = Task { try await refreshClient.send("", files: [draft]) }
    for _ in 0..<200 { if await refreshHTTP.isUploadHeld() { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    let refreshHeld = await refreshHTTP.isUploadHeld(); precondition(refreshHeld)
    _ = try await authorization.accessToken(forceRefresh: true)
    await refreshHTTP.releaseUpload()
    _ = try await refreshedSend.value
    let headers = await refreshHTTP.allAuthorizationHeaders(), refreshMethods = await refreshSocket.methods()
    precondition(headers == ["Bearer refreshed-1", "Bearer refreshed-1", "Bearer refreshed-2"])
    precondition(refreshMethods.filter { $0 == "submit" }.count == 1)
    await refreshClient.disconnect()

    try CFLFileDraftStorage.remove(draft); try CFLFileDraftStorage.remove(empty)
}
func checkLargeStreamingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("etos-large-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    guard FileManager.default.createFile(atPath: source.path, contents: nil) else { throw CFLFailure.storage }
    let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: 100_000_000); try handle.close()
    let oversizedSource = root.appendingPathComponent("oversized")
    guard FileManager.default.createFile(atPath: oversizedSource.path, contents: nil) else { throw CFLFailure.storage }
    let oversizedHandle = try FileHandle(forWritingTo: oversizedSource); try oversizedHandle.truncate(atOffset: 100_000_001); try oversizedHandle.close()
    do { _ = try CFLFileDraftStorage.copy(source: oversizedSource, directory: root.appendingPathComponent("snapshots"), name: "oversized", mediaType: ""); preconditionFailure("oversized snapshot") } catch CFLFailure.invalidInput { }
    let a = try CFLFileDraftStorage.copy(source: source, directory: root.appendingPathComponent("snapshots"), name: "a", mediaType: "")
    let b = try CFLFileDraftStorage.copy(source: source, directory: root.appendingPathComponent("snapshots"), name: "b", mediaType: "")
    let socket = FakeSocket(snapshot: fileSnapshot()), http = FakeStreamingFileHTTP(), store = MemoryStore()
    let client = CFLChatClient(target: "https://example.com", store: store, imageHTTP: http, transport: { socket })
    await client.connect()
    let capabilities: ChordJSON = .object(["text": .bool(true), "stop": .bool(true), "files": .object([
        "maxFilesPerMessage": .number(6), "maxFileBytes": .number(100_000_000), "maxMessageFileBytes": .number(200_000_000)])])
    try await socket.emit(update(sequence: 1, field: "capabilities", value: capabilities))
    for _ in 0..<200 { if await client.currentState().fileLimits?.maxFileBytes == 100_000_000 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    _ = try await client.send("", files: [a, b])
    let counts = await http.transferCounts(), entries = await store.entries
    precondition(counts.0 <= 65536 && counts.1 == 200_000_000 && entries.first?.files?.map(\.size) == [100_000_000, 100_000_000])
    await client.disconnect()
}
#endif

#if !CFL_SOURCE_CHECKS
@main
#endif
struct CFLChatChecks {
    static func main() async throws {
        #if canImport(CryptoKit)
        if CommandLine.arguments.dropFirst().elementsEqual(["--large-files-only"]) { try await checkLargeStreamingFiles(); return }
        #endif
        if CommandLine.arguments.dropFirst().elementsEqual(["--bounded-auth-only"]) { try await checkBoundedAuthErrorBodies(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--files-only"]) {
            try await checkBoundedAuthErrorBodies()
            #if canImport(CryptoKit)
            try await checkFileCopyCancellation()
            try await checkFiles()
            try await checkStreamingFiles()
            #endif
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--stickers-only"]) { try await checkStickers(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--timeout-only"]) { try await checkHistoryTimeout(); print("CFL history timeout checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--ordered-only"]) { try await checkOrderedTimeline(); print("CFL ordered timeline checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--view-window-only"]) { try await checkViewItemAndWindowContinuity(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--retry-only"]) { try await checkRetryImages(); print("CFL retry image checks passed"); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--voice-only"]) { try await checkVoiceMessages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--external-images-only"]) { try await checkExternalMarkdownImages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--markdown-images-only"]) { try await checkMarkdownImages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--reminders-only"]) { try await checkReminderSources(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--images-only"]) { try await checkImages(); return }
        if CommandLine.arguments.dropFirst().elementsEqual(["--send-identity-only"]) { try await checkCallerSendIdentity(); return }
        try await checkBoundedAuthErrorBodies()
        #if canImport(CryptoKit)
        try await checkFileCopyCancellation()
        try await checkFiles()
        #endif
        try await checkReplySourceContract()
        try await checkCallerSendIdentity()
        try await checkStickers()
        try await checkReminderSources()
        try await checkViewItemAndWindowContinuity()
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
            let current = await restored.currentState().pending
            if current.first?.status == .submitted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let recovered = await restored.currentState().pending; precondition(recovered[0].status == .submitted && recovered[0].operationId == saved[0].operationId)
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
