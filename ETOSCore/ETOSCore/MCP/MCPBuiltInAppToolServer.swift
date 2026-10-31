// ============================================================================
// MCPBuiltInAppToolServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 将需要审批的本地工具包装为应用内建 MCP Server。
// MCP 负责统一暴露、启停与审批；AppTool 只保留具体执行实现。
// ============================================================================

import Foundation

public enum MCPBuiltInAppToolServer {
    static let conversationSourceSessionIDArgument = "_etos_source_session_id"
    static let conversationToolCallIDArgument = "_etos_tool_call_id"
    static let localAgentRunIDArgument = "_etos_agent_run_id"
    static let localAgentTriggeringMessageIDArgument = "_etos_triggering_message_id"
    static let localAgentSelectedMCPServerIDsArgument = "_etos_selected_mcp_server_ids"
    static let localAgentApprovedCommandRuleIDsArgument = "_etos_approved_command_rule_ids"

    @MainActor
    static func appToolDescriptions(
        for category: AppToolCatalogCategory,
        includeUnavailablePlatformTools: Bool = false
    ) -> [MCPToolDescription] {
        appToolDescriptions(
            for: category,
            appToolManager: AppToolManager.shared,
            includeUnavailablePlatformTools: includeUnavailablePlatformTools
        )
    }

    @MainActor
    static func appToolDescriptions(
        for category: AppToolCatalogCategory,
        appToolManager: AppToolManager,
        includeUnavailablePlatformTools: Bool = false
    ) -> [MCPToolDescription] {
        #if os(macOS)
        if category == .linux {
            return LocalLinuxToolDefinitions.all.map { tool in
                MCPToolDescription(
                    toolId: tool.name,
                    description: tool.description,
                    inputSchema: tool.parameters,
                    examples: nil
                )
            }
        }

        #else
        if category == .linux { return [] }
        #endif

        if category == .deviceOperations {
            return includeUnavailablePlatformTools
                ? MCPNativeDeviceToolDefinitions.descriptions
                : MCPNativeDeviceToolDefinitions.availableDescriptions
        }

        if category == .mediaEnvironment {
            return includeUnavailablePlatformTools
                ? MCPNativeMediaToolDefinitions.descriptions
                : MCPNativeMediaToolDefinitions.availableDescriptions
        }

        if category == .visionLanguage {
            return includeUnavailablePlatformTools
                ? MCPNativeVisionLanguageToolDefinitions.descriptions
                : MCPNativeVisionLanguageToolDefinitions.availableDescriptions
        }

        let staticTools = AppToolKind.allCases
            .filter { !AppToolManager.builtInToolKinds.contains($0) }
            .filter { includeUnavailablePlatformTools || $0.isAvailableOnCurrentPlatform }
            .filter { ToolCatalogSupport.appToolCategory(for: $0) == category }
            .map { kind in
                MCPToolDescription(
                    toolId: kind.toolName,
                    description: kind.toolDescription,
                    inputSchema: kind.parameters,
                    examples: nil
                )
            }

        guard category == .custom else { return staticTools }

        let customTools = appToolManager.customJSTools
            .filter { includeUnavailablePlatformTools || $0.engine.isAvailableOnCurrentPlatform }
            .map { tool in
                MCPToolDescription(
                    toolId: tool.toolName,
                    description: customJSToolDescription(for: tool),
                    inputSchema: tool.parameters,
                    examples: nil
                )
            }

        return staticTools + customTools
    }

    static func category(for toolName: String) -> AppToolCatalogCategory? {
        #if os(macOS)
        if LocalLinuxToolDefinitions.contains(toolName) {
            return .linux
        }
        #endif
        if MCPNativeDeviceToolDefinitions.contains(toolName) {
            return .deviceOperations
        }
        if MCPNativeMediaToolDefinitions.contains(toolName) {
            return .mediaEnvironment
        }
        if MCPNativeVisionLanguageToolDefinitions.contains(toolName) {
            return .visionLanguage
        }
        if let kind = AppToolKind.resolve(from: toolName),
           !AppToolManager.builtInToolKinds.contains(kind) {
            return ToolCatalogSupport.appToolCategory(for: kind)
        }
        if AppToolManager.isCustomJSToolName(toolName) {
            return .custom
        }
        return nil
    }

    @MainActor
    static func executeTool(toolName: String, argumentsJSON: String) async throws -> String {
        return try await AppToolManager.shared.executeToolForBuiltInMCP(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
    }

    #if os(macOS)
    static func executeLinuxTool(
        toolName: String,
        argumentsJSON: String,
        sourceSessionID: UUID,
        sourceRunID: UUID,
        triggeringMessageID: UUID?,
        toolCallID: String,
        approvedCommandRuleIDs: Set<UUID>
    ) async throws -> String {
        try await LocalLinuxToolExecutor.shared.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            sessionID: sourceSessionID,
            runID: sourceRunID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            approvedCommandRuleIDs: approvedCommandRuleIDs
        )
    }

