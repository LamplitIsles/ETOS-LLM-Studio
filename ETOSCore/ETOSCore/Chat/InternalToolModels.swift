import Foundation

/// 内部工具定义，与服务商无关。
public enum InternalToolKind: String, Codable, Hashable, Sendable {
    case openAIResponsesLocalShell = "openai_responses_local_shell"
}

public struct InternalToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue // 使用已有的 JSONValue 来定义参数结构
    public let isBlocking: Bool // 此工具是否需要阻塞主流程并等待返回结果
    /// nil 表示普通函数工具；非空值只由明确支持该原生工具的适配器消费。
    public let kind: InternalToolKind?
    public let providerSpecificFields: [String: JSONValue]?

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        isBlocking: Bool = true,
        kind: InternalToolKind? = nil,
        providerSpecificFields: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.isBlocking = isBlocking
        self.kind = kind
        self.providerSpecificFields = providerSpecificFields
    }
}

/// 工具结果的终态来源。正文只负责承载输出，不能再反向推断审批状态。
public enum InternalToolCallResultDisposition: String, Codable, Hashable, Sendable {
    /// 调用已经结束，工具未报告执行错误。
    case completed
    /// 调用已经结束，但工具明确报告执行失败。
    case failed
    /// 调用在执行前被用户或治理策略明确拒绝。
    case rejected
}

/// 内部工具调用，与服务商无关。
public struct InternalToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let toolName: String
    public let arguments: String // 参数通常是JSON字符串
    public var result: String? // 工具执行结果（用于展示）
    public var resultDisposition: InternalToolCallResultDisposition?
    public let providerSpecificFields: [String: JSONValue]? // 服务商专有字段（例如 Gemini thought_signature）

    /// 只认可执行链路写入的结构化终态，避免工具正文中的安全规则或错误示例污染 UI。
    public var wasRejected: Bool {
        resultDisposition == .rejected
    }

    /// 只认可执行链路写入的失败终态，避免根据任意工具正文猜测执行结果。
    public var executionFailed: Bool {
        resultDisposition == .failed
    }

    public init(
        id: String,
        toolName: String,
        arguments: String,
        result: String? = nil,
        resultDisposition: InternalToolCallResultDisposition? = nil,
        providerSpecificFields: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.resultDisposition = resultDisposition
        self.providerSpecificFields = providerSpecificFields
    }
}
