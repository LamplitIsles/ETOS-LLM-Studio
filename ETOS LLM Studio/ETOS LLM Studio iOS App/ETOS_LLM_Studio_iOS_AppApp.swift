// ============================================================================
// ETOS_LLM_Studio_iOS_AppApp.swift
// ============================================================================
// ETOS LLM Studio iOS App 应用入口文件
//
// 定义内容:
// - 定义 App 的主体 (@main)
// - 设置应用的根视图为 ContentView
// ============================================================================

import SwiftUI
import Combine
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

@main
struct ETOS_LLM_Studio_iOS_AppApp: App {
    @StateObject private var launchStateMachine = AppLaunchStateMachine()
    @StateObject private var updateTimelineManager = UpdateTimelineManager.shared
    @StateObject private var feedbackService = FeedbackService.shared
    @StateObject private var appConfig = AppConfigStore.shared
    @StateObject private var appLockWindowPresenter = AppLockWindowPresenter()
    @State private var hasTriggeredFeedbackRefreshOnLaunch = false
    @State private var unsupportedIncomingFile = false

    init() {
        _ = ChatBackgroundStartupCache.shared
        AppLanguageRuntime.applyConfiguredLanguage()
        SyncTemporaryFileCleaner.cleanupResidualTemporaryDirectoriesInBackground()
        FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
        let performanceTelemetryEnabled = PerformanceTelemetryCenter.resolveLaunchEnabled(
            requiresManualUnlock: DatabaseEncryptionManager.shared.requiresManualUnlock
        ) {
            AppConfigStore.boolValue(for: .performanceTelemetryEnabled)
        }
        PerformanceTelemetryCenter.shared.prepareLaunchMeasurement(
            enabled: performanceTelemetryEnabled
        )
        Task { @MainActor in
            ChatAppearanceProfileManager.shared.activate()
            await PerformanceTelemetryCenter.shared.configure(
                enabled: performanceTelemetryEnabled
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(unsupportedIncomingFile: $unsupportedIncomingFile)
                .networkConnectionApprovalHost()
                .environmentObject(appConfig)
                .overlay {
                    if launchStateMachine.phase == .waitingForDatabaseUnlock {
                        DatabaseUnlockOverlayView {
                            handleDatabaseUnlocked()
                        }
                        .zIndex(2_000)
                    }
                }
                .onOpenURL { url in
                    Task { @MainActor in
                        if NewAPIProviderImportURLHandler.canHandle(url) {
                            NotificationCenter.default.post(name: .newAPIProviderImportDidFail, object: NSLocalizedString("此功能暂不可用。", comment: ""))
                            return
                        }
                        if await SystemEntryURLRouter.handle(url) {
                            return
                        }
                        let handledByShortcutRouter = await ShortcutURLRouter.shared.handleIncomingURL(url)
                        if !handledByShortcutRouter && url.isFileURL {
                            unsupportedIncomingFile = true
                        }
                    }
                }
                .onAppear {
                    PerformanceTelemetryCenter.shared.markFirstInterfaceReady()
                    appLockWindowPresenter.install()
                    updateTimelineManager.activateOnLaunchIfNeeded()
                    triggerFeedbackRefreshOnLaunchIfNeeded()
                }
                .onChange(of: appConfig.performanceTelemetryEnabled) { _, enabled in
                    Task {
                        await PerformanceTelemetryCenter.shared.configure(enabled: enabled)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: AppConfigStore.persistentStoreDidLoadNotification)) { _ in
                    guard !DatabaseEncryptionManager.shared.requiresManualUnlock else { return }
                    Task {
                        await PerformanceTelemetryCenter.shared.configure(
                            enabled: appConfig.performanceTelemetryEnabled
                        )
                    }
                }
                .task {
                    launchStateMachine.startIfNeeded()
                }
        }
    }

    @MainActor
    private func handleDatabaseUnlocked() {
        guard launchStateMachine.phase == .waitingForDatabaseUnlock else { return }
        appConfig.reloadFromPersistentStore()
        launchStateMachine.continueAfterDatabaseUnlock()
    }

    private func triggerFeedbackRefreshOnLaunchIfNeeded() {
        guard !hasTriggeredFeedbackRefreshOnLaunch else { return }
        hasTriggeredFeedbackRefreshOnLaunch = true
        Task(priority: .utility) {
            await feedbackService.refreshTicketsOnLaunch()
        }
    }
}
