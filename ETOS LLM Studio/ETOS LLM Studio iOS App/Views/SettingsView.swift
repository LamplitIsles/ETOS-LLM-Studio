// ============================================================================
// SettingsView.swift
// ============================================================================
// SettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

enum SettingsNavigationDestination: Hashable, Identifiable {
    case feedbackCenter
    case feedbackIssue(issueNumber: Int)
    case achievementJournal
    case updateTimeline

    var id: String {
        switch self {
        case .feedbackCenter:
            return "feedbackCenter"
        case .feedbackIssue(let issueNumber):
            return "feedbackIssue-\(issueNumber)"
        case .achievementJournal:
            return "achievementJournal"
        case .updateTimeline:
            return "updateTimeline"
        }
    }
}

private enum CoreSettingsNavigationDestination: Hashable {
    case connection
    case speechOutput
    case display
}

struct SettingsCoreGridLayout: Equatable {
    private static let compactCardHeight: CGFloat = 100
    private static let wideCardHeight: CGFloat = 140

    let columnCount: Int
    let preferredCardHeight: CGFloat

    static func resolved(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> SettingsCoreGridLayout {
        let usesWideLayout = horizontalSizeClass == .regular || verticalSizeClass == .compact
        return usesWideLayout
            ? SettingsCoreGridLayout(columnCount: 3, preferredCardHeight: wideCardHeight)
            : SettingsCoreGridLayout(columnCount: 2, preferredCardHeight: compactCardHeight)
    }
}

struct SettingsView: View {
    private static let portraitCoreSettingsColumns = Array(
        repeating: GridItem(.flexible()),
        count: 2
    )
    private static let landscapeCoreSettingsColumns = Array(
        repeating: GridItem(.flexible()),
        count: 3
    )
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var cflModel: CFLConversationModel
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @Binding private var requestedDestination: SettingsNavigationDestination?
    @State private var coreSettingsDestination: CoreSettingsNavigationDestination?
    @State private var settingsResearchTask: Task<Void, Never>?

    init(requestedDestination: Binding<SettingsNavigationDestination?> = .constant(nil)) {
        self._requestedDestination = requestedDestination
    }
    