    #endif

    static func executeFileTool(toolName: String, argumentsJSON: String) async throws -> String {
        try await LocalAgentFileToolExecutor.shared.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
    }

    static func executeNativeDeviceTool(toolName: String, argumentsJSON: String) async throws -> String {
        let result = try await MCPNativeDeviceExecutor.shared.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
        return try MCPNativeJSON.text(result)
    }

    static func executeNativeMediaTool(toolName: String, argumentsJSON: String) async throws -> String {
        let result = try await MCPNativeMediaExecutor.shared.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
        return try MCPNativeJSON.text(result)
    }

    static func executeNativeVisionLanguageTool(toolName: String, argumentsJSON: String) async throws -> String {
        let result = try await MCPNativeVisionLanguageExecutor.shared.execute(
            toolName: toolName,
            argumentsJSON: argumentsJSON
        )
        return try MCPNativeJSON.text(result)
    }

    private static func customJSToolDescription(for tool: AppToolCustomJSTool) -> String {
        String(
            format: NSLocalizedString(
                "自定义 JavaScript 工具。脚本保存在应用的 CustomJSTools 独立目录中，执行入口为同步 function main(input)。运行引擎：%@。能力边界：没有 Node.js、require/import、文件系统、原生网络 API 或持久后台任务能力。工具说明：%@",
                comment: "Built-in MCP custom JS tool description"
            ),
            tool.engine.displayName,
            tool.toolDescription
        )
    }
}

