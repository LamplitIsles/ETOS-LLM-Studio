@testable import ETOSCore
import Combine
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("CFL image presentation")
struct CFLImagePresentationTests {
    @Test("Editing a draft and changing it back invalidates the old send snapshot")
    func returningToTheSameDraftDoesNotRestoreItsRevision() {
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        let sentRevision = model.draftRevision
        changes.send("B")
        changes.send("A")
        #expect(model.draftRevision != sentRevision)
    }

    @Test("Leaving and reopening the page invalidates earlier image tasks")
    func leavingPageInvalidatesImageTasks() {
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        let revision = model.imagePageRevision
        model.pageDidDisappear()
        #expect(!model.imagePageActive)
        model.pageDidAppear()
        #expect(model.imagePageActive && model.imagePageRevision != revision)
    }

    @Test("Markdown image retry clears the failure and starts a fresh attempt")
    func markdownImageRetryStartsFreshAttempt() {
        let status = CFLMarkdownImageStatus()
        status.inlineFailure(URL(string: "https://example.invalid/image.png")!, stamp: status.stamp)
        status.retry()
        #expect(!status.inlineFailed && status.attempt == 1)
    }

    @Test("Markdown images cannot load after the page leaves its context")
    func markdownImageDoesNotLoadAfterNavigation() async {
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        let context = CFLMarkdownImageContext(model: model, target: "https://example.invalid", session: "session",
                                              revision: 1, clientID: UUID(), status: CFLMarkdownImageStatus(), originalSources: nil)
        model.pageDidDisappear()
        do {
            _ = try await context.load(URL(string: "https://example.invalid/test.png")!)
            Issue.record("An inactive page must not load an image")
        } catch {
            #expect((error as? CFLFailure) == .sessionChanged)
        }
    }

    @Test("Rendered Markdown keeps the original workspace image destination")
    func markdownImagesSurvivePreparationAndMath() async throws {
        let markdown = "![space](work/a%20b.png)\n\ninline ![percent](work/a%2520b.png) and $x$"
        let prepared = await ETPreparedMarkdownRenderPayload.build(from: markdown)
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        let context = CFLMarkdownImageContext(model: model, target: nil, session: nil, revision: 0,
                                              clientID: UUID(), status: CFLMarkdownImageStatus(),
                                              originalSources: CFLMarkdownImageSources(markdown: markdown))
        let mathSources = try #require(prepared.mathImageSources)
        for rendered in [prepared.imageSources, mathSources] {
            let mapping = context.rendered(sources: rendered.sources)
            #expect(mapping.source(for: try #require(URL(string: "work/a%20b.png"))) == "work/a%20b.png")
            #expect(mapping.source(for: try #require(URL(string: "work/a%2520b.png"))) == "work/a%2520b.png")
        }
    }

    @Test("Images with conflicting original URLs stay unavailable across reply chunks")
    func conflictingMarkdownDestinationsAreUnavailable() throws {
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        let context = CFLMarkdownImageContext(model: model, target: nil, session: nil, revision: 0,
                                              clientID: UUID(), status: CFLMarkdownImageStatus(),
                                              originalSources: CFLMarkdownImageSources(markdown: "![a](work/a%.png)\n\n![b](work/a%25.png)"))
            .rendered(sources: CFLMarkdownImageSources(markdown: "![a](work/a%.png)"))
        #expect(context.source(for: try #require(URL(string: "work/a%.png"))) == nil)
    }

    @Test("Equivalent workspace spellings resolve to the same image")
    func equivalentWorkspaceDestinationsRemainAvailable() throws {
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        let context = CFLMarkdownImageContext(model: model, target: nil, session: nil, revision: 0,
                                              clientID: UUID(), status: CFLMarkdownImageStatus(),
                                              originalSources: CFLMarkdownImageSources(markdown: "![a](<work/a b.png>)\n\n![b](work/a%20b.png)"))
            .rendered(sources: CFLMarkdownImageSources(markdown: "![b](work/a%20b.png)"))
        let source = try #require(context.source(for: URL(string: "work/a%20b.png")!))
        #expect(CFLMarkdownImageSources.areEquivalent(source, "work/a%20b.png"))
    }

