// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建聊天根视图，统一承接通知与页面跳转
// ============================================================================

import SwiftUI
import Foundation
import Combine
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sizeCategory) private var sizeCategory
    @Binding var unsupportedIncomingFile: Bool
    @StateObject private var announcementManager = AnnouncementManager.shared
    @StateObject private var surveyManager = SurveyManager.shared
    @StateObject private var deviceMessages = DeviceMessageManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var appLockManager = AppLockManager.shared
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @StateObject private var cflModel = CFLConversationModel()
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var launchRecoveryRequest: Persistence.LaunchRecoveryRequest?
    @State private var launchRecoveryErrorMessage: String?
    @State private var rootBodyFont: Font = .body
    @State private var rootFontPreparationTask: Task<Void, Never>?
    @State private var isNativeSettingsPresented: Bool = false
    @State private var systemEntryInboxPayload: SystemEntryInboxPayload?
    @State private var newAPIProviderImportErrorMessage: String?
    
    var body: some View {
        contentWithNewAPIImportAlerts
            // 启动时检查公告
            .task {
                await handleLaunchTasks()
            }
            .task(id: canPresentDeviceMessage) {
                guard canPresentDeviceMessage else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard canPresentDeviceMessage else { return }
                deviceMessages.presentIfPossible()
            }
            .onAppear {
                refreshRootToolPermissionAutoPresentationBlocker()
            }
            .onDisappear {
                setRootToolPermissionAutoPresentationBlocked(false)
            }
            .onChange(of: rootToolPermissionAutoPresentationBlocked) { _, _ in
                refreshRootToolPermissionAutoPresentationBlocker()
            }
            .onChange(of: announcementManager.shouldShowAlert) { _, isPresented in
                guard !isPresented else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !announcementManager.shouldShowAlert else { return }
                    surveyManager.presentPendingSurveyIfPossible()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    TTSManager.shared.setApplicationIsInBackground(false)
                    appLockManager.handleSceneDidBecomeActive()
                    ChatAppearanceProfileManager.shared.handleAppBecameActive()
                case .background:
                    TTSManager.shared.setApplicationIsInBackground(true)
                    appLockManager.handleSceneDidEnterBackground()
                    Task {
                        await AppConfigStore.shared.flushPendingWrites()
                    }
                default:
                    break
                }
            }
    }

    private var baseContent: some View {
        notificationAwareContent
        .alert(NSLocalizedString("数据库已恢复", comment: ""), isPresented: launchRecoveryNoticePresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
        .alert(NSLocalizedString("检测到数据库损坏", comment: ""), isPresented: launchRecoveryRequestPresented) {
            Button(NSLocalizedString("稍后再说", comment: ""), role: .cancel) {
                Persistence.dismissPendingLaunchRecoveryRequest()
                launchRecoveryRequest = nil
            }
            Button(NSLocalizedString("从启动备份恢复", comment: "")) {
                restoreLaunchBackupFromPrompt()
            }
        } message: {
            Text(launchRecoveryRequest?.message ?? "")
        }
        .alert(NSLocalizedString("启动备份恢复失败", comment: ""), isPresented: launchRecoveryErrorPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                launchRecoveryErrorMessage = nil
            }
        } message: {
            Text(launchRecoveryErrorMessage ?? "")
        }
        .alert(NSLocalizedString("导入失败", comment: ""), isPresented: externalDocumentImportErrorPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                unsupportedIncomingFile = false
            }
        } message: {
            Text(NSLocalizedString("当前聊天暂不支持发送文件或图片。", comment: "Unsupported chat attachment"))
        }
        // MARK: - 公告弹窗
        .sheet(isPresented: $announcementManager.shouldShowAlert) {
            if let announcement = announcementManager.currentAnnouncement {
                AnnouncementAlertView(
                    announcement: announcement,
                    onDismiss: {
                        announcementManager.dismissAlert()
                    }
                )
            }
        }
        .sheet(isPresented: surveyPresentationBinding) {
            if let survey = surveyManager.currentSurvey {
                SurveyResponseSheet(survey: survey, manager: surveyManager)
            }
        }
        .sheet(item: Binding(get: { deviceMessages.currentMessage }, set: { _ in deviceMessages.postpone() })) { message in
            NavigationStack {
                DeviceMessageResponseView(message: message, manager: deviceMessages)
            }
            .appLockOverlayLayer()
        }
        .sheet(item: $systemEntryInboxPayload) { payload in
            SystemEntryInboxPreviewView(payload: payload) {
                systemEntryInboxPayload = nil
            }
        }
    }

    private var notificationAwareContent: some View {
        fontAndLanguageAwareContent
        .onReceive(NotificationCenter.default.publisher(for: .requestSwitchToChatTab)) { _ in
            pushNativeChatIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenFeedback)) { _ in
            openFeedbackFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenAchievementJournal)) { _ in
            openAchievementJournalFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenUpdateTimeline)) { _ in
            openUpdateTimelineFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSystemEntryInboxPreview)) { notification in
            systemEntryInboxPayload = notification.object as? SystemEntryInboxPayload
        }
    }

    private var fontAndLanguageAwareContent: some View {
        appNavigationContent
            .environment(\.font, rootBodyFont)
            .onChange(of: sizeCategory) { _, _ in
                refreshRootBodyFont()
            }
            .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage))
            .onAppear {
                AppLanguageRuntime.apply(rawValue: appConfig.appLanguage)
                refreshRootBodyFont()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .syncFontsUpdated)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                refreshRootBodyFont()
            }
            .onChange(of: appConfig.fontUseCustomFonts) { _, isEnabled in
                _ = isEnabled
                FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
                refreshRootBodyFont()
            }
            .onChange(of: appConfig.fontFallbackScope) { _, _ in
                refreshRootBodyFont()
            }
            .onChange(of: appConfig.fontCustomScale) { _, newValue in
                let normalizedValue = FontLibrary.normalizedFontScale(newValue)
                if normalizedValue != newValue {
                    appConfig.fontCustomScale = normalizedValue
                }
                refreshRootBodyFont()
            }
            .onChange(of: appConfig.appLanguage) { _, newValue in
                AppLanguageRuntime.apply(rawValue: newValue)
            }
    }

    private var appNavigationContent: some View {
        NavigationStack {
            CFLConversationView(model: cflModel, openSettings: { pushNativeSettings(destination: nil) })
                .navigationDestination(isPresented: $isNativeSettingsPresented) {
                    SettingsView(requestedDestination: $settingsDestination)
                }
        }
        .environmentObject(cflModel)
    }

    private var contentWithNewAPIImportAlerts: some View {
        baseContent
            .sheet(item: globalToolPermissionRequestBinding) { request in
                GlobalToolPermissionSheet(request: request) { decision in
                    toolPermissionCenter.resolveRequest(withID: request.id, decision: decision)
                }
                .interactiveDismissDisabled(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAPIProviderImportDidFail)) { notification in
                newAPIProviderImportErrorMessage = notification.object as? String
                    ?? NSLocalizedString("此功能暂不可用。", comment: "")
            }
            .alert(NSLocalizedString("导入失败", comment: "Import failure title"), isPresented: newAPIProviderImportErrorPresented) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                    newAPIProviderImportErrorMessage = nil
                }
            } message: {
                Text(newAPIProviderImportErrorMessage ?? "")
            }
    }

    private var globalToolPermissionRequestBinding: Binding<ToolPermissionRequest?> {
        Binding(
            get: { globalToolPermissionRequest },
            set: { _ in }
        )
    }

    private var globalToolPermissionRequest: ToolPermissionRequest? {
        guard toolPermissionCenter.canAutoPresentRequestDetails else { return nil }
        return toolPermissionCenter.activeRequest
    }

    private var rootToolPermissionAutoPresentationBlocked: Bool {
        isNativeSettingsPresented
            || announcementManager.shouldShowAlert
            || surveyManager.shouldShowSurvey
            || deviceMessages.currentMessage != nil
            || unsupportedIncomingFile
            || launchRecoveryNoticeMessage != nil
            || launchRecoveryRequest != nil
            || launchRecoveryErrorMessage != nil
            || newAPIProviderImportErrorMessage != nil
            || appLockManager.state == .locked
    }

    private func setRootToolPermissionAutoPresentationBlocked(_ blocked: Bool) {
        toolPermissionCenter.setAutoPresentationBlocked(blocked, reason: "ios.root.presentation")
    }

    private var canPresentDeviceMessage: Bool {
        deviceMessages.hasPendingMessage
            && scenePhase == .active
            && !rootToolPermissionAutoPresentationBlocked
            && toolPermissionCenter.activeRequest == nil
            && !toolPermissionCenter.hasAutoPresentationBlockers(excluding: ["ios.root.presentation"])
            && systemEntryInboxPayload == nil
    }

    private func refreshRootToolPermissionAutoPresentationBlocker() {
        setRootToolPermissionAutoPresentationBlocked(rootToolPermissionAutoPresentationBlocked)
    }

    private var surveyPresentationBinding: Binding<Bool> {
        Binding(
            get: { surveyManager.shouldShowSurvey },
            set: { isPresented in
                if !isPresented {
                    surveyManager.dismissCurrentSurvey()
                }
            }
        )
    }

    private var launchRecoveryNoticePresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryNoticeMessage = nil
                }
            }
        )
    }

    private var launchRecoveryRequestPresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryRequest != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryRequest = nil
                }
            }
        )
    }

    private var launchRecoveryErrorPresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryErrorMessage = nil
                }
            }
        )
    }

    private var externalDocumentImportErrorPresented: Binding<Bool> {
        Binding(
            get: { unsupportedIncomingFile },
            set: { isPresented in
                if !isPresented {
                    unsupportedIncomingFile = false
                }
            }
        )
    }

    private var newAPIProviderImportErrorPresented: Binding<Bool> {
        Binding(
            get: { newAPIProviderImportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    newAPIProviderImportErrorMessage = nil
                }
            }
        )
    }

    private func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    private func openAchievementJournalFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openAchievementJournal()
    }

    private func openUpdateTimelineFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openUpdateTimeline()
    }

    private func openFeedback(issueNumber: Int?) {
        let destination: SettingsNavigationDestination
        if let issueNumber,
           FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
            destination = .feedbackIssue(issueNumber: issueNumber)
        } else {
            destination = .feedbackCenter
        }
        pushNativeSettings(destination: destination)
    }

    private func openAchievementJournal() {
        pushNativeSettings(destination: .achievementJournal)
    }

    private func openUpdateTimeline() {
        pushNativeSettings(destination: .updateTimeline)
    }

    private func handleLaunchTasks() async {
        launchRecoveryRequest = Persistence.currentLaunchRecoveryRequest()
        launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
        await announcementManager.checkAnnouncement()
        await surveyManager.checkSurveys(canPresent: !announcementManager.shouldShowAlert)
        await deviceMessages.checkMessages()
        if let pendingRoute = notificationCenter.consumePendingRoute() {
            switch pendingRoute {
            case .dailyPulse:
                break
            case .feedback:
                openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
            case .achievementJournal:
                openAchievementJournal()
            case .updateTimeline:
                openUpdateTimeline()
            }
        }
    }

    private func restoreLaunchBackupFromPrompt() {
        launchRecoveryRequest = nil
        Task {
            do {
                let message = try await Task.detached(priority: .userInitiated) {
                    try Persistence.restorePendingLaunchBackupRequest()
                }.value
                AppConfigStore.shared.reloadFromPersistentStore()
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryNoticeMessage = message
            } catch {
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryErrorMessage = error.localizedDescription
            }
        }
    }

    private func pushNativeSettings(destination: SettingsNavigationDestination?) {
        settingsDestination = nil
        isNativeSettingsPresented = true
        if let destination {
            DispatchQueue.main.async {
                settingsDestination = destination
            }
        }
    }

    private func pushNativeChatIfNeeded() {
        isNativeSettingsPresented = false
    }

    private func refreshRootBodyFont() {
        rootFontPreparationTask?.cancel()
        rootFontPreparationTask = Task { @MainActor in
            let font = await ETFontResolver.shared.font(for: .body, sizeCategory: sizeCategory)
            guard !Task.isCancelled else { return }
            rootBodyFont = font
            rootFontPreparationTask = nil
        }
    }

}
