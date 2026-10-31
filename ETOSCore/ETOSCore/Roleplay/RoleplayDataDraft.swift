import Foundation

public enum RoleplayDataTarget: Hashable, Sendable {
    case macros
    case variables(RoleplayVariableScope, messageID: UUID?, versionIndex: Int)
}

/// 草稿只带所选层的原值及绑定对象，不把其他层的旧副本写回数据库。
public struct RoleplayDataDraft: Sendable {
    public let sessionID: UUID
    public let target: RoleplayDataTarget
    public let subjectID: UUID?
    public let originalValues: [String: JSONValue]

    public func normalizedValues(_ values: [String: JSONValue]) throws -> [String: JSONValue] {
        switch target {
        case .macros: return try Self.normalizeMacros(values)
        case .variables(let scope, _, _):
            guard !RoleplayVariableSnapshot.containsReservedValues(values, scope: scope) else { throw RoleplayDataDraftError.reservedKeys }
            return values
        }
    }

    public static func normalizeMacros(_ values: [String: JSONValue]) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        var names = Set<String>()
        for (key, value) in values {
            let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw RoleplayDataDraftError.emptyMacroName }
            guard !name.contains("{{"), !name.contains("}}") else { throw RoleplayDataDraftError.invalidMacroName }
            guard case .string = value else { throw RoleplayDataDraftError.invalidMacroValue }
            // 解析器忽略大小写，同名宏不能依赖字典遍历顺序决定替换值。
            guard names.insert(name.lowercased()).inserted else { throw RoleplayDataDraftError.duplicateMacroName }
            result[name] = value
        }
        return result
    }
}

public enum RoleplayDataDraftError: LocalizedError {
    case emptyMacroName, invalidMacroName, invalidMacroValue, duplicateMacroName, scopeUnavailable, reservedKeys

    public var errorDescription: String? {
        switch self {
        case .emptyMacroName: NSLocalizedString("宏名称不能为空。", comment: "")
        case .invalidMacroName: NSLocalizedString("宏名称不要包含花括号。", comment: "")
        case .invalidMacroValue: NSLocalizedString("宏值必须是字符串。", comment: "")
        case .duplicateMacroName: NSLocalizedString("宏名称不能重复。", comment: "")
        case .scopeUnavailable: NSLocalizedString("当前作用域暂不可用，请先绑定角色、身份或创建消息。", comment: "")
        case .reservedKeys: NSLocalizedString("变量包含内部保留字段，请通过对应设置修改。", comment: "")
        }
    }
}