    @Test("Streaming keeps an image stable until its mapping changes")
    func streamingImageRevisionTracksItsMapping() async throws {
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.sessionId = "session"
        state.sessionRevision = 1
        func reply(_ text: String) throws -> CFLStreamingReply {
            try JSONDecoder().decode(CFLStreamingReply.self, from: JSONSerialization.data(withJSONObject: [
                "id": "reply", "turnId": "turn", "createdAt": 1, "text": text
            ]))
        }
        state.streamingReply = try reply("![first](work/a%25.png)\n")
        model.state = state
        for _ in 0..<100 where model.visibleReply.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let first = try #require(model.visibleReply.first)

        state.streamingReply = try reply("![first](work/a%25.png)\nMore text\n")
        model.state = state
        for _ in 0..<100 where model.visibleReply.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        let extended = try #require(model.visibleReply.first)
        #expect(first.id == extended.id && first.markdownSourcesRevision == extended.markdownSourcesRevision)

        state.streamingReply = try reply("![first](work/a%25.png)\nMore text\n![conflict](work/a%.png)\n")
        model.state = state
        for _ in 0..<100 where model.visibleReply.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let ambiguous = try #require(model.visibleReply.first)
        #expect(first.id == ambiguous.id && first.markdownSourcesRevision != ambiguous.markdownSourcesRevision)
    }

    @Test("A real navigation invalidates the page even when a picker covers it")
    func navigationOverridesPickerCoverage() {
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        let revision = model.imagePageRevision
        model.imagePickerWillPresent()
        model.pageDidDisappear()
        #expect(model.imagePageActive && model.imagePageRevision == revision)
        model.navigationDidLeavePage()
        #expect(!model.imagePageActive && model.imagePageRevision != revision)
        model.imagePickerDidDismiss()
        model.pageDidAppear()
        #expect(model.imagePageActive && model.imagePageRevision != revision)
    }

    @Test("Assistant images remain attached once, including image-only and more than the input limit")
    func projectsImagesWithoutDroppingOrDuplicatingThem() async throws {
        let refs: [[String: Any]] = (0..<7).map { index in
            ["attachmentId": "image-\(index)", "name": "image-\(index).png",
             "mediaType": "image/png", "availability": "available"]
        }
        let source: [[String: Any]] = [
            ["id": "image-only", "role": "agent", "text": "", "createdAt": 1, "images": refs],
            ["id": "mixed", "role": "agent", "text": "First line\nSecond line", "createdAt": 2, "images": refs],
            ["id": "user", "role": "user", "text": "", "createdAt": 3, "images": [refs[0]]]
        ]
        let messages = try JSONDecoder().decode([CFLMessage].self, from: JSONSerialization.data(withJSONObject: source))
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        var state = CFLChatState()
        state.sessionId = "session"
        state.sessionRevision = 1
        state.messages = messages
        model.state = state
        for _ in 0..<100 where model.visibleMessages.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let only = model.visibleMessages.filter { $0.id.message == "image-only" }
        let mixed = model.visibleMessages.filter { $0.id.message == "mixed" }
        let user = model.visibleMessages.filter { $0.id.message == "user" }
        #expect(only.count == 1)
        #expect(only.first?.images.map(\.attachmentId) == refs.indices.map { "image-\($0)" })
        #expect(mixed.flatMap(\.images).map(\.attachmentId) == refs.indices.map { "image-\($0)" })
        #expect(user.count == 1 && user.first?.outgoing == true && user.first?.images.count == 1)
    }

