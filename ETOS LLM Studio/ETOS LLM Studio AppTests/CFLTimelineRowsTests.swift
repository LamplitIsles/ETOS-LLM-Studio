import Foundation
import Combine
import ExyteChat
@testable import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("CFL timeline row presentation")
struct CFLTimelineRowsTests {
    @Test("A gap loads once per viewport visit and errors require explicit retry")
    func gapVisibilityVisits() {
        var visits = CFLHistoryGapVisits()
        var gap = CFLHistoryGap(id: UUID(), afterId: "old", beforeId: "new", status: .pending)
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 400)
        let visible = CGRect(x: 10, y: 120, width: 100, height: 40)
        let offscreen = CGRect(x: 10, y: 520, width: 100, height: 40)
        #expect(CFLHistoryGapVisits.visible(visible, in: viewport))
        #expect(!CFLHistoryGapVisits.visible(offscreen, in: viewport))
        #expect(visits.update(gap, visible: true))
        #expect(!visits.update(gap, visible: true))
        gap.status = .error
        #expect(!visits.update(gap, visible: false))
        #expect(!visits.update(gap, visible: true))
        gap.status = .pending
        #expect(visits.update(gap, visible: true))
        #expect(!visits.update(gap, visible: true))
        visits.reset()
        #expect(visits.update(gap, visible: true))
    }
    private func item(_ id: String) -> CFLDisplayMessage {
        CFLDisplayMessage(id: .init(target: "fixture", session: "session", message: id, offset: 0),
                          text: "reply", outgoing: false, markdown: false, images: [],
                          sessionRevision: 1, clientID: UUID())
    }

    @Test("Interface messages retain timeline position and update their own row")
    func interfaceRowPresentation() throws {
        func message(_ id: String, _ ui: String) throws -> CFLMessage {
            let wire = """
            {"id":"\(id)","role":"agent","text":"","createdAt":1,"operationId":null,"turnId":"turn","ui":\(ui)}
            """
            return try JSONDecoder().decode(CFLMessage.self, from: Data(wire.utf8))
        }
        let first = try message("first", "null")
        let second = try message("second", "{}")
        let input = CFLTimelineProjection.ProjectionInput(target: "fixture", session: "session", revision: 1, clientID: UUID(),
            messages: [first, second], reply: nil, historyGaps: [], drafts: [], previews: [], pending: [],
            otherTargetPending: [], anchors: [:], locals: [], origins: [:])
        let rows = CFLTimelineProjection.project(input, cache: [:]).messages
        #expect(rows.map(\.id.message) == ["first", "second"])
        #expect(rows[0].ui == .null && rows[1].ui == .object([:]))
        let bubble = CFLBubbleState(rows[1])
        var changes = 0
        let observer = bubble.objectWillChange.sink { _ in changes += 1 }
        var updated = rows[1]
        updated.ui = .object(["changed": .bool(true)])
        bubble.update(updated)
        #expect(changes == 1 && bubble.item.ui == updated.ui)
        #expect(CFLTimelineRow.message(rows[1]).message.id == CFLTimelineRow.message(updated).message.id)
        withExtendedLifetime(observer) {}
    }

    @Test("The renderer bridge accepts only its dedicated scheme and authority")
    func interfaceMediaBridgeURL() throws {
        let valid = try #require(URL(string: "cfl-media://load/%2Fapi%2Fchat%2Fmedia%2Fphoto%2Fpreview"))
        #expect(CFLA2UIBridgePolicy.mediaPath(valid) == "/api/chat/media/photo/preview")
        let workspace = try #require(URL(string: "cfl-media://load/%2Fapi%2Fchat%2Fworkspace-media%3Fkind%3Daudio%26path%3Dmusic%252F%252520.wav"))
        #expect(CFLA2UIBridgePolicy.mediaPath(workspace) == "/api/chat/workspace-media?kind=audio&path=music%2F%2520.wav")
        for value in ["https://load/%2Fapi%2Faudio%2Fx.mp3", "cfl-media://other/%2Fapi%2Faudio%2Fx.mp3",
                      "cfl-media://user@load/%2Fapi%2Faudio%2Fx.mp3", "cfl-media://load/%2Fapi%2Faudio%2Fx.mp3?x=1"] {
            let url = try #require(URL(string: value))
            #expect(CFLA2UIBridgePolicy.mediaPath(url) == nil)
        }
    }

    @Test("Independent media requests share a version until the presentation ends")
    func interfaceMediaVersions() {
        var versions = CFLA2UIMediaVersions()
        #expect(versions.admit("first", for: "/media/a"))
        #expect(versions.admit("first", for: "/media/a"))
        #expect(!versions.admit("second", for: "/media/a"))
        #expect(versions.admit("second", for: "/media/b"))
        versions.reset()
        #expect(versions.admit("second", for: "/media/a"))
    }

    @Test("Embedded interface height is bounded by the native viewport")
    func interfaceHeight() throws {
        let short = try #require(CFLA2UIBridgePolicy.displayHeight(150.2, viewport: 600))
        #expect(short.height == 151 && !short.scroll)
        let tall = try #require(CFLA2UIBridgePolicy.displayHeight(900, viewport: 600))
        #expect(tall.height == 600 && tall.scroll)
        #expect(CFLA2UIBridgePolicy.displayHeight(.infinity, viewport: 600)?.height == nil)
        #expect(CFLA2UIBridgePolicy.displayHeight(10_001, viewport: 600)?.height == nil)
        let viewport = CFLTimelineViewport.visibleFrame(CGRect(x: 0, y: 10, width: 390, height: 800), navigationHeight: 64, composerHeight: 280)
        #expect(viewport.height == 456)
        let resized = try #require(CFLA2UIBridgePolicy.displayHeight(700, viewport: Double(viewport.height)))
        #expect(resized.height == 456 && resized.scroll)
    }

    @Test("File rows retain their identity and show attachment metadata")
    func fileRowPresentation() {
        let client = UUID()
        let id = CFLDisplayMessage.ID(target: "fixture", session: "session", message: "local:op", offset: 0)
        let local = CFLDisplayMessage(id: id, text: "", outgoing: true, markdown: false, images: [],
                                      sessionRevision: 1, clientID: client,
                                      files: [CFLDisplayFile(name: "notes.txt", size: 3)])
        let ref = CFLFileRef(attachmentId: "file1", name: "notes.txt", mediaType: "text/plain", size: 3, availability: "available")
        let confirmed = CFLDisplayMessage(id: id, text: "", outgoing: true, markdown: false, images: [],
                                          sessionRevision: 1, clientID: client, files: [CFLDisplayFile(ref)])
        #expect(CFLTimelineRow.message(local).message.id == CFLTimelineRow.message(confirmed).message.id)
        let bubble = CFLBubbleState(local)
        var changes = 0
        let observer = bubble.objectWillChange.sink { _ in changes += 1 }
        bubble.update(confirmed)
        #expect(changes == 1 && bubble.item.files.first?.ref == ref)
        withExtendedLifetime(observer) {}
    }

    @Test("File-only history and unverified retry keep the original visible file")
    func fileHistoryAndRetry() throws {
        let wire = #"{"id":"message","role":"user","text":"","createdAt":1,"operationId":"attempt","turnId":null,"files":[{"attachmentId":"new","name":"new.txt","mediaType":"text/plain","size":3,"availability":"available"}]}"#
        let message = try JSONDecoder().decode(CFLMessage.self, from: Data(wire.utf8))
        let original = CFLFileRef(attachmentId: "old", name: "old.txt", mediaType: "text/plain", size: 3, availability: "available")
        let pending = CFLPending(target: "fixture", sessionId: "session", operationId: "attempt", text: "", createdAt: Date(),
                                 dispatched: true, status: .unknown, retrySource: "source", files: [original])
        var input = CFLTimelineProjection.ProjectionInput(target: "fixture", session: "session", revision: 1, clientID: UUID(),
            messages: [message], reply: nil, historyGaps: [], drafts: [], previews: [], pending: [pending],
            otherTargetPending: [], anchors: [:], locals: [], origins: [:])
        let uncertain = CFLTimelineProjection.project(input, cache: [:]).messages
        #expect(uncertain.count == 1 && uncertain[0].files.first?.name == "old.txt")
        input = CFLTimelineProjection.ProjectionInput(target: input.target, session: input.session, revision: input.revision,
            clientID: input.clientID, messages: [message], reply: nil, historyGaps: [], drafts: [], previews: [], pending: [],
            otherTargetPending: [], anchors: [:], locals: [], origins: [:])
        let confirmed = CFLTimelineProjection.project(input, cache: [:]).messages
        #expect(confirmed.count == 1 && confirmed[0].files.first?.name == "new.txt")
    }

    @Test("The adapter publishes only changed rows and coalesces stale updates")
    func adapterUpdates() async {
        let adapter = CFLTimelineAdapter()
        var snapshots: [[String]] = []
        let observation = adapter.$rows.dropFirst().sink { snapshots.append($0.map { $0.message.id }) }
        let first = CFLTimelineRow.message(item("first"))
        adapter.offer([first])
        adapter.offer([first])
        #expect(snapshots == [[first.message.id]])

        adapter.transaction = TableUpdateTransaction()
        let second = CFLTimelineRow.message(item("second"))
        let third = CFLTimelineRow.message(item("third"))
        adapter.offer([first, second])
        adapter.offer([first, third])
        for _ in 0..<1000 where adapter.rows.count != 2 { await Task.yield() }
        #expect(adapter.rows.map { $0.message.id } == [first.message.id, third.message.id])
        #expect(snapshots == [[first.message.id], [first.message.id, third.message.id]])
        withExtendedLifetime(observation) {}
    }

    @Test("bottom space retains its identity as the composer grows")
    func bottomSpace() {
        let before = CFLTimelineRow.bottomSpace(height: 86).message
        let after = CFLTimelineRow.bottomSpace(height: 140).message
        #expect(before.id == after.id)
        #expect(before != after)
    }

    @Test("overlay spacing refreshes the row without changing its identity")
    func overlaySpacing() {
        let row = CFLTimelineRow.message(item("message"))
        let before = row.message(topPadding: 84, bottomPadding: 86)
        let after = row.message(topPadding: 0, bottomPadding: 140)
        #expect(before.id == after.id)
        #expect(before != after)
        #expect(before.customData["etosTopPadding"] as? CGFloat == 84)
        #expect(after.customData["etosBottomPadding"] as? CGFloat == 140)
    }

    @Test("A text confirmation does not change the visible Exyte row")
    func confirmationDoesNotRedrawText() {
        let client = UUID()
        let id = CFLDisplayMessage.ID(target: "fixture", session: "session", message: "local:op", offset: 0)
        let before = CFLDisplayMessage(id: id, text: "hello", outgoing: true, markdown: false, images: [],
                                       sessionRevision: 1, clientID: client, sendingLocally: true)
        var pending = CFLPending(target: "fixture", sessionId: "session", operationId: "op", text: "hello",
                                 createdAt: Date(), dispatched: true, status: .unknown)
        let checking = CFLDisplayMessage(id: id, text: "hello", outgoing: true, markdown: false, images: [],
                                         sessionRevision: 1, clientID: client, pending: pending)
        pending.status = .submitted
        let confirmed = CFLDisplayMessage(id: id, text: "hello", outgoing: true, markdown: false, images: [],
                                          sessionRevision: 1, clientID: client, pending: pending)
        #expect(CFLTimelineRow.message(before).message == CFLTimelineRow.message(checking).message)
        #expect(CFLTimelineRow.message(before).message == CFLTimelineRow.message(confirmed).message)
        let bubble = CFLBubbleState(before)
        var notifications = 0
        let observation = bubble.objectWillChange.sink { _ in notifications += 1 }
        bubble.update(checking)
        bubble.update(confirmed)
        #expect(notifications == 0)
        pending.status = .failed
        let failed = CFLDisplayMessage(id: id, text: "hello", outgoing: true, markdown: false, images: [],
                                       sessionRevision: 1, clientID: client, pending: pending)
        #expect(CFLTimelineRow.message(before).message != CFLTimelineRow.message(failed).message)
        bubble.update(failed)
        #expect(notifications == 1)
        withExtendedLifetime(observation) {}
    }

    @Test("Binding a server image keeps the same visible preview row")
    func confirmationPreservesPreview() {
        let client = UUID(), id = CFLDisplayMessage.ID(target: "fixture", session: "session", message: "local:op", offset: 0)
        let data = Data([1, 2, 3])
        let local = CFLLocalImagePreview(sessionId: "session", operationId: "op", originOperationId: "op",
                                         draftId: "draft", order: 0, attachmentId: nil, data: data)
        let bound = CFLLocalImagePreview(sessionId: "session", operationId: "op", originOperationId: "op",
                                         draftId: "draft", order: 0, attachmentId: "stored", data: data)
        let ref = CFLImageRef(attachmentId: "stored", name: "photo.png", mediaType: "image/png", availability: "available")
        let before = CFLDisplayMessage(id: id, text: "", outgoing: true, markdown: false, images: [],
                                       sessionRevision: 1, clientID: client, previews: [local], sendingLocally: true)
        let after = CFLDisplayMessage(id: id, text: "", outgoing: true, markdown: false, images: [ref],
                                      sessionRevision: 1, clientID: client, previews: [bound])
        #expect(CFLTimelineRow.message(before).message == CFLTimelineRow.message(after).message)
    }
}
