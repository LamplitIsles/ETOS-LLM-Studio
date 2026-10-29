import ETOSCore
import SwiftUI

/// 与移动端一致地分开会话和输出参数，向导只暴露当前页可见的字段。
struct MacCoreSettingsView: View {
    enum Page: String { case conversation, output }
    let page: Page
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared

    private var title: String {
        switch page {
        case .conversation: NSLocalizedString("会话", comment: "")
        case .output: NSLocalizedString("输出", comment: "")
        }
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "core-\(page.rawValue)", title: NSLocalizedString("使用说明", comment: ""),
                    details: introduction, documentID: "macos-workspace", isActive: isActive)
            }
            switch page {
            case .conversation:
                Section {
                    Toggle(NSLocalizedString("自动命名会话", comment: ""), isOn: $configuration.enableAutoSessionNaming)
                    Stepper(value: $configuration.maxChatHistory, in: 0...1000) {
                        Text(String(format: NSLocalizedString("历史消息数：%d", comment: ""), configuration.maxChatHistory))
                    }
                }
            case .output:
                Section { Toggle(NSLocalizedString("流式输出", comment: ""), isOn: $configuration.enableStreaming) }
                Section(NSLocalizedString("生成参数", comment: "")) {
                    Toggle(NSLocalizedString("启用温度参数", comment: ""), isOn: $configuration.aiTemperatureEnabled)
                    Slider(value: $configuration.aiTemperature, in: 0...2) { Text(NSLocalizedString("温度", comment: "")) }
                        .disabled(!configuration.aiTemperatureEnabled)
                    Toggle(NSLocalizedString("启用 Top P", comment: ""), isOn: $configuration.aiTopPEnabled)
                    Slider(value: $configuration.aiTopP, in: 0...1) { Text(NSLocalizedString("Top P", comment: "")) }
                        .disabled(!configuration.aiTopPEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-settings-\(page.rawValue)"), title: title,
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: isActive, settings: settings)
    }

    private var introduction: String {
        switch page {
        case .conversation: NSLocalizedString("mac.settings.conversation.help", value: "Automatic naming and history limits apply to conversation requests. These settings save immediately.", comment: "Mac 会话设置说明")
        case .output: NSLocalizedString("mac.settings.output.help", value: "Streaming displays a reply as it arrives. Temperature and Top P are sent only when their switches are enabled; supported ranges depend on the model. Changes save immediately and apply to future requests.", comment: "Mac 输出设置说明")
        }
    }

    private var settings: [GuidePageSetting] {
        switch page {
        case .conversation: [
            .bool("auto_title", label: NSLocalizedString("自动命名会话", comment: ""), get: { configuration.enableAutoSessionNaming }, set: { configuration.enableAutoSessionNaming = $0 }),
            .integer("history_limit", label: NSLocalizedString("历史消息数", comment: ""), range: 0...1000, get: { configuration.maxChatHistory }, set: { configuration.maxChatHistory = $0 })
        ]
        case .output: [
            .bool("streaming", label: NSLocalizedString("流式输出", comment: ""), get: { configuration.enableStreaming }, set: { configuration.enableStreaming = $0 }),
            .bool("temperature_enabled", label: NSLocalizedString("启用温度参数", comment: ""), get: { configuration.aiTemperatureEnabled }, set: { configuration.aiTemperatureEnabled = $0 }),
            .double("temperature", label: NSLocalizedString("温度", comment: ""), range: 0...2, get: { configuration.aiTemperature }, set: { configuration.aiTemperature = $0 }),
            .bool("top_p_enabled", label: NSLocalizedString("启用 Top P", comment: ""), get: { configuration.aiTopPEnabled }, set: { configuration.aiTopPEnabled = $0 }),
            .double("top_p", label: NSLocalizedString("Top P", comment: ""), range: 0...1, get: { configuration.aiTopP }, set: { configuration.aiTopP = $0 })
        ]
        }
    }
}
