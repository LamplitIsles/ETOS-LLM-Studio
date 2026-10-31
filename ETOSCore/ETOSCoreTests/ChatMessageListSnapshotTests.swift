import Foundation
import Testing
@testable import ETOSCore

struct ChatMessageListSnapshotTests {
    @Test("预计算历史索引保留工具与错误消息权重、定位及双向翻页行为")
    func preparedHistoryIndexPreservesWindowSemantics() {
        let messages: [ChatMessage] = (0..<12).flatMap { index in
            [
                ChatMessage(role: .user, content: "问题 \(index)"),
                ChatMessage(role: .assistant, content: "回复"),
                ChatMessage(role: .tool, content: "工具结果"),
                ChatMessage(role: .error, content: "中断")
            ]
        }
        let index = ChatHistoryWindowIndex(messages: messages)
        let initial = ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 3, index: index)
        #expect(initial == ChatHistoryWindowSupport.trailing(in: messages, weightedLimit: 3))
        let earlier = ChatHistoryWindowSupport.expandingEarlier(
            initial, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9, index: index
        )
        #expect(earlier == ChatHistoryWindowSupport.expandingEarlier(
            initial, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9
        ))
        #expect(ChatHistoryWindowSupport.expandingLater(
            earlier, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9, index: index
        ) == ChatHistoryWindowSupport.expandingLater(
            earlier, in: messages, weightedBatchSize: 4, maximumWeightedCount: 9
        ))
        for messageID in [messages[0].id, messages[24].id, messages[47].id, UUID()] {
            #expect(ChatHistoryWindowSupport.position(of: messageID, in: messages, window: earlier, index: index)
                == ChatHistoryWindowSupport.position(of: messageID, in: messages, window: earlier))
            #expect(ChatHistoryWindowSupport.centered(on: messageID, in: messages, maximumWeightedCount: 9, index: index)
                == ChatHistoryWindowSupport.centered(on: messageID, in: messages, maximumWeightedCount: 9))
        }
        let appended = messages + [ChatMessage(role: .user, content: "追加问题")]
        let readingWindow = ChatHistoryWindow(lowerBound: 8, upperBound: 24)
        #expect(ChatHistoryWindowSupport.rebased(
            readingWindow, from: messages, to: appended, previousIndex: index, index: .init(messages: appended)
        ) == readingWindow)
    }
}
