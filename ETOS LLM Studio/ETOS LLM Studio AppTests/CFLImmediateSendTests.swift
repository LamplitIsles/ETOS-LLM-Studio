import Combine
import Foundation
import Testing
import ExyteChat
@testable import ETOSCore
@testable import ETOS_LLM_Studio_App

private actor ImmediateStore: CFLPendingStore {
    private var entries: [CFLPending] = []
    private var failures: Int
    private var uncertainFirstSave: Bool
    private var failNextLoad = false
    init(failures: Int = 0, uncertainFirstSave: Bool = false) {
        self.failures = failures
        self.uncertainFirstSave = uncertainFirstSave
    }
    func load() throws -> [CFLPending] {
        if failNextLoad { failNextLoad = false; throw CFLFailure.storage }
        return entries
    }
    func save(_ entries: [CFLPending]) throws {
        if failures > 0 { failures -= 1; throw CFLFailure.storage }
        self.entries = entries
        if uncertainFirstSave {
            uncertainFirstSave = false
            failNextLoad = true
            throw CFLFailure.storage
        }
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
                "capabilities": .object(["text": .bool(true), "stop": .bool(true), "images": limits,
                    "files": .object(["maxFilesPerMessage": .number(6), "maxFileBytes": .number(100_000_000), "maxMessageFileBytes": .number(200_000_000)])]),
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

private actor ImmediateFiles: CFLImageHTTP {
    private var manifest: [String: Any]?
    private var uploaded: [String] = []
    func data(for request: URLRequest) throws -> (Data, URLResponse) { throw CFLFailure.requestFailed }
    func boundedData(for request: URLRequest, maximumBytes: Int) throws -> (Data, URLResponse) {
        let url = request.url!
        let status: Int
        let value: [String: Any]
        if request.httpMethod == "GET" {
            status = manifest == nil ? 404 : 200
            value = manifest.map { ["manifest": $0, "uploaded": uploaded] } ?? [:]
        } else if url.path.hasSuffix("/complete"), let manifest {
            status = 200
            let files = manifest["files"] as! [[String: Any]]
            value = ["sessionId": manifest["sessionId"]!, "operationId": manifest["operationId"]!,
                "files": files.enumerated().map { index, file in
                    ["id": file["id"]!, "order": index, "ref": ["attachmentId": "saved-\(index)", "name": file["name"]!,
                        "mediaType": file["mediaType"]!, "size": file["size"]!, "availability": "available"]] as [String: Any]
                }]
        } else {
            status = 200
            manifest = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
            value = ["manifest": manifest!, "uploaded": uploaded]
        }
        return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func uploadFile(for request: URLRequest, from file: URL, maximumResponseBytes: Int) throws -> (Data, URLResponse) {
        uploaded.append(request.url!.lastPathComponent)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }
    func uploadedIDs() -> [String] { uploaded }
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
    @Test("A file-only send appears immediately with its actual name and size")
    func fileOnlyAppearsImmediately() async throws {
        let socket = ImmediateSocket()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(), imageHTTP: ImmediateFiles(), transport: { socket })
        await client.connect()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("etos-file-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        let file = CFLSelectedFile(prepared: try CFLFileDraftStorage.copy(source: source, directory: fixture,
            name: "notes.txt", mediaType: "text/plain"))
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: await client.currentState(),
                                         initialFiles: [file], draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        var draft = ""
        #expect(model.sendImmediately(draft) { draft = "" })
        #expect(model.selectedFiles.isEmpty)
        #expect(model.visibleMessages.last?.files.first?.name == "notes.txt")
        #expect(model.visibleMessages.last?.files.first?.size == 3)
        for _ in 0..<1000 where await socket.submittedOperations().isEmpty { await Task.yield() }
        let operations = await socket.submittedOperations()
        #expect(operations.count == 1)
        try #require(!operations.isEmpty)
        try await socket.releaseFirst()
        await client.disconnect()
    }

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

    @Test("An uncertain local save pauses queued sends until inspection")
    func uncertainSavePausesQueue() async throws {
        let socket = ImmediateSocket(), filesHTTP = ImmediateFiles()
        let client = CFLChatClient(target: "https://example.invalid", store: ImmediateStore(uncertainFirstSave: true), imageHTTP: filesHTTP, transport: { socket })
        await client.connect()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("etos-file-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        let file = CFLSelectedFile(prepared: try CFLFileDraftStorage.copy(source: source, directory: fixture,
            name: "notes.txt", mediaType: "text/plain"))
        let model = CFLConversationModel(client: client, target: "https://example.invalid", initialState: await client.currentState(),
                                         initialFiles: [file],
                                         draftChanges: Empty<String, Never>().eraseToAnyPublisher())
        #expect(model.sendImmediately("first") {})
        #expect(model.sendImmediately("second") {})
        for _ in 0..<1000 where model.uncertain == nil || model.retryIsBusy { await Task.yield() }
        let first = try #require(model.uncertain)
        #expect(first.text == "first")
        #expect(await filesHTTP.uploadedIDs() == [file.id])
        #expect(await socket.submittedOperations().isEmpty)
        await model.refresh()
        #expect(model.uncertain == nil)
        for _ in 0..<1000 where await socket.submittedOperations().isEmpty { await Task.yield() }
        let operations = await socket.submittedOperations()
        #expect(operations.count == 1)
        #expect(operations.first != first.operationId)
        try #require(!operations.isEmpty)
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
