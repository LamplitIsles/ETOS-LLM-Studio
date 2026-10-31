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
