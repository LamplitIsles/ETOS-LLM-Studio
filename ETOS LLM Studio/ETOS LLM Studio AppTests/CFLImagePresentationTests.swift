import ETOSCore
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
}
