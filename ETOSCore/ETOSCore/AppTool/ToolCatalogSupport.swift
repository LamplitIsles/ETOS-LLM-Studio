// ============================================================================
// ToolCatalogSupport.swift
// ============================================================================
// 统一工具中心所需的共享辅助逻辑。
// - 汇总内置工具状态
// - 生成工具参数 Schema 摘要
// ============================================================================

import Foundation

public enum ToolCatalogBuiltInToolKind: String, CaseIterable, Identifiable, Sendable {
    case widgetCard
    case getSystemTime

    public var id: String { rawValue }
}

public enum ToolCatalogBuiltInToolStatusReason: String, Equatable, Sendable {
    case enabled
    case isolatedBySession
    case widgetDisabled
    case getSystemTimeDisabled
}

public struct ToolCatalogBuiltInToolState: Identifiable, Equatable, Sendable {
    public let kind: ToolCatalogBuiltInToolKind
    public let isConfiguredEnabled: Bool
    public let isAvailableInCurrentSession: Bool
    public let statusReason: ToolCatalogBuiltInToolStatusReason

    public var id: ToolCatalogBuiltInToolKind { kind }

    public init(
        kind: ToolCatalogBuiltInToolKind,
        isConfiguredEnabled: Bool,
        isAvailableInCurrentSession: Bool,
        statusReason: ToolCatalogBuiltInToolStatusReason
    ) {
        self.kind = kind
        self.isConfiguredEnabled = isConfiguredEnabled
        self.isAvailableInCurrentSession = isAvailableInCurrentSession
        self.statusReason = statusReason
    }
}

public enum AppToolCatalogCategory: String, Hashable, Codable, Sendable {
    case interaction
    case conversation
    case file
    case database
    case custom
    case feedback
    case linux
    case browser
    case deviceOperations = "device_operations"
    case mediaEnvironment = "media_environment"
    case visionLanguage = "vision_language"
}

public enum ToolCatalogSupport {
    public static func builtInToolStates(
        enableWidgetTool: Bool,
        enableGetSystemTimeTool: Bool,
        isToolIsolated: Bool
    ) -> [ToolCatalogBuiltInToolState] {
        let widgetReason: ToolCatalogBuiltInToolStatusReason = isToolIsolated && enableWidgetTool
            ? .isolatedBySession
            : (enableWidgetTool ? .enabled : .widgetDisabled)
        let getSystemTimeReason: ToolCatalogBuiltInToolStatusReason = isToolIsolated && enableGetSystemTimeTool
            ? .isolatedBySession
            : (enableGetSystemTimeTool ? .enabled : .getSystemTimeDisabled)

        return [
            ToolCatalogBuiltInToolState(
                kind: .widgetCard,
                isConfiguredEnabled: enableWidgetTool,
                isAvailableInCurrentSession: enableWidgetTool && !isToolIsolated,
                statusReason: widgetReason
            ),
            ToolCatalogBuiltInToolState(
                kind: .getSystemTime,
                isConfiguredEnabled: enableGetSystemTimeTool,
                isAvailableInCurrentSession: enableGetSystemTimeTool && !isToolIsolated,
                statusReason: getSystemTimeReason
            )
        ]
    }

    public static func configuredEnabledCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isConfiguredEnabled).count
    }

    public static func availableCount(for states: [ToolCatalogBuiltInToolState]) -> Int {
        states.filter(\.isAvailableInCurrentSession).count
    }

    public static func appToolCategory(for kind: AppToolKind) -> AppToolCatalogCategory {
        switch kind {
        case .echoText, .fillUserInput, .submitFeedbackTicket:
            return .interaction
        case .listSandboxDirectory, .readSandboxFile, .writeSandboxFile, .searchSandboxFiles,
             .readSandboxFileChunk, .moveSandboxItem, .copySandboxItem, .createSandboxDirectory,
             .batchEditSandboxFile, .undoSandboxMutation, .diffSandboxFile, .editSandboxFile,
             .deleteSandboxItem:
            return .file
        case .listSQLiteTables, .querySQLite, .mutateSQLite:
            return .database
        case .executeJSCJavaScript, .createCustomJSCJSTool:
            return .custom
        case .showWidget, .getSystemTime:
            return .interaction
        }
    }

    public static func schemaSummary(for schema: JSONValue?, fieldLimit: Int = 4) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }

        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }

        var segments: [String] = ["type=\(typeLabel)"]

        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            let fields = properties.keys.sorted().prefix(max(1, fieldLimit))
            segments.append("fields=\(fields.joined(separator: ", "))")
        }

        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item {
                    return key
                }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }

        return segments.joined(separator: " · ")
    }
}