    @Test("A generating image stays in place before voice and becomes ready without duplicating streaming text")
    func orderedImageAndVoiceRemainStable() async throws {
        let decoder = JSONDecoder()
        func messages(_ ready: Bool) throws -> [CFLMessage] {
            let image: [String: Any] = ready
                ? ["id": "image", "role": "agent", "text": "", "createdAt": 2, "imageState": "ready",
                   "images": [["attachmentId": "photo", "name": "photo.png", "mediaType": "image/png", "availability": "available"]]]
                : ["id": "image", "role": "agent", "text": "", "createdAt": 2, "imageState": "preparing"]
            let source: [[String: Any]] = [
                ["id": "text", "role": "agent", "text": "Hello\n", "createdAt": 1, "textState": "streaming"],
                image,
                ["id": "voice", "role": "agent", "text": "", "createdAt": 3, "voice": ["id": String(repeating: "a", count: 64)]]
            ]
            return try decoder.decode([CFLMessage].self, from: JSONSerialization.data(withJSONObject: source))
        }
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.sessionId = "session"
        state.sessionRevision = 1
        state.messages = try messages(false)
        state.streamingReply = try decoder.decode(CFLStreamingReply.self, from: JSONSerialization.data(withJSONObject: [
            "id": "text", "turnId": "turn", "createdAt": 1, "text": "Hello\n"
        ]))
        model.state = state
        for _ in 0..<100 where model.visibleMessages.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        let before = model.visibleMessages
        try #require(before.count == 3)
        #expect(before.map(\.id.message) == ["text", "image", "voice"])
        #expect(before[1].imageState == .preparing && before[2].voice != nil)
        #expect(model.visibleReply.isEmpty)

        state.messages = try messages(true)
        model.state = state
        for _ in 0..<100 where model.visibleMessages.dropFirst().first?.imageState != .ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.visibleMessages.count == 3)
        #expect(model.visibleMessages.map(\.id) == before.map(\.id))
        #expect(model.visibleMessages[1].images.first?.attachmentId == "photo")
        #expect(model.visibleReply.isEmpty)
    }

    @Test("Two local image previews keep their identities when the message is confirmed")
    func localPreviewsSurviveConfirmation() async throws {
        let session = "session", operation = "operation"
        let bytes = [Data([1, 2]), Data([3, 4])]
        func previews(confirmed: Bool) -> [CFLLocalImagePreview] {
            (0..<2).map { index in
                CFLLocalImagePreview(sessionId: session, operationId: operation, originOperationId: operation,
                                     draftId: "draft-\(index)", order: index,
                                     attachmentId: confirmed ? "image-\(index)" : nil, data: bytes[index])
            }
        }
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.sessionId = session
        state.sessionRevision = 1
        state.localDrafts = [CFLLocalDraft(sessionId: session, operationId: operation, text: "hello", images: previews(confirmed: false))]
        model.state = state
        for _ in 0..<100 where model.visibleMessages.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let draft = try #require(model.visibleMessages.first)
        #expect(draft.previews.map(\.draftId) == ["draft-0", "draft-1"])

        let refs: [[String: Any]] = (0..<2).map { index in
            ["attachmentId": "image-\(index)", "name": "same.png", "mediaType": "image/png", "availability": "available"]
        }
        let source: [[String: Any]] = [["id": "server-message", "role": "user", "text": "hello",
                                        "createdAt": 1, "operationId": operation, "images": refs]]
        state.localDrafts = []
        state.localPreviews = previews(confirmed: true)
        state.messages = try JSONDecoder().decode([CFLMessage].self, from: JSONSerialization.data(withJSONObject: source))
        model.state = state
        for _ in 0..<100 where model.visibleMessages.first?.images.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        let confirmed = try #require(model.visibleMessages.first)
        #expect(model.visibleMessages.count == 1 && confirmed.id == draft.id)
        #expect(confirmed.previews.map(\.draftId) == draft.previews.map(\.draftId))
        #expect(confirmed.previews.map(\.data) == bytes)
    }

    @Test("Pending image messages retain their position as later replies arrive and while a retry is confirmed")
    func pendingImagesStayInTimelinePosition() async throws {
        let session = "session", operation = "operation", attempt = "attempt"
        let preview = CFLLocalImagePreview(sessionId: session, operationId: operation, originOperationId: operation,
                                           draftId: "draft", order: 0, attachmentId: "old-image", data: Data([1, 2]))
        func messages(_ entries: [[String: Any]]) throws -> [CFLMessage] {
            try JSONDecoder().decode([CFLMessage].self, from: JSONSerialization.data(withJSONObject: entries))
        }
        let before: [String: Any] = ["id": "before", "role": "agent", "text": "Before", "createdAt": 1]
        let after: [String: Any] = ["id": "after", "role": "agent", "text": "After", "createdAt": 3]
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.sessionId = session
        state.sessionRevision = 1
        state.messages = try messages([before])
        model.state = state
        state.localDrafts = [CFLLocalDraft(sessionId: session, operationId: operation, text: "Mine", images: [preview])]
        model.state = state
        state.messages = try messages([before, after])
        model.state = state
        for _ in 0..<100 where model.visibleMessages.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleMessages.map(\.id.message) == ["before", "local:operation", "after"])

        let oldRef = CFLImageRef(attachmentId: "old-image", name: "same.png", mediaType: "image/png", availability: "available")
        var pending = CFLPending(target: "target", sessionId: session, operationId: attempt, text: "Mine",
                                 createdAt: Date(), dispatched: true, status: .unknown, images: [oldRef])
        pending.retrySource = operation
        state.localDrafts = []
        state.localPreviews = [preview]
        state.pending = [pending]
        let observed: [String: Any] = ["id": "confirmed", "role": "user", "text": "Mine", "createdAt": 2,
                                       "operationId": attempt, "images": [["attachmentId": "new-image", "name": "same.png", "mediaType": "image/png", "availability": "available"]]]
        state.messages = try messages([before, observed, after])
        model.state = state
        for _ in 0..<100 where model.visibleMessages.first(where: { $0.pending != nil }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.visibleMessages.count == 3)
        #expect(model.visibleMessages.map(\.id.message) == ["before", "local:operation", "after"])
        #expect(model.visibleMessages[1].previews.first?.data == preview.data)
    }

    @Test("Restored pending messages without a local anchor follow the current session history")
    func restoredPendingDoesNotJumpToTopOrReuseAnotherSession() async throws {
        func message(_ id: String) throws -> CFLMessage {
            try JSONDecoder().decode(CFLMessage.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "role": "agent", "text": id, "createdAt": 1
            ]))
        }
        func pending(_ operation: String, session: String) -> CFLPending {
            CFLPending(target: "target", sessionId: session, operationId: operation, text: operation,
                       createdAt: Date(), dispatched: true, status: .unknown)
        }
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.pending = [pending("first", session: "a"), pending("second", session: "b")]
        model.state = state
        state.sessionId = "a"
        state.sessionRevision = 1
        state.messages = [try message("history-a")]
        model.state = state
        for _ in 0..<100 where model.visibleMessages.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleMessages.map(\.id.message) == ["history-a", "local:first"])

        state.sessionId = "b"
        state.sessionRevision = 2
        state.messages = [try message("history-b")]
        model.state = state
        for _ in 0..<100 where model.visibleMessages.first?.id.message != "history-b" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.visibleMessages.map(\.id.message) == ["history-b", "local:second"])
    }

    @Test("An intervening reply stays before a later send with an earlier failed predecessor")
    func laterSendFollowsInterveningReply() async throws {
        func message(_ id: String) throws -> CFLMessage {
            try JSONDecoder().decode(CFLMessage.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "role": "agent", "text": id, "createdAt": 1
            ]))
        }
        let model = CFLConversationModel(draftChanges: PassthroughSubject<String, Never>().eraseToAnyPublisher())
        var state = CFLChatState()
        state.connection = .online
        state.sessionId = "session"
        state.sessionRevision = 1
        state.messages = [try message("before")]
        model.state = state
        state.pending = [CFLPending(target: "target", sessionId: "session", operationId: "first", text: "First",
                                    createdAt: Date(), dispatched: true, status: .failed)]
        model.state = state
        state.messages.append(try message("reply"))
        model.state = state
        model.capturePendingAnchor(session: "session")
        let preview = CFLLocalImagePreview(sessionId: "session", operationId: "second", originOperationId: "second",
                                           draftId: "draft", order: 0, attachmentId: nil, data: Data([1, 2]))
        state.localDrafts = [CFLLocalDraft(sessionId: "session", operationId: "second", text: "Second", images: [preview])]
        model.state = state
        for _ in 0..<100 where model.visibleMessages.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.visibleMessages.map(\.id.message) == ["before", "local:first", "reply", "local:second"])

        state.localDrafts = []
        state.pending.append(CFLPending(target: "target", sessionId: "session", operationId: "second", text: "Second",
                                        createdAt: Date(), dispatched: true, status: .unknown))
        model.state = state
        for _ in 0..<100 where model.visibleMessages.first(where: { $0.pending?.operationId == "second" }) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.visibleMessages.map(\.id.message) == ["before", "local:first", "reply", "local:second"])
    }
}
