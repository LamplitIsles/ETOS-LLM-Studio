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
