import Foundation
import Testing
@testable import ETOSCore

@Suite("工具描述自定义", .serialized)
struct ToolDescriptionCustomizationTests {
    @MainActor
    @Test("三个直接内置工具使用自定义提示词并可恢复默认，参数不变")
    func directBuiltInDescriptions() throws {
        for kind in [AppToolKind.showWidget, .getSystemTime] {
            let id = try #require(kind.builtInDescriptionPromptID)
            let previous = BuiltInPromptStore.customizedTemplate(for: id)
            defer {
                if let previous { BuiltInPromptStore.saveTemplate(previous, for: id) }
                else { BuiltInPromptStore.resetTemplate(for: id) }
            }
            #expect(BuiltInPromptStore.saveTemplate("精简说明", for: id))
            let tool = AppToolManager.shared.toolDefinition(for: kind)
            #expect(tool.description == "精简说明")
            #expect(tool.parameters == kind.parameters)
            #expect(BuiltInPromptStore.saveTemplate("", for: id))
            #expect(AppToolManager.shared.toolDefinition(for: kind).description == "")
            #expect(BuiltInPromptStore.resetTemplate(for: id))
            #expect(AppToolManager.shared.toolDefinition(for: kind).description == kind.toolDescription)
        }
    }

}
