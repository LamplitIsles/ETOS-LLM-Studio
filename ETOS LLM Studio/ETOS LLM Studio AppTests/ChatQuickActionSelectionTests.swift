// ============================================================================
// ChatQuickActionSelectionTests.swift
// ============================================================================

import Testing
import ETOSCore
@testable import ETOS_LLM_Studio_App

@Suite("聊天快捷功能配置测试")
struct ChatQuickActionSelectionTests {
    @Test("临时对话使用隐私图标")
    func temporaryChatUsesPrivacySymbol() {
        #expect(ChatQuickAction.temporaryChat.systemImage == "eye.slash")
    }

    @Test("临时对话开关使用有无斜线区分状态")
    func temporaryChatStateUsesSlash() {
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: false) == "eye")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true) == "eye.slash.fill")
    }

    @Test("空配置和未知配置回退到全部快捷功能")
    func invalidSelectionUsesAllActionsFallback() {
        #expect(ChatQuickActionSelection.decode("") == ChatQuickAction.allCases)
        #expect(ChatQuickActionSelection.decode("unknown") == ChatQuickAction.allCases)
    }

    @Test("新用户数据库默认值选中全部快捷功能")
    func newUserDefaultSelectsAllActions() {
        guard case .text(let rawValue) = AppConfigKey.chatQuickActionIDs.defaultValue else {
            Issue.record("聊天快捷功能默认值不是文本配置")
            return
        }

        #expect(ChatQuickActionSelection.decode(rawValue) == ChatQuickAction.allCases)
    }

    @Test("多选配置去重并按界面顺序保存")
    func multipleSelectionIsNormalized() {
        let encoded = ChatQuickActionSelection.encode([
            .shortcuts,
            .settings,
            .usageAnalytics,
            .shortcuts
        ])

        #expect(encoded == "settings,usageAnalytics,shortcuts")
        #expect(ChatQuickActionSelection.decode(encoded) == [.settings, .usageAnalytics, .shortcuts])
    }

}
