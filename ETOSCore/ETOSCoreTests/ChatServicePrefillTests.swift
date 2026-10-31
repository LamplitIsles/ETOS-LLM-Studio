import Foundation
import Combine
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("错误与未完成工具调用不可预填充")
    func prefillExcludesErrorsAndToolCalls() throws {
        let error = ChatMessage(role: .error, content: "网络错误")
        #expect(!error.canPrefill)
        #expect(!ChatMessage(role: .assistant, content: "").canPrefill)
        #expect(!ChatMessage(role: .assistant, content: "调用中", toolCalls: [
            InternalToolCall(id: "call", toolName: "search", arguments: "{")
        ]).canPrefill)
    }
}
