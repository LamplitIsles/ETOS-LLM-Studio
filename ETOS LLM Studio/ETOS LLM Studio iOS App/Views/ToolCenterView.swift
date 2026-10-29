// ============================================================================
// ToolCenterView.swift
// ============================================================================
// ToolCenterView 界面 (iOS)
// - 统一预览聊天工具
// - 在同一入口集中调整启用状态与关键设置
// ============================================================================

import SwiftUI
import ETOSCore

struct ToolCenterView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    @StateObject var appToolManager = AppToolManager.shared
    @StateObject var shortcutManager = ShortcutToolManager.shared
    @StateObject var skillManager = SkillManager.shared

    @ObservedObject var appConfig = AppConfigStore.shared

    @State var searchText: String = ""
    @State var showEnabledOnly: Bool = false
    @State var isShowingIntroDetails = false
    @State var isShowingBuiltInIntroDetails = false

    var currentSessionIsolationActive: Bool {
        viewModel.currentSession?.isToolContextIsolationActive ?? false
    }

    var builtInStates: [ToolCatalogBuiltInToolState] {
        ToolCatalogSupport.builtInToolStates(
            enableWidgetTool: appToolManager.isToolEnabled(.showWidget),
            enableGetSystemTimeTool: appToolManager.isToolEnabled(.getSystemTime),
            isToolIsolated: currentSessionIsolationActive
        )
    }

    var configuredBuiltInCount: Int {
        ToolCatalogSupport.configuredEnabledCount(for: builtInStates)
    }

    var availableBuiltInCount: Int {
        ToolCatalogSupport.availableCount(for: builtInStates)
    }

    var filteredBuiltInStates: [ToolCatalogBuiltInToolState] {
        let matchesGroup = matchesSearch(
            for: [
                NSLocalizedString("内置工具", comment: "Built-in tools section title"),
                NSLocalizedString("内置工具控制网页卡片、问答与系统时间能力。", comment: "Built-in tools footer")
            ]
        )
        return builtInStates.filter { state in
            guard matchesGroup || matchesSearch(for: builtInKeywords(for: state.kind)) else { return false }
            if showEnabledOnly {
                return state.isConfiguredEnabled
            }
            return true
        }
    }

    var isBuiltInSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredBuiltInStates.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                NSLocalizedString("内置工具", comment: "Built-in tools section title"),
                NSLocalizedString("内置工具控制网页卡片、问答与系统时间能力。", comment: "Built-in tools footer")
            ]
        )
    }

    var filteredShortcutTools: [ShortcutToolDefinition] {
        shortcutManager.tools
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .filter { tool in
                let keywords = [
                    tool.displayName,
                    tool.name,
                    tool.effectiveDescription
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return tool.isEnabled
                }
                return true
            }
    }

    var filteredSkills: [SkillMetadata] {
        skillManager.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { skill in
                let keywords = [
                    skill.name,
                    skill.description,
                    skill.compatibility ?? "",
                    "Agent Skills",
                    "use_skill"
                ]
                guard matchesSearch(for: keywords) else { return false }
                if showEnabledOnly {
                    return skillManager.isSkillEnabled(skill.name)
                }
                return true
            }
    }

    var isSkillsSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredSkills.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                "Agent Skills",
                "use_skill",
                NSLocalizedString("向模型暴露 Agent Skills（use_skill）", comment: "Expose Agent Skills to model")
            ]
        )
    }

    var isShortcutSectionVisible: Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return true
        }
        if !filteredShortcutTools.isEmpty {
            return true
        }
        return matchesSearch(
            for: [
                NSLocalizedString("快捷指令工具", comment: "Shortcut tools section title"),
                NSLocalizedString("向模型暴露快捷指令工具", comment: "Expose shortcut tools to model")
            ]
        )
    }

    var configuredShortcutCount: Int {
        shortcutManager.tools.filter(\.isEnabled).count
    }

    var configuredSkillCount: Int {
        skillManager.skills.filter { skillManager.isSkillEnabled($0.name) }.count
    }

    var availableShortcutCount: Int {
        guard shortcutManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredShortcutCount
    }

    var availableSkillCount: Int {
        guard skillManager.chatToolsEnabled, !currentSessionIsolationActive else { return 0 }
        return configuredSkillCount
    }

    var hasVisibleTools: Bool {
        isBuiltInSectionVisible
        || isSkillsSectionVisible
        || isShortcutSectionVisible
    }

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("工具中心", comment: "Tool center intro title"),
                    summary: NSLocalizedString("先看当前会话能用什么，再按工具来源进入细分设置。", comment: "Tool center intro summary"),
                    details: NSLocalizedString("工具中心新版说明正文", comment: "Tool center intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            filterSection
            if isBuiltInSectionVisible {
                builtInSection
            }
            if isSkillsSectionVisible {
                skillsSection
            }
            if isShortcutSectionVisible {
                shortcutSection
            }

            if !hasVisibleTools {
                Section {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "No matching tools in tool center"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具中心", comment: "Tool center title"))
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text(NSLocalizedString("搜索工具", comment: "Search tools prompt"))
        )
        .onAppear {
            skillManager.reloadFromDisk()
        }
        .guideSettingsPageContext(
            id: "tool-center",
            title: NSLocalizedString("工具中心", comment: "工具中心向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center")],
            settings: guideSettings
        )
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .bool("built_in_tools_enabled", label: NSLocalizedString("向模型暴露内置工具", comment: "向导设置字段"), get: { appToolManager.chatToolsEnabled }, set: { appToolManager.setChatToolsEnabled($0) }),
            .bool("shortcut_tools_enabled", label: NSLocalizedString("向模型暴露快捷指令工具", comment: "向导设置字段"), get: { shortcutManager.chatToolsEnabled }, set: { shortcutManager.setChatToolsEnabled($0) }),
            .bool("agent_skills_enabled", label: NSLocalizedString("向模型暴露 Agent Skills", comment: "向导设置字段"), get: { skillManager.chatToolsEnabled }, set: { skillManager.setChatToolsEnabled($0) }),
            .readOnly("session_tool_isolation", label: NSLocalizedString("当前会话工具隔离", comment: "向导设置字段"), value: { .bool(currentSessionIsolationActive) }),
            .readOnly("configured_builtin_count", label: NSLocalizedString("已启用内置工具数", comment: "向导设置字段"), value: { .int(configuredBuiltInCount) }),
            .readOnly("configured_shortcut_count", label: NSLocalizedString("已启用快捷指令工具数", comment: "向导设置字段"), value: { .int(configuredShortcutCount) }),
            .readOnly("configured_skill_count", label: NSLocalizedString("已启用 Agent Skill 数", comment: "向导设置字段"), value: { .int(configuredSkillCount) })
        ]
    }
}
