// ============================================================================
// MCPBuiltInAppToolServerTests.swift
// ============================================================================
// ETOSCoreTests
//
// 验证拓展工具与会话协作工具按分类注册为应用内建 MCP Server。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("内建 MCP 拓展工具服务器测试")
struct MCPBuiltInAppToolServerTests {
    @Test("路线工具不声明或执行公交完整路线")
    func testTransitDirectionsAreRejectedBeforeNetworkAccess() async throws {
        let tool = try #require(MCPNativeDeviceToolDefinitions.descriptions.first { $0.toolId == "maps.directions" })
        let schema = try #require(tool.inputSchema?.toAny() as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let transport = try #require(properties["transport_type"] as? [String: Any])
        #expect(transport["enum"] as? [String] == ["automobile", "walking", "cycling"])

        do {
            _ = try await MCPNativeMapsExecutor().execute(toolName: "maps.directions", arguments: [
                "source_latitude": 28.19, "source_longitude": 112.93,
                "destination_latitude": 28.20, "destination_longitude": 112.94,
                "transport_type": "transit"
            ])
            Issue.record("公交模式应在发出网络请求前被拒绝。")
        } catch MCPNativeCapabilityError.invalidArgument {
        }
    }

    #if os(watchOS)
    @Test("手表系统 URL 工具拒绝电话短信以外的协议")
    func testWatchSystemURLRejectsUnsupportedSchemes() async throws {
        for url in ["https://example.com", "mailto:example@example.com", "maps://"] {
            do {
                _ = try await MCPNativeMapsExecutor().execute(toolName: "device.open_url", arguments: ["url": url])
                Issue.record("手表不能把不受支持的 URL 报告为已打开。")
            } catch MCPNativeCapabilityError.invalidArgument {
            }
        }
    }
    #endif
}
