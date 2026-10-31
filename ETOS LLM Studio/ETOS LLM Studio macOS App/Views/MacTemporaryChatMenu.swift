import ETOSCore
import SwiftUI

@MainActor
struct MacTemporaryChatMenu: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Binding var showingIntroduction: Bool

    var body: some View {
        Menu {
            Button(NSLocalizedString("开启临时对话", comment: "")) { workspace.enableTemporaryChat() }
                .disabled(!canChangeMode || workspace.isTemporaryChat)
            Divider()
            Button(NSLocalizedString("使用说明", comment: "")) { showingIntroduction = true }
        } label: {
            Label(NSLocalizedString("临时对话", comment: ""), systemImage: ChatQuickAction.temporaryChat.systemImage(
                isTemporaryChatEnabled: workspace.isTemporaryChat))
        }
        .disabled(!workspace.canManageLocalModels)
    }

    private var canChangeMode: Bool {
        workspace.canModifyCurrentHistory && (workspace.isTemporaryChat || workspace.messages.isEmpty)
    }
}

/// 由工具栏提供锚点，不能把弹窗挂在原生菜单临时生成的条目上。
@MainActor
struct MacTemporaryChatIntroductionView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(NSLocalizedString("临时对话只保存在运行期间，重新启动后不会恢复。", comment: ""))
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("临时对话", comment: ""))
            .guideSettingsPageContext(
                id: "mac-temporary-chat-introduction", title: NSLocalizedString("临时对话", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: isActive && workspace.canManageLocalModels,
                settings: [.readOnly("temporary_chat", label: NSLocalizedString("状态", comment: ""), value: {
                    .bool(workspace.isTemporaryChat)
                })]
            )
        }
        .modifier(MacAppLockOverlayModifier())
        .frame(width: 420, height: 340)
    }
}
