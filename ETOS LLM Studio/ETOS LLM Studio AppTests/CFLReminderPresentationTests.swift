import Combine
import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

@MainActor
@Suite("CFL reminder presentation")
struct CFLReminderPresentationTests {
    @Test("Collapsed reminders use one line; expanded reminders retain the original lines")
    func reminderText() {
        let text = "记得查看\n今天的安排"
        #expect(CFLReminderBubble.displayedText(text, expanded: false) == "⏰ 记得查看 今天的安排")
        #expect(CFLReminderBubble.displayedText(text, expanded: true) == "⏰ " + text)
    }

    @Test("Source identifies a whole reminder independently of its role and preserves images")
    func projectsReminderAndOrdinaryMessages() async throws {
        let image: [String: Any] = ["attachmentId": "image-1", "name": "image.png",
                                    "mediaType": "image/png", "availability": "available"]
        let reminder: [String: Any] = ["kind": "reminder", "reminderId": "reminder-1"]
        let source: [[String: Any]] = [
            ["id": "user-reminder", "role": "user", "text": "第一行\n第二行", "createdAt": 1, "source": reminder],
            ["id": "agent-reminder", "role": "agent", "text": "A\nB", "createdAt": 2, "source": reminder, "images": [image]],
            ["id": "ordinary", "role": "user", "text": "⏰ 我自己写的", "createdAt": 3]
        ]
        let messages = try JSONDecoder().decode([CFLMessage].self, from: JSONSerialization.data(withJSONObject: source))
        let changes = PassthroughSubject<String, Never>()
        let model = CFLConversationModel(draftChanges: changes.eraseToAnyPublisher())
        var state = CFLChatState()
        state.sessionId = "session"
        state.messages = messages
        model.state = state
        for _ in 0..<100 where model.visibleMessages.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let rows = model.visibleMessages
        try #require(rows.count == 3)
        #expect(rows[0].isReminder && !rows[0].outgoing && rows[0].text == "第一行\n第二行")
        #expect(rows[1].isReminder && !rows[1].outgoing && rows[1].text == "A\nB" && rows[1].images.count == 1)
        #expect(!rows[2].isReminder && rows[2].outgoing && rows[2].text == "⏰ 我自己写的")
    }
}
