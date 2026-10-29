import Foundation

enum InternalToolCallResultDisposition: Equatable { case completed, failed }
struct InternalToolCall: Equatable {
    let id: String
    var result: String?
    var resultDisposition: InternalToolCallResultDisposition?
}
struct ChatMessage: Equatable {
    let id: UUID
    var toolCalls: [InternalToolCall]?
}

@main
struct ToolResultMutationChecks {
    static func main() {
        let messageID = UUID()
        var messages = [ChatMessage(id: messageID, toolCalls: [
            InternalToolCall(id: "one"), InternalToolCall(id: "two")
        ])]
        precondition(ChatToolResultMutation.apply(to: &messages, messageID: messageID, toolCallID: "one", result: "first", disposition: .completed))
        precondition(ChatToolResultMutation.apply(to: &messages, messageID: messageID, toolCallID: "two", result: "second", disposition: .failed))
        precondition(messages[0].toolCalls?[0].result == "first" && messages[0].toolCalls?[1].result == "second")
        let beforeMissingCall = messages
        precondition(!ChatToolResultMutation.apply(to: &messages, messageID: messageID, toolCallID: "missing", result: "ignored", disposition: .completed))
        precondition(messages == beforeMissingCall)
        messages.removeAll()
        precondition(!ChatToolResultMutation.apply(to: &messages, messageID: messageID, toolCallID: "one", result: "ignored", disposition: .completed))
        precondition(messages.isEmpty)
        print("tool result mutation checks passed")
    }
}
