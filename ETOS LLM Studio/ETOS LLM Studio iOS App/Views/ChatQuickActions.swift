// ============================================================================
// ChatQuickActions.swift
// ============================================================================
// ETOS LLM Studio
//
// 统一描述聊天页可配置快捷功能及其设置界面。
// ============================================================================

import SwiftUI
import ETOSCore

struct ChatQuickActionSettingsView: View {
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var selectedActions: [ChatQuickAction] = ChatQuickActionSelection.fallback

    var body: some View {
        List {
            Section {
                ForEach(ChatQuickAction.allCases) { action in
                    Button {
                        toggle(action)
                    } label: {
                        HStack {
                            Label(action.title, systemImage: action.systemImage)
                            Spacer()
                            if selectedActions.contains(action) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedActions.count == 1 && selectedActions.contains(action))
                }
            } footer: {
                Text(NSLocalizedString("选择一个功能时会直接执行；选择多个功能时，聊天页按钮会展开自适应快捷文件夹。至少保留一个功能。", comment: "聊天快捷功能设置说明"))
            }
        }
        .navigationTitle(NSLocalizedString("聊天快捷功能", comment: "聊天快捷功能设置页标题"))
        .guideSettingsPageContext(
            id: "settings-chat-quick-actions",
            title: NSLocalizedString("聊天快捷功能", comment: "聊天快捷功能向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            settings: [
                .json(
                    "actions",
                    label: NSLocalizedString("已选择的快捷功能", comment: "聊天快捷功能向导字段"),
                    schema: .dictionary([
                        "type": .string("array"),
                        "items": .dictionary([
                            "type": .string("string"),
                            "enum": .array(ChatQuickAction.allCases.map { .string($0.rawValue) })
                        ]),
                        "minItems": .int(1),
                        "uniqueItems": .bool(true)
                    ]),
                    get: { .array(selectedActions.map { .string($0.rawValue) }) },
                    normalize: { value in
                        guard case .array(let items) = value, !items.isEmpty else { throw GuideError.invalidToolArguments }
                        var seen = Set<ChatQuickAction>()
                        let actions = try items.map { item -> ChatQuickAction in
                            guard case .string(let rawValue) = item,
                                  let action = ChatQuickAction(rawValue: rawValue),
                                  seen.insert(action).inserted else {
                                throw GuideError.invalidToolArguments
                            }
                            return action
                        }
                        return .array(actions.map { .string($0.rawValue) })
                    },
                    set: { value in
                        guard case .array(let items) = value else { throw GuideError.invalidToolArguments }
                        let actions = try items.map { item -> ChatQuickAction in
                            guard case .string(let rawValue) = item,
                                  let action = ChatQuickAction(rawValue: rawValue) else {
                                throw GuideError.invalidToolArguments
                            }
                            return action
                        }
                        selectedActions = actions
                        appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(actions)
                    }
                )
            ]
        )
        .onAppear(perform: reloadSelection)
        .onChange(of: appConfig.chatQuickActionIDs) { _, _ in
            reloadSelection()
        }
    }

    private func toggle(_ action: ChatQuickAction) {
        if let index = selectedActions.firstIndex(of: action) {
            guard selectedActions.count > 1 else { return }
            selectedActions.remove(at: index)
        } else {
            selectedActions.append(action)
        }
        appConfig.chatQuickActionIDs = ChatQuickActionSelection.encode(selectedActions)
    }

    private func reloadSelection() {
        selectedActions = ChatQuickActionSelection.decode(appConfig.chatQuickActionIDs)
    }
}
