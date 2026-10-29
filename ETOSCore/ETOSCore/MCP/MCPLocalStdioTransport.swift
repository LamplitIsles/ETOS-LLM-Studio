// ============================================================================
// MCPLocalStdioTransport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本机 stdio MCP 的配置及公共错误类型。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPLocalStdioLaunchPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case onDemand = "on_demand"
    case manual

    public var displayName: String {
        switch self {
        case .onDemand:
            return NSLocalizedString("调用时启动", comment: "Local stdio MCP on-demand launch policy")
        case .manual:
            return NSLocalizedString("手动连接后常驻", comment: "Local stdio MCP manual persistent launch policy")
        }
    }
}

public enum MCPLocalStdioIdlePolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case immediate
    case oneMinute = "one_minute"
    case fiveMinutes = "five_minutes"
    case fifteenMinutes = "fifteen_minutes"
    case keepAlive = "keep_alive"

    public var displayName: String {
        switch self {
        case .immediate:
            return NSLocalizedString("调用结束后退出", comment: "Local stdio MCP immediate idle policy")
        case .oneMinute:
            return NSLocalizedString("空闲 1 分钟后退出", comment: "Local stdio MCP one minute idle policy")
        case .fiveMinutes:
            return NSLocalizedString("空闲 5 分钟后退出", comment: "Local stdio MCP five minute idle policy")
        case .fifteenMinutes:
            return NSLocalizedString("空闲 15 分钟后退出", comment: "Local stdio MCP fifteen minute idle policy")
        case .keepAlive:
            return NSLocalizedString("保持到手动停止", comment: "Local stdio MCP keep alive idle policy")
        }
    }

    var delayNanoseconds: UInt64? {
        switch self {
        case .immediate: return 0
        case .oneMinute: return 60 * 1_000_000_000
        case .fiveMinutes: return 5 * 60 * 1_000_000_000
        case .fifteenMinutes: return 15 * 60 * 1_000_000_000
        case .keepAlive: return nil
        }
    }
}

public struct MCPLocalStdioConfiguration: Codable, Hashable, Sendable {
    public var command: String
    public var arguments: [String]
    /// 仅用于接收常见 mcpServers JSON 的字面环境；写入 MCP Store 前会迁移为记录引用并清空。
    public var environment: [String: String]
    public var environmentVariableIDs: [UUID]
    public var inheritLocalLinuxEnvironment: Bool
    public var workingDirectory: String
    public var startupTimeoutSeconds: TimeInterval
    public var launchPolicy: MCPLocalStdioLaunchPolicy
    public var idlePolicy: MCPLocalStdioIdlePolicy

    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        environmentVariableIDs: [UUID] = [],
        inheritLocalLinuxEnvironment: Bool = true,
        workingDirectory: String = "",
        startupTimeoutSeconds: TimeInterval = 30,
        launchPolicy: MCPLocalStdioLaunchPolicy = .onDemand,
        idlePolicy: MCPLocalStdioIdlePolicy = .fiveMinutes
    ) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.environmentVariableIDs = environmentVariableIDs
        self.inheritLocalLinuxEnvironment = inheritLocalLinuxEnvironment
        self.workingDirectory = workingDirectory
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.launchPolicy = launchPolicy
        self.idlePolicy = idlePolicy
    }

    public var commandLine: String {
        ([command] + arguments).joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case arguments
        case environment
        case environmentVariableIDs
        case inheritLocalLinuxEnvironment
        case workingDirectory
        case startupTimeoutSeconds
        case launchPolicy
        case idlePolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        environmentVariableIDs = try container.decodeIfPresent([UUID].self, forKey: .environmentVariableIDs) ?? []
        inheritLocalLinuxEnvironment = try container.decodeIfPresent(
            Bool.self,
            forKey: .inheritLocalLinuxEnvironment
        ) ?? true
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        startupTimeoutSeconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .startupTimeoutSeconds
        ) ?? 30
        launchPolicy = try container.decodeIfPresent(
            MCPLocalStdioLaunchPolicy.self,
            forKey: .launchPolicy
        ) ?? .onDemand
        idlePolicy = try container.decodeIfPresent(
            MCPLocalStdioIdlePolicy.self,
            forKey: .idlePolicy
        ) ?? .fiveMinutes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
        if !environment.isEmpty { try container.encode(environment, forKey: .environment) }
        if !environmentVariableIDs.isEmpty {
            try container.encode(environmentVariableIDs, forKey: .environmentVariableIDs)
        }
        if !inheritLocalLinuxEnvironment {
            try container.encode(false, forKey: .inheritLocalLinuxEnvironment)
        }
        if workingDirectory != "" {
            try container.encode(workingDirectory, forKey: .workingDirectory)
        }
        if startupTimeoutSeconds != 30 {
            try container.encode(startupTimeoutSeconds, forKey: .startupTimeoutSeconds)
        }
        if launchPolicy != .onDemand { try container.encode(launchPolicy, forKey: .launchPolicy) }
        if idlePolicy != .fiveMinutes { try container.encode(idlePolicy, forKey: .idlePolicy) }
    }
}

public enum MCPLocalStdioError: LocalizedError {
    case dependencyMissing(command: String, suggestedRecipe: String?)
    case processExited(exitCode: Int32, linuxError: Int32)
    case invalidStandardOutput
    case legacyTransportUnavailable

    public var errorDescription: String? {
        switch self {
        case .dependencyMissing(let command, let suggestedRecipe):
            if let suggestedRecipe {
                return String(
                    format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装；可前往“环境准备”运行 %@。", comment: "Local stdio MCP missing dependency with recipe"),
                    command,
                    suggestedRecipe
                )
            }
            return String(
                format: NSLocalizedString("MCP_RUNTIME_DEPENDENCY_MISSING：找不到命令 %@。ETOS 不会自动安装，请在终端中自行安装后重试。", comment: "Local stdio MCP missing dependency"),
                command
            )
        case .processExited(let exitCode, let linuxError):
            return String(
                format: NSLocalizedString("本地 MCP 进程已退出（exit=%d，errno=%d）。请检查命令和依赖；ETOS 不会自动安装缺失软件。", comment: "Local stdio MCP process exited error"),
                exitCode,
                linuxError
            )
        case .invalidStandardOutput:
            return NSLocalizedString("本地 MCP 的 stdout 含有非 JSON-RPC 内容；普通日志必须写入 stderr。", comment: "Local stdio MCP invalid stdout error")
        case .legacyTransportUnavailable:
            return NSLocalizedString("本地 stdio MCP 只支持当前流式 MCP 客户端。", comment: "Local stdio MCP legacy client error")
        }
    }
}

public final class MCPLocalStdioLegacyTransport: MCPTransport, @unchecked Sendable {
    public init() {}

    public func sendMessage(_ payload: Data) async throws -> Data {
        throw MCPLocalStdioError.legacyTransportUnavailable
    }

    public func sendNotification(_ payload: Data) async throws {
        throw MCPLocalStdioError.legacyTransportUnavailable
    }
}
