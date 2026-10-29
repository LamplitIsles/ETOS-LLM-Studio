import Foundation

enum ChatToolResultMutation {
    static func apply(
        to messages: inout [ChatMessage], messageID: UUID, toolCallID: String,
        result: String, disposition: InternalToolCallResultDisposition
    ) -> Bool {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              var calls = messages[messageIndex].toolCalls,
              let callIndex = calls.firstIndex(where: { $0.id == toolCallID }) else { return false }
        calls[callIndex].result = result
        calls[callIndex].resultDisposition = disposition
        messages[messageIndex].toolCalls = calls
        return true
    }
}