actor MCPBuiltInAppToolServerEngine {
    private let category: AppToolCatalogCategory
    private let jsonrpcVersion = "2.0"

    init(category: AppToolCatalogCategory) {
        self.category = category
    }

    func handleNotification(_ payload: Data) async throws {
        _ = try requestObject(from: payload)
    }

    func handleMessage(_ payload: Data) async throws -> Data {
        let request = try requestObject(from: payload)
        guard let id = request["id"] else {
            throw MCPClientError.invalidResponse
        }
        guard let method = request["method"] as? String else {
            return try errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            return try successResponse(id: id, result: initializeResult())
        case "tools/list":
            let result = await toolsListResult()
            return try successResponse(id: id, result: result)
        case "tools/call":
            return try successResponse(id: id, result: await toolCallResult(from: request["params"] as? [String: Any]))
        case "resources/list":
            return try successResponse(id: id, result: ["resources": []])
        case "resources/templates/list":
            return try successResponse(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return try successResponse(id: id, result: ["prompts": []])
        default:
            return try errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": MCPProtocolVersion.current,
            "capabilities": [
                "tools": [
                    "listChanged": false
                ],
                "resources": [
                    "subscribe": false,
                    "listChanged": false
                ],
                "prompts": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "ETOS Built-in App Tools - \(category.rawValue)",
                "version": "0.1.0"
            ]
        ]
    }

    private func toolsListResult() async -> [String: Any] {
        let category = self.category
        let descriptions = await MCPBuiltInAppToolServer.appToolDescriptions(for: category)
        let tools = descriptions.map { tool in
            [
                "name": tool.toolId,
                "description": tool.description ?? "",
                "inputSchema": tool.inputSchema?.toAny() ?? [
                    "type": "object",
                    "additionalProperties": true
                ]
            ] as [String: Any]
        }
        return ["tools": tools]
    }

    private func toolCallResult(from params: [String: Any]?) async -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            return errorToolResult(message: "Missing tool name")
        }
        guard MCPBuiltInAppToolServer.category(for: name) == category else {
            return errorToolResult(message: "Unknown built-in app tool: \(name)")
        }
        var arguments = params["arguments"] as? [String: Any] ?? [:]
        let argumentsJSON: String
        do {
            // 旧缓存或手动 MCP 请求也不能越过本机能力边界。
            if category == .deviceOperations || category == .mediaEnvironment || category == .visionLanguage {
                guard MCPNativeCapabilityAvailability.isToolAvailableOnCurrentPlatform(name) else {
                    throw MCPNativeCapabilityError.unsupportedTool(name)
                }
            }
            #if os(macOS)
            if category == .linux {
                guard let rawSourceSessionID = arguments.removeValue(
                    forKey: MCPBuiltInAppToolServer.conversationSourceSessionIDArgument
                ) as? String,
                      let sourceSessionID = UUID(uuidString: rawSourceSessionID),
                      let rawRunID = arguments.removeValue(
                        forKey: MCPBuiltInAppToolServer.localAgentRunIDArgument
                      ) as? String,
                      let sourceRunID = UUID(uuidString: rawRunID),
                      let toolCallID = arguments.removeValue(
                        forKey: MCPBuiltInAppToolServer.conversationToolCallIDArgument
                      ) as? String,
                      !toolCallID.isEmpty else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 工具缺少可信运行上下文。", comment: "Missing trusted Linux tool context")
                    )
                }
                let triggeringMessageID = (arguments.removeValue(
                    forKey: MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument
                ) as? String).flatMap(UUID.init(uuidString:))
                arguments.removeValue(
                    forKey: MCPBuiltInAppToolServer.localAgentSelectedMCPServerIDsArgument
                )
                let approvedCommandRuleIDs = Set((arguments.removeValue(
                    forKey: MCPBuiltInAppToolServer.localAgentApprovedCommandRuleIDsArgument
                ) as? [String] ?? []).compactMap(UUID.init(uuidString:)))
                argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
                let result = try await MCPBuiltInAppToolServer.executeLinuxTool(
                    toolName: name,
                    argumentsJSON: argumentsJSON,
                    sourceSessionID: sourceSessionID,
                    sourceRunID: sourceRunID,
                    triggeringMessageID: triggeringMessageID,
                    toolCallID: toolCallID,
                    approvedCommandRuleIDs: approvedCommandRuleIDs
                )
                return successToolResult(toolName: name, result: result)
            }

            #endif

            if category == .file {
                argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
                let result = try await MCPBuiltInAppToolServer.executeFileTool(
                    toolName: name,
                    argumentsJSON: argumentsJSON
                )
                return successToolResult(toolName: name, result: result)
            }

            if category == .deviceOperations {
                argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
                let result = try await MCPBuiltInAppToolServer.executeNativeDeviceTool(
                    toolName: name,
                    argumentsJSON: argumentsJSON
                )
                return successToolResult(toolName: name, result: result)
            }

            if category == .mediaEnvironment {
                argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
                let result = try await MCPBuiltInAppToolServer.executeNativeMediaTool(
                    toolName: name,
                    argumentsJSON: argumentsJSON
                )
                return successToolResult(toolName: name, result: result)
            }

            if category == .visionLanguage {
                argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
                let result = try await MCPBuiltInAppToolServer.executeNativeVisionLanguageTool(
                    toolName: name,
                    argumentsJSON: argumentsJSON
                )
                return successToolResult(toolName: name, result: result)
            }

            argumentsJSON = try prettyPrintedJSON(arguments, prettyPrinted: false)
            let result = try await MCPBuiltInAppToolServer.executeTool(
                toolName: name,
                argumentsJSON: argumentsJSON
            )
            return successToolResult(toolName: name, result: result)
        } catch {
            return errorToolResult(message: error.localizedDescription, toolName: name)
        }
    }

    private func successToolResult(toolName: String, result: String) -> [String: Any] {
        let structuredContent = parsedJSONObject(from: result) ?? [
            "tool_name": toolName,
            "result": result,
            "provider": "etos_builtin_app_tool"
        ]
        return [
            "content": [
                [
                    "type": "text",
                    "text": result
                ]
            ],
            "structuredContent": structuredContent,
            "isError": false
        ]
    }

    private func errorToolResult(message: String, toolName: String? = nil) -> [String: Any] {
        var content: [String: Any] = [
            "error": message,
            "provider": "etos_builtin_app_tool"
        ]
        if let toolName {
            content["tool_name"] = toolName
        }
        return [
            "content": [
                [
                    "type": "text",
                    "text": (try? prettyPrintedJSON(content)) ?? "\(content)"
                ]
            ],
            "structuredContent": content,
            "isError": true
        ]
    }

    private func requestObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return object
    }

    private func successResponse(id: Any, result: [String: Any]) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "result": result
        ])
    }

    private func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func responseData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func parsedJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func prettyPrintedJSON(_ object: [String: Any], prettyPrinted: Bool = true) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPClientError.invalidResponse
        }
        return text
    }
}

extension AppToolManager {
    func executeToolForBuiltInMCP(toolName: String, argumentsJSON: String) async throws -> String {
        if let kind = AppToolKind.resolve(from: toolName) {
            guard !Self.builtInToolKinds.contains(kind) else {
                throw AppToolExecutionError.unknownTool
            }
            guard kind.isAvailableOnCurrentPlatform else {
                throw AppToolExecutionError.toolDisabled(kind.displayName)
            }
            return try await Self.executeResolvedTool(
                kind: kind,
                argumentsJSON: argumentsJSON,
                current: self,
                sourceSessionID: nil,
                sourceMessageID: nil
            )
        }

        guard let customTool = customJSTool(withToolName: toolName) else {
            throw AppToolExecutionError.unknownTool
        }
        guard customTool.engine.isAvailableOnCurrentPlatform else {
            throw AppToolExecutionError.toolDisabled(customTool.displayName)
        }
        return try await executeCustomJSTool(customTool, argumentsJSON: argumentsJSON)
    }
}