    var body: some View {
        List {
            Section {
                coreSettingsGrid
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section(NSLocalizedString("拓展能力", comment: "设置拓展能力分组")) {
                NavigationLink {
                    UsageAnalyticsView()
                } label: {
                    SettingsListIconLabel("用量统计", icon: .usageAnalytics)
                }

                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    SettingsListIconLabel("快捷指令工具集成", icon: .shortcuts)
                }

                NavigationLink {
                    SpeechInputSettingsView(
                        enableSpeechInput: $appConfig.enableSpeechInput,
                        audioRecordingFormat: Binding(
                            get: { AudioRecordingFormat(rawValue: appConfig.audioRecordingFormat) ?? .aac },
                            set: { appConfig.audioRecordingFormat = $0.rawValue }
                        )
                    )
                } label: {
                    SettingsListIconLabel("语音输入", icon: .speechInput)
                }

                NavigationLink {
                    ExtendedFeaturesView()
                } label: {
                    SettingsListIconLabel("拓展功能", icon: .extendedFeatures)
                }
            }

            // MARK: - 公告通知 Section
            if announcementManager.shouldShowInSettings {
                Section(NSLocalizedString("系统公告", comment: "系统公告分组")) {
                    ForEach(announcementManager.currentAnnouncements, id: \.uniqueKey) { announcement in
                        NavigationLink {
                            AnnouncementDetailView(
                                announcement: announcement,
                                announcementManager: announcementManager
                            )
                        } label: {
                            HStack {
                                announcementIcon(for: announcement.type)
                                Text(announcement.title)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            Section(NSLocalizedString("关于", comment: "设置关于分组")) {
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsListIconLabel("关于 ETOS LLM Studio", icon: .about)
                }
            }
        }
        .navigationTitle(NSLocalizedString("设置", comment: "设置页标题"))
        .onAppear {
            scheduleSettingsResearchAchievementIfNeeded()
        }
        .onDisappear {
            cancelSettingsResearchAchievementTask()
        }
        .onChange(of: appConfig.enableMarkdown) { _, isEnabled in
            if !isEnabled, appConfig.enableAdvancedRenderer {
                appConfig.enableAdvancedRenderer = false
            }
        }
        .navigationDestination(item: $coreSettingsDestination) { destination in
            switch destination {
            case .connection:
                CFLConnectionSettingsView(model: cflModel)
            case .speechOutput:
                TTSSettingsView()
            case .display:
                DisplaySettingsView(
                    enableMarkdown: $appConfig.enableMarkdown,
                    enableBackground: $background.enableBackground,
                    backgroundBlur: $background.backgroundBlur,
                    backgroundOpacity: $background.backgroundOpacity,
                    enableAutoRotateBackground: $background.enableAutoRotateBackground,
                    currentBackgroundImage: $background.currentBackgroundImage,
                    backgroundContentMode: $background.backgroundContentMode,
                    enableLiquidGlass: $appConfig.enableLiquidGlass,
                    enableChatTopBlurFade: $appConfig.enableChatTopBlurFade,
                    enableAdvancedRenderer: $appConfig.enableAdvancedRenderer,
                    enableAutoReasoningPreview: $appConfig.enableAutoReasoningPreview,
                    enableNoBubbleUI: $appConfig.enableNoBubbleUI,
                    allBackgrounds: background.backgroundImages
                )
            }
        }
        .navigationDestination(item: $requestedDestination) { destination in
            switch destination {
            case .feedbackCenter:
                FeedbackCenterView()
            case .feedbackIssue(let issueNumber):
                FeedbackDetailView(issueNumber: issueNumber)
            case .achievementJournal:
                AchievementJournalView()
            case .updateTimeline:
                UpdateTimelineView()
            }
        }
    }

    /// 使用导航开始前已经确定的尺寸等级，避免在 List 布局过程中切换网格结构。
    private var coreSettingsGrid: some View {
        let layout = SettingsCoreGridLayout.resolved(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        let columns = layout.columnCount == 3
            ? Self.landscapeCoreSettingsColumns
            : Self.portraitCoreSettingsColumns

        return LazyVGrid(columns: columns) {
            coreSettingsButton(
                titleKey: "连接设置",
                icon: .connection,
                destination: .connection,
                preferredHeight: layout.preferredCardHeight
            )
            coreSettingsButton(
                titleKey: "语音朗读（TTS）",
                icon: .speechOutput,
                destination: .speechOutput,
                preferredHeight: layout.preferredCardHeight
            )
            coreSettingsButton(
                titleKey: "背景与视觉",
                icon: .display,
                destination: .display,
                preferredHeight: layout.preferredCardHeight
            )
        }
    }

    private func coreSettingsButton(
        titleKey: String,
        icon: SettingsListIcon,
        destination: CoreSettingsNavigationDestination,
        preferredHeight: CGFloat
    ) -> some View {
        Button {
            coreSettingsDestination = destination
        } label: {
            SettingsCategoryCard(
                titleKey,
                icon: icon,
                preferredHeight: preferredHeight
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助方法

    @ViewBuilder
    private func settingsListIcon(_ icon: SettingsListIcon) -> some View {
        if appConfig.settingsColorfulIconsEnabled {
            SettingsListIconView(icon: icon)
        } else {
            SettingsListPlainIconView(icon: icon)
        }
    }

    /// 根据公告类型返回对应图标
    @ViewBuilder
    private func announcementIcon(for type: AnnouncementType) -> some View {
        switch type {
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .blocking:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
        @unknown default:
            Image(systemName: "bell.fill")
                .foregroundColor(.gray)
        }
    }

    private func scheduleSettingsResearchAchievementIfNeeded() {
        cancelSettingsResearchAchievementTask()
        guard !AchievementCenter.shared.hasUnlocked(id: .settingsResearcher) else { return }

        let delay = UInt64(AchievementTriggerEvaluator.settingsResearchDuration * 1_000_000_000)
        settingsResearchTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            guard AchievementTriggerEvaluator.shouldUnlockSettingsResearcher(
                elapsedTime: AchievementTriggerEvaluator.settingsResearchDuration
            ) else { return }
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .settingsResearcher)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .settingsResearcher)
        }
    }

    private func cancelSettingsResearchAchievementTask() {
        settingsResearchTask?.cancel()
        settingsResearchTask = nil
    }

}

private struct CFLConnectionSettingsView: View {
    @ObservedObject var model: CFLConversationModel
    @ObservedObject private var config = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var originDraft = ""
    @State private var invalidOrigin = false
    @State private var isReady = false

    var body: some View {
        Form {
            Section {
                TextField("https://", text: $originDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if invalidOrigin {
                    Text(NSLocalizedString("请输入不含路径或凭据的 HTTPS 地址。", comment: "CFL invalid origin"))
                        .foregroundStyle(.red)
                }
            } header: {
                Text(NSLocalizedString("服务地址", comment: "CFL origin"))
            } footer: {
                Text(NSLocalizedString("请使用仅限可信网络访问的服务地址。", comment: "CFL trusted network"))
            }
            .disabled(!isReady)
        }
        .navigationTitle(NSLocalizedString("连接设置", comment: "CFL connection settings"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    guard let origin = CFLHTTPSOrigin.normalized(originDraft), !origin.isEmpty else {
                        invalidOrigin = true
                        return
                    }
                    Task { await model.connect(origin: origin) }
                    dismiss()
                }
                .disabled(!isReady || model.busy || model.uncertain != nil)
            }
        }
        .task {
            await config.waitForPersistentStoreLoaded()
            originDraft = config.cflHTTPSOrigin
            isReady = true
        }
    }
}

struct SettingsListIcon {
    let systemName: String
    let backgroundColor: Color
}

extension SettingsListIcon {
    static let connection = SettingsListIcon(systemName: "network", backgroundColor: .blue)
    static let speechOutput = SettingsListIcon(systemName: "speaker.wave.2", backgroundColor: .purple)
    static let chatQuickAction = SettingsListIcon(systemName: "ellipsis.circle", backgroundColor: .indigo)
    static let slashCommands = SettingsListIcon(systemName: "terminal", backgroundColor: .indigo)
    static let providerManagement = SettingsListIcon(systemName: "cube", backgroundColor: .orange)
    static let conversationSettings = SettingsListIcon(systemName: "bubble.left.and.bubble.right", backgroundColor: .indigo)
    static let promptSettings = SettingsListIcon(systemName: "text.quote", backgroundColor: .purple)
    static let outputSettings = SettingsListIcon(systemName: "waveform", backgroundColor: .blue)
    static let dailyPulse = SettingsListIcon(systemName: "sparkles", backgroundColor: .yellow)
    static let usageAnalytics = SettingsListIcon(systemName: "chart.bar", backgroundColor: .cyan)
    static let batch = SettingsListIcon(systemName: "tray.full", backgroundColor: .blue)
    static let memory = SettingsListIcon(systemName: "brain", backgroundColor: .mint)
    static let mcp = SettingsListIcon(systemName: "network", backgroundColor: .blue)
    static let agentSkills = SettingsListIcon(systemName: "star", backgroundColor: .purple)
    static let shortcuts = SettingsListIcon(systemName: "bolt", backgroundColor: .orange)
    static let imageGeneration = SettingsListIcon(systemName: "photo", backgroundColor: .pink)
    static let roleplay = SettingsListIcon(systemName: "theatermasks", backgroundColor: .purple)
    static let speechInput = SettingsListIcon(systemName: "mic", backgroundColor: .red)
    static let extendedFeatures = SettingsListIcon(systemName: "ellipsis", backgroundColor: .indigo)
    static let backgroundGeneration = SettingsListIcon(systemName: "location", backgroundColor: .green)
    static let localLinux = SettingsListIcon(systemName: "terminal", backgroundColor: .green)
    static let browserAgent = SettingsListIcon(systemName: "safari", backgroundColor: .blue)
    static let guide = SettingsListIcon(systemName: "questionmark.bubble", backgroundColor: .blue)
    static let display = SettingsListIcon(systemName: "sun.max", backgroundColor: .purple)
    static let sync = SettingsListIcon(systemName: "arrow.clockwise", backgroundColor: .green)
    static let security = SettingsListIcon(systemName: "lock", backgroundColor: .red)
    static let about = SettingsListIcon(systemName: "info.circle", backgroundColor: .gray)
    static let achievementJournal = SettingsListIcon(systemName: "star", backgroundColor: .yellow)
    static let feedback = SettingsListIcon(systemName: "bubble", backgroundColor: .blue)
    static let storage = SettingsListIcon(systemName: "archivebox", backgroundColor: .teal)
    static let importData = SettingsListIcon(systemName: "arrow.down", backgroundColor: .green)
    static let conversationMemory = SettingsListIcon(systemName: "person", backgroundColor: .mint)
    static let memoryLibrary = SettingsListIcon(systemName: "folder", backgroundColor: .orange)
}

struct SettingsListIconLabel: View {
    let title: String
    let icon: SettingsListIcon
    @ObservedObject private var appConfig = AppConfigStore.shared

    init(_ titleKey: String, icon: SettingsListIcon) {
        self.title = NSLocalizedString(titleKey, comment: "设置列表入口标题")
        self.icon = icon
    }

    var body: some View {
        // 原生 Label 为文字提供分隔线对齐锚点，避免线条延伸到图标下方。
        Label {
            Text(title)
        } icon: {
            if appConfig.settingsColorfulIconsEnabled {
                SettingsListIconView(icon: icon)
            } else {
                SettingsListPlainIconView(icon: icon)
            }
        }
    }
}

private struct SettingsCategoryCard: View {
    let title: String
    let icon: SettingsListIcon
    let preferredHeight: CGFloat
    @ObservedObject private var appConfig = AppConfigStore.shared

    init(_ titleKey: String, icon: SettingsListIcon, preferredHeight: CGFloat) {
        self.title = NSLocalizedString(titleKey, comment: "核心设置分类入口标题")
        self.icon = icon
        self.preferredHeight = preferredHeight
    }

    var body: some View {
        VStack(alignment: .leading) {
            categoryIcon
            Spacer()
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        // 只限制卡片随宽度增长的目标高度，动态字体仍可按内容继续撑开。
        .frame(maxWidth: .infinity, minHeight: preferredHeight, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var categoryIcon: some View {
        if appConfig.settingsColorfulIconsEnabled {
            Image(systemName: icon.systemName)
                .symbolVariant(.fill)
                .font(.title2.weight(.semibold))
                .foregroundStyle(icon.backgroundColor)
                .accessibilityHidden(true)
        } else {
            Image(systemName: icon.systemName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
    }
}

struct SettingsListPlainIconView: View {
    let icon: SettingsListIcon

    var body: some View {
        Image(systemName: icon.systemName)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

struct SettingsListIconView: View {
    let icon: SettingsListIcon

    var body: some View {
        Circle()
            .fill(icon.backgroundColor)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: icon.systemName)
                    .symbolVariant(.fill)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
