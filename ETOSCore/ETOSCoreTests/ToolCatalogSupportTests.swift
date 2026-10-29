// ============================================================================
// ToolCatalogSupportTests.swift
// ============================================================================
// ToolCatalogSupportTests 测试文件
// - 覆盖内置工具状态汇总
// - 覆盖 Schema 摘要生成逻辑
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("工具中心辅助测试")
struct ToolCatalogSupportTests {

    @Test("工具隔离会影响内置工具")
    func testBuiltInToolStatesReflectIsolation() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: true,
            enableGetSystemTimeTool: true,
            isToolIsolated: true
        )

        #expect(states.first(where: { $0.kind == .widgetCard })?.isAvailableInCurrentSession == false)
        #expect(states.first(where: { $0.kind == .getSystemTime })?.isAvailableInCurrentSession == false)
    }

    @Test("网页卡片工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectWidgetDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: false,
            enableGetSystemTimeTool: true,
            isToolIsolated: false
        )

        let widgetTool = states.first(where: { $0.kind == .widgetCard })
        #expect(widgetTool?.isConfiguredEnabled == false)
        #expect(widgetTool?.isAvailableInCurrentSession == false)
        #expect(widgetTool?.statusReason == .widgetDisabled)
    }

    @Test("获取系统时间工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectGetSystemTimeDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: true,
            enableGetSystemTimeTool: false,
            isToolIsolated: false
        )

        let timeTool = states.first(where: { $0.kind == .getSystemTime })
        #expect(timeTool?.isConfiguredEnabled == false)
        #expect(timeTool?.isAvailableInCurrentSession == false)
        #expect(timeTool?.statusReason == .getSystemTimeDisabled)
    }

    @Test("拓展工具会按用途归入不同分类")
    func testAppToolCategoryMapping() {
        #expect(ToolCatalogSupport.appToolCategory(for: .listSandboxDirectory) == .file)
        #expect(ToolCatalogSupport.appToolCategory(for: .querySQLite) == .database)
        #expect(ToolCatalogSupport.appToolCategory(for: .submitFeedbackTicket) == .interaction)
        #expect(ToolCatalogSupport.appToolCategory(for: .fillUserInput) == .interaction)
        #expect(ToolCatalogSupport.appToolCategory(for: .executeJSCJavaScript) == .custom)
    }

    @Test("Schema 摘要会提取字段与必填项")
    func testSchemaSummaryIncludesFieldsAndRequiredKeys() {
        let schema = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "query": .dictionary(["type": .string("string")]),
                "count": .dictionary(["type": .string("integer")])
            ]),
            "required": .array([.string("query")])
        ])

        let summary = ToolCatalogSupport.schemaSummary(for: schema, fieldLimit: 4)

        #expect(summary == "type=object · fields=count, query · required=query")
    }
}
