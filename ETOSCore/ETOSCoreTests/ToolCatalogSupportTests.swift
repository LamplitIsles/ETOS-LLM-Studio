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
            enableAskUserInputTool: true,
            enableGetSystemTimeTool: true,
            isToolIsolated: true
        )

        #expect(states.first(where: { $0.kind == .widgetCard })?.isAvailableInCurrentSession == false)
        #expect(states.first(where: { $0.kind == .askUserInput })?.isAvailableInCurrentSession == false)
        #expect(states.first(where: { $0.kind == .getSystemTime })?.isAvailableInCurrentSession == false)
    }

    @Test("网页卡片工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectWidgetDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: false,
            enableAskUserInputTool: true,
            enableGetSystemTimeTool: true,
            isToolIsolated: false
        )

        let widgetTool = states.first(where: { $0.kind == .widgetCard })
        #expect(widgetTool?.isConfiguredEnabled == false)
        #expect(widgetTool?.isAvailableInCurrentSession == false)
        #expect(widgetTool?.statusReason == .widgetDisabled)
    }

    @Test("询问用户选项工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectAskUserInputDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: true,
            enableAskUserInputTool: false,
            enableGetSystemTimeTool: true,
            isToolIsolated: false
        )

        let askTool = states.first(where: { $0.kind == .askUserInput })
        #expect(askTool?.isConfiguredEnabled == false)
        #expect(askTool?.isAvailableInCurrentSession == false)
        #expect(askTool?.statusReason == .askUserInputDisabled)
    }

    @Test("获取系统时间工具关闭时应标记为未启用")
    func testBuiltInToolStatesReflectGetSystemTimeDisabled() {
        let states = ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: true,
            enableAskUserInputTool: true,
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

    @Test("MCP 工具目录会保留已选服务器的完整工具清单")
    func testMCPCatalogToolsIncludesDisabledAndDeniedTools() {
        let selectedServerID = UUID()
        let unselectedServerID = UUID()

        let selectedServer = MCPServerConfiguration(
            id: selectedServerID,
            displayName: "已选服务器",
            transport: .http(endpoint: URL(string: "https://example.com/selected")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true,
            disabledToolIds: ["beta"],
            toolApprovalPolicies: ["gamma": .alwaysDeny]
        )
        let unselectedServer = MCPServerConfiguration(
            id: unselectedServerID,
            displayName: "未选服务器",
            transport: .http(endpoint: URL(string: "https://example.com/unselected")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: false
        )

        let selectedStatus = MCPServerStatus(
            connectionState: .ready,
            tools: [
                MCPToolDescription(toolId: "alpha", description: nil, inputSchema: nil, examples: nil),
                MCPToolDescription(toolId: "beta", description: nil, inputSchema: nil, examples: nil),
                MCPToolDescription(toolId: "gamma", description: nil, inputSchema: nil, examples: nil)
            ],
            isSelectedForChat: true
        )
        let unselectedStatus = MCPServerStatus(
            connectionState: .ready,
            tools: [
                MCPToolDescription(toolId: "hidden", description: nil, inputSchema: nil, examples: nil)
            ],
            isSelectedForChat: false
        )

        let catalog = ToolCatalogSupport.mcpCatalogTools(
            servers: [selectedServer, unselectedServer],
            statuses: [
                selectedServerID: selectedStatus,
                unselectedServerID: unselectedStatus
            ]
        )

        #expect(catalog.count == 3)
        #expect(catalog.map(\.tool.toolId) == ["alpha", "beta", "gamma"])
    }

    @Test("MCP 工具目录排序会先按服务器再按工具名")
    func testSortedMCPCatalogToolsSortsByServerThenTool() {
        let alphaServer = MCPServerConfiguration(
            displayName: "Alpha Server",
            transport: .http(endpoint: URL(string: "https://example.com/alpha")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true
        )
        let betaServer = MCPServerConfiguration(
            displayName: "Beta Server",
            transport: .http(endpoint: URL(string: "https://example.com/beta")!, apiKey: nil, additionalHeaders: [:]),
            isSelectedForChat: true
        )

        let tools = [
            MCPAvailableTool(
                server: betaServer,
                tool: MCPToolDescription(toolId: "zeta", description: nil, inputSchema: nil, examples: nil),
                internalName: "mcp://beta/zeta"
            ),
            MCPAvailableTool(
                server: alphaServer,
                tool: MCPToolDescription(toolId: "gamma", description: nil, inputSchema: nil, examples: nil),
                internalName: "mcp://alpha/gamma"
            ),
            MCPAvailableTool(
                server: alphaServer,
                tool: MCPToolDescription(toolId: "beta", description: nil, inputSchema: nil, examples: nil),
                internalName: "mcp://alpha/beta"
            )
        ]

        let sortedTools = ToolCatalogSupport.sortedMCPCatalogTools(tools)

        #expect(sortedTools.map(\.server.displayName) == ["Alpha Server", "Alpha Server", "Beta Server"])
        #expect(sortedTools.map(\.tool.toolId) == ["beta", "gamma", "zeta"])
    }
}
