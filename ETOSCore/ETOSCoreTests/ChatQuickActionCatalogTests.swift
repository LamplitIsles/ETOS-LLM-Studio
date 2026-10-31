import Foundation
import Testing
@testable import ETOSCore

struct ChatQuickActionCatalogTests {
    @Test("共享目录保持当前快捷功能的标识及顺序")
    func preservesStoredIdentifiers() {
        var expected = [
            "temporaryChat", "settings", "usageAnalytics", "shortcuts", "extendedFeatures"
        ]
        #if os(macOS)
        expected.append("localTerminal")
        #endif
        #expect(ChatQuickAction.allCases.map(\.rawValue) == expected)
        guard case .text(let raw) = AppConfigKey.chatQuickActionIDs.defaultValue else {
            Issue.record("默认快捷功能配置应为文本"); return
        }
        #expect(ChatQuickActionSelection.decode(raw) == ChatQuickAction.allCases)
        #expect(ChatQuickActionSelection.encode([]) == ChatQuickActionSelection.encode(ChatQuickAction.allCases))
    }

    @Test("混合未知标识时保留有效选择并规范顺序，不扩展成全部")
    func mixedUnknownValuesKeepValidSubset() {
        #expect(ChatQuickActionSelection.decode("toolCenter,browser,unknown,shortcuts,settings,browser") == [.settings, .shortcuts])
        #expect(ChatQuickActionSelection.encode([.shortcuts, .settings, .shortcuts]) == "settings,shortcuts")
        #expect(ChatQuickActionSelection.decode("unknown,,") == ChatQuickAction.allCases)
    }

    @Test("临时聊天三种状态共享隐私图标，其他功能不受状态影响")
    func temporaryModeSymbolsRemainCompatible() {
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: false) == "eye")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true) == "eye.slash.fill")
        #expect(ChatQuickAction.shortcuts.systemImage(isTemporaryChatEnabled: true) == "bolt")
    }
}
