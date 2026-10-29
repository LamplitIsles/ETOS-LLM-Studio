import Foundation
import Testing
@testable import ETOSCore

struct ToolInteractionPresentationTests {
    @Test("只有已结束的 Widget 结果可以构建网页，参数和拒绝结果不会执行")
    func widgetRequiresCompletedResult() throws {
        let result = #"{"title":"图表","widget_code":"<p>已完成</p>","inline_aspect_ratio":"4:3"}"#
        let arguments = #"{"widget_code":"<script>unapproved()</script>"}"#
        var call = InternalToolCall(id: "widget", toolName: AppToolKind.showWidget.toolName, arguments: arguments)
        #expect(CompletedToolWidget(message: ChatMessage(role: .assistant, content: "", toolCalls: [call])) == nil)
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: "等待审批", toolCalls: [call])) == nil)
        call.result = result
        call.resultDisposition = .rejected
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])) == nil)
        call.resultDisposition = .failed
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])) == nil)
        call.resultDisposition = .completed
        let rendered = try #require(CompletedToolWidget(message: ChatMessage(role: .tool, content: result, toolCalls: [call])))
        #expect(rendered.payload.widgetCode == "<p>已完成</p>")
        #expect(!rendered.html.contains("unapproved()"))
        #expect(CompletedToolWidget(message: ChatMessage(role: .tool, content: result))?.payload == rendered.payload)
    }
}
