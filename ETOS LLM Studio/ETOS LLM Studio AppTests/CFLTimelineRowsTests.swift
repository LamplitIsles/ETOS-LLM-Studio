import Foundation
import ExyteChat
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("CFL timeline row presentation")
struct CFLTimelineRowsTests {
    private func item(_ id: String) -> CFLDisplayMessage {
        CFLDisplayMessage(id: .init(target: "fixture", session: "session", message: id, offset: 0),
                          text: "reply", outgoing: false, markdown: false, images: [],
                          sessionRevision: 1, clientID: UUID())
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
}
