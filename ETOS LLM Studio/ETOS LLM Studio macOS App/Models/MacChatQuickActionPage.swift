import ETOSCore
import Foundation

/// 其余入口使用原生临时聊天菜单和 Settings 窗口。
enum MacChatQuickActionPage: String, CaseIterable, Identifiable, Sendable {
    case usageAnalytics, shortcuts, extendedFeatures, localTerminal
    var id: String { rawValue }

    var action: ChatQuickAction {
        switch self {
        case .usageAnalytics: .usageAnalytics
        case .shortcuts: .shortcuts
        case .extendedFeatures: .extendedFeatures
        case .localTerminal: .localTerminal
        }
    }
}

struct MacChatQuickActionDestination: Identifiable {
    let id = UUID()
    let page: MacChatQuickActionPage
}
