import Combine
import Foundation
import Testing
import ExyteChat
@testable import ETOSCore
@testable import ETOS_LLM_Studio_App

private actor ImmediateStore: CFLPendingStore {
    private var entries: [CFLPending] = []
    private var failures: Int
    init(failures: Int = 0) { self.failures = failures }
    func load() -> [CFLPending] { entries }
    func save(_ entries: [CFLPending]) throws {
        if failures > 0 { failures -= 1; throw CFLFailure.storage }
        self.entries = entries
    }
}

private actor ImmediateSocket: CFLChatTransport {
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var held: [(String, String)] = []
    private var operations: [String] = []
    private var closed = false

    func send(_ text: String) throws {
        let call = try JSONDecoder().decode(ChordJSON.self, from: Data(text.utf8)).object!
        let id = call["id"]!.string!, command = call["call"]!.object!
        let method = command["member"]!.string!, args = command["args"]!.array!
        if method == "submit" {
            let operation = args[0].object!["operationId"]!.string!
            operations.append(operation); held.append((id, operation)); return
        }
        let result: ChordJSON
        if method == "subscribe" {
            let limits: ChordJSON = .object(["mediaTypes": .array([.string("image/png")]), "maxImagesPerMessage": .number(2),
                "maxImageBytes": .number(100), "maxMessageImageBytes": .number(150)])
            let view: ChordJSON = .object(["version": .number(2), "sessionId": .string("A"), "name": .string("test"),
                "activeTurnId": .null, "contextUsage": .null, "compaction": .null, "recovery": .array([]),
                "capabilities": .object(["text": .bool(true), "stop": .bool(true), "images": limits]),
                "messages": .array([]), "before": .null])
            result = .object(["serviceId": .string("lamplit.chat.v2"), "mode": .string("singleton"),
                "instances": .array([.object(["members": .array([.object(["name": .string("view"), "kind": .string("state"),
                    "sequence": .number(0), "ops": .array([.array([.string("r"), view])])])])])])])
        } else { result = .null }
        try enqueue(.object(["type": .string("result"), "id": .string(id), "result": result]))
    }

    private func enqueue(_ frame: ChordJSON) throws {
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: text) } else { queue.append(text) }
    }
    func receive() async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CFLFailure.offline }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() { closed = true; waiter?.resume(throwing: CFLFailure.offline); waiter = nil }
    func submittedOperations() -> [String] { operations }
    func releaseFirst() throws {
        let (id, operation) = held.removeFirst()
        let receipt: ChordJSON = .object(["operationId": .string(operation), "state": .string("submitted"),
            "messageId": .null, "turnId": .null, "error": .null])
        try enqueue(.object(["type": .string("result"), "id": .string(id), "result": receipt]))
    }
    func observe(operation: String, text: String) throws {
        let message: ChordJSON = .object(["id": .string("server-message"), "role": .string("user"),
            "text": .string(text), "createdAt": .number(1), "operationId": .string(operation), "turnId": .null])
        try enqueue(.object(["type": .string("update"), "subscriptionId": .string("view"), "update": .object([
            "type": .string("state"), "member": .string("view"), "sequence": .number(1),
            "ops": .array([.array([.string("s"), .array([.string("messages")]), .array([message])])])
        ])]))
    }
}

private actor ImmediateImages: CFLImageHTTP {
    private var uploaded: [String] = []
    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let operation = body["operationId"] as! String
        uploaded.append(operation)
        let images = (body["images"] as! [[String: Any]]).map { image in
            ["id": image["id"]!, "order": image["order"]!, "ref": ["attachmentId": "stored", "name": image["name"]!,
                "mediaType": image["mediaType"]!, "availability": "available"]] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["sessionId": body["sessionId"]!, "operationId": operation, "images": images])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func operations() -> [String] { uploaded }
}

