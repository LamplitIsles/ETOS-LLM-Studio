import ETOSCore
import SwiftUI

/// 设置沿用移动端的功能名称；桌面用稳定的侧栏定位，详情页各自拥有导航栈。
struct MacSettingsView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var selection: MacSettingsDestination? = .display
    @State private var visible = false
    private var available: Bool { visible && workspace.canManageLocalModels && appLock.state != .locked }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    rows([.display])
                }
                Section(NSLocalizedString("拓展能力", comment: "")) {
                    rows([.usage, .shortcuts, .speech, .tts, .extended])
                }
                Section(NSLocalizedString("设置", comment: "")) {
                    rows([.general, .security, .about])
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(NSLocalizedString("设置", comment: ""))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack { destination(selection ?? .display) }
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(workspace.isRestoringData)
        .frame(minWidth: 820, minHeight: 620)
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
        .networkConnectionApprovalHost(isEnabled: available)
        .modifier(MacSettingsAchievementTriggers())
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: configuration.appLanguage) { _, language in AppLanguageRuntime.apply(rawValue: language) }
    }

    private func rows(_ destinations: [MacSettingsDestination]) -> some View {
        ForEach(destinations) { destination in
            Label(destination.title, systemImage: destination.symbol).tag(destination)
        }
    }

    @ViewBuilder
    private func destination(_ destination: MacSettingsDestination) -> some View {
        switch destination {
        case .display: MacDisplaySettingsView(isActive: available)
        case .usage: MacUsageAnalyticsView(isActive: available)
        case .shortcuts: MacShortcutToolsView(isActive: available, model: workspace.shortcutTools)
        case .speech: MacSpeechInputSettingsView(model: workspace.speechInput, isActive: available)
        case .tts: MacTTSSettingsView(model: workspace.tts, isActive: available)
        case .extended: MacExtendedFeaturesView(isActive: available)
        case .general: generalSettings
        case .security: MacSecuritySettingsView(isActive: available)
        case .about: MacAboutView(isActive: available)
        }
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker(NSLocalizedString("语言", comment: ""), selection: $configuration.appLanguage) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        Text(language.nativeDisplayName).tag(language.rawValue)
                    }
                }
                NavigationLink(NSLocalizedString("全局代理设置", comment: "")) {
                    MacGlobalProxyView(model: workspace.globalProxy, isActive: available)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("通用", comment: ""))
        .guideSettingsPageContext(id: "mac-general", title: NSLocalizedString("通用", comment: ""),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available,
            settings: [
                .readOnly("proxy_requires_navigation", label: NSLocalizedString("全局代理设置", comment: ""), value: { .bool(true) }),
                .string("language", label: NSLocalizedString("语言", comment: ""), allowedValues: AppLanguagePreference.allCases.map(\.rawValue), get: { configuration.appLanguage }, set: { configuration.appLanguage = $0 })
            ])
    }

}
