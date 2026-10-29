import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacBuiltInToolPresentationTests {
    @Test("启用筛选保留被会话隔离的工具，状态区分已配置和实际可用")
    func isolationDoesNotChangeConfiguredFilter() throws {
        let states = ToolCatalogSupport.builtInToolStates(enableWidgetTool: false,
            enableGetSystemTimeTool: true, isToolIsolated: true)
        let prepared = MacBuiltInToolPresentation.prepare(states: states, query: "", enabledOnly: true)
        #expect(prepared.rows.map(\.id) == [.getSystemTime])
        #expect(prepared.rows.allSatisfy { !$0.state.isAvailableInCurrentSession })
        #expect(prepared.all[.widgetCard]?.state.statusReason == .widgetDisabled)
        guard case .array(let values) = prepared.guide else { Issue.record("缺少内置工具快照"); return }
        #expect(values.count == 1)
        for value in values {
            guard case .dictionary(let fields) = value else { Issue.record("目录项不是对象"); return }
            #expect(fields["configured_enabled"] == .bool(true))
            #expect(fields["available_in_session"] == .bool(false))
        }
    }

    @Test("后台搜索匹配实际工具说明，详情索引仍保留其他工具")
    func searchKeepsFullDetailIndex() {
        let states = ToolCatalogSupport.builtInToolStates(enableWidgetTool: true,
            enableGetSystemTimeTool: true, isToolIsolated: false)
        let prepared = MacBuiltInToolPresentation.prepare(states: states, query: " GET_SYSTEM_TIME ", enabledOnly: false)
        #expect(prepared.rows.map(\.id) == [.getSystemTime])
        #expect(prepared.all.count == 2)
        #expect(prepared.all[.getSystemTime]?.state.isAvailableInCurrentSession == true)
        #expect(prepared.all[.widgetCard]?.state.isAvailableInCurrentSession == true)
    }
}