@MainActor
@Suite("CFL immediate sending")
struct CFLImmediateSendTests {
    @Test("A confirmed message keeps its actual client projection and visible row")
    func confirmationKeepsVisibleRow() async throws {
        let socket = ImmediateSocket()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(), transport: { socket })
        await client.connect()
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: await client.currentState(),
                                         draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        var draft = "hello"
        #expect(model.sendImmediately(draft) { draft = "" })
        let before = CFLTimelineRow.message(try #require(model.visibleMessages.last)).message
        for _ in 0..<1000 where await socket.submittedOperations().isEmpty { await Task.yield() }
        let operation = try #require(await socket.submittedOperations().first)
        var projectedAfterObservation = false
        let observation = model.$visibleMessages.dropFirst().sink { _ in
            if model.state.messages.contains(where: { $0.operationId == operation }) { projectedAfterObservation = true }
        }
        try await socket.releaseFirst()
        try await socket.observe(operation: operation, text: "hello")
        for _ in 0..<1000 where !projectedAfterObservation { await Task.yield() }
        #expect(model.state.messages.first?.operationId == operation)
        #expect(projectedAfterObservation)
        let projected = CFLTimelineRow.message(try #require(model.visibleMessages.last)).message
        let after = try #require(model.timelineRows.first?.message)
        #expect(projected == before)
        #expect(after == before)
        #expect(model.timelineRows.count == 1 && draft.isEmpty)
        withExtendedLifetime(observation) {}
        await client.disconnect()
    }

    @Test("Text and image appear before submit returns; a second draft is preserved and sent in order")
    func sendsImmediatelyAndSerially() async throws {
        let socket = ImmediateSocket(), http = ImmediateImages()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(), imageHTTP: http, transport: { socket })
        await client.connect()
        let state = await client.currentState()
        #expect(state.connection == .online)
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1]), jpeg = Data([255, 216, 255, 1])
        let prepared = CFLPreparedImage(id: "draft-image", name: "photo.png", mediaType: "image/png", original: png, preview: jpeg, model: jpeg)
        let id = UUID()
        let image = CFLSelectedImage(id: id, attachment: ImageAttachment(id: id, data: png, mimeType: "image/png", fileName: "photo.png", thumbnailData: jpeg), prepared: prepared)
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: state, initialImages: [image],
                                         draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        var draft = "first"
        #expect(model.sendImmediately(draft) { draft = "" })
        #expect(draft.isEmpty && model.selectedImages.isEmpty)
        #expect(model.visibleMessages.last?.text == "first" && model.visibleMessages.last?.previews.count == 1)
        let firstRow = try #require(model.visibleMessages.last)
        draft = "second"
        #expect(model.sendImmediately(draft) { draft = "" })
        #expect(draft.isEmpty && model.visibleMessages.suffix(2).map(\.text) == ["first", "second"])
        draft = "new draft"
        for _ in 0..<1000 where await socket.submittedOperations().isEmpty { await Task.yield() }
        let firstOperations = await socket.submittedOperations()
        #expect(firstOperations.count == 1)
        #expect(await http.operations() == firstOperations)
        #expect(firstRow.id.message == "local:\(try #require(firstOperations.first))")
        try await socket.releaseFirst()
        for _ in 0..<1000 where await socket.submittedOperations().count < 2 { await Task.yield() }
        let operations = await socket.submittedOperations()
        #expect(operations.count == 2)
        #expect(try #require(operations.last) != #require(operations.first))
        #expect(draft == "new draft")
        try await socket.releaseFirst()
        await client.disconnect()
    }

    @Test("Known offline sends leave the draft untouched")
    func offlineKeepsDraft() async {
        let socket = ImmediateSocket()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(), transport: { socket })
        var state = CFLChatState(); state.connection = .offline; state.sessionId = "A"
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: state,
                                         draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        var draft = "keep"
        #expect(!model.sendImmediately(draft) { draft = "" })
        #expect(draft == "keep" && model.visibleMessages.isEmpty)
    }

    @Test("A definite local save failure stays visible and retries only on request")
    func localFailureCanBeRetried() async throws {
        let socket = ImmediateSocket()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(failures: 1), transport: { socket })
        await client.connect()
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: await client.currentState(),
                                         draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        var draft = "kept"
        #expect(model.sendImmediately(draft) { draft = "" })
        let originalID = try #require(model.visibleMessages.last?.id)
        for _ in 0..<1000 where model.visibleMessages.last?.pending?.status != .failed { await Task.yield() }
        let failure = try #require(model.visibleMessages.last?.pending)
        #expect(failure.status == .failed && !failure.dispatched)
        #expect(await socket.submittedOperations().isEmpty)
        await model.retry(failure)
        for _ in 0..<1000 where await socket.submittedOperations().isEmpty { await Task.yield() }
        #expect(await socket.submittedOperations().count == 1)
        for _ in 0..<1000 where model.visibleMessages.last?.id != originalID { await Task.yield() }
        #expect(model.visibleMessages.last?.id == originalID)
        try await socket.releaseFirst()
        await client.disconnect()
    }
}
