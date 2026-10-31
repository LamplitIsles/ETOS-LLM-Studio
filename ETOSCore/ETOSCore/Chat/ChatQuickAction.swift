import Foundation

/// iOS 与 Mac 共享稳定标识和显示顺序，继续读写 ui.chatQuickActionIDs。
public enum ChatQuickAction: String, CaseIterable, Identifiable, Sendable {
    case temporaryChat
    case settings
    case usageAnalytics
    case shortcuts
    case extendedFeatures
    #if os(macOS)
    case localTerminal
    #endif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .temporaryChat: return NSLocalizedString("临时对话", comment: "聊天快捷功能标题")
        case .settings: return NSLocalizedString("设置", comment: "聊天快捷功能标题")
        case .usageAnalytics: return NSLocalizedString("用量统计", comment: "聊天快捷功能标题")
        case .shortcuts: return NSLocalizedString("快捷指令工具集成", comment: "聊天快捷功能标题")
        case .extendedFeatures: return NSLocalizedString("拓展功能", comment: "聊天快捷功能标题")
        #if os(macOS)
        case .localTerminal: return NSLocalizedString("终端", comment: "聊天快捷功能标题")
        #endif
        }
    }

    public var systemImage: String {
        switch self {
        case .temporaryChat: return "eye.slash"
        case .settings: return "gearshape"
        case .usageAnalytics: return "chart.bar"
        case .shortcuts: return "bolt"
        case .extendedFeatures: return "ellipsis.circle"
        #if os(macOS)
        case .localTerminal: return "terminal"
        #endif
        }
    }

    public func systemImage(isTemporaryChatEnabled: Bool) -> String {
        guard self == .temporaryChat else { return systemImage }
        guard isTemporaryChatEnabled else { return "eye" }
        return "eye.slash.fill"
    }
}

public enum ChatQuickActionSelection {
    public static let fallback = ChatQuickAction.allCases

    public static func decode(_ rawValue: String) -> [ChatQuickAction] {
        let selectedIDs = Set(rawValue.split(separator: ",").map(String.init))
        let actions = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return actions.isEmpty ? fallback : actions
    }

    public static func encode(_ actions: [ChatQuickAction]) -> String {
        let selectedIDs = Set(actions.map(\.rawValue))
        let normalized = ChatQuickAction.allCases.filter { selectedIDs.contains($0.rawValue) }
        return (normalized.isEmpty ? fallback : normalized).map(\.rawValue).joined(separator: ",")
    }
}
