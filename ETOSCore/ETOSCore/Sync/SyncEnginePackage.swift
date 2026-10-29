// ============================================================================
// SyncEnginePackage.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步包的构建与导入入口流程。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - 打包导出

    /// 根据同步选项构建完整同步包
    /// 包含每日脉冲时，异步调用方应先等待 DailyPulseManager.flushPendingPersistence()。
    public static func buildPackage(
        options: SyncOptions,
        userDefaults: UserDefaults = .standard
    ) -> SyncPackage {
        var providers: [Provider] = []
        var backgrounds: [SyncedBackground] = []
        var mcpServers: [MCPServerConfiguration] = []
        var audioFiles: [SyncedAudio] = []
        var imageFiles: [SyncedImage] = []
        var skills: [SyncedSkillBundle] = []
        var shortcutTools: [ShortcutToolDefinition] = []
        var feedbackTickets: [FeedbackTicket] = []
        var dailyPulseRuns: [DailyPulseRun] = []
        var dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent] = []
        var dailyPulsePendingCuration: DailyPulseCurationNote?
        var dailyPulseExternalSignals: [DailyPulseExternalSignal] = []
        var dailyPulseTasks: [DailyPulseTask] = []
        var usageStatsDayBundles: [UsageStatsDayBundle] = []
        var fontFiles: [SyncedFontFile] = []
        var fontRouteConfigurationData: Data?
        var appStorageSnapshot: Data?
        var referencedImageFileNames = Set<String>()
        let roleplayCharacters = RoleplayStore.shared.loadCharacters()
        referencedImageFileNames.formUnion(roleplayCharacters.compactMap(\.avatarFileName))
        referencedImageFileNames.formUnion(roleplayCharacters.flatMap { $0.assets ?? [] }.compactMap(\.localFileName))
        referencedImageFileNames.formUnion(RoleplayStore.shared.loadPersonas().compactMap(\.avatarFileName))

        if options.contains(.providers) {
            providers = ConfigLoader.loadProviders()
        }

        if options.contains(.backgrounds) {
            ConfigLoader.setupBackgroundsDirectory()
            let directory = ConfigLoader.getBackgroundsDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                backgrounds = fileURLs.compactMap { url in
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
                    return SyncedBackground(filename: url.lastPathComponent, data: data)
                }
            }
        }

        if options.contains(.mcpServers) {
            mcpServers = MCPServerStore.loadServers()
        }

        if options.contains(.skills) {
            skills = SkillStore.exportSkillBundles()
        }

        if options.contains(.shortcutTools) {
            shortcutTools = ShortcutToolStore.loadTools()
        }

        if options.contains(.feedbackTickets) {
            feedbackTickets = FeedbackStore.loadTickets()
        }

        if options.contains(.dailyPulse) {
            dailyPulseRuns = Persistence.loadDailyPulseRuns()
            dailyPulseFeedbackHistory = Persistence.loadDailyPulseFeedbackHistory()
            dailyPulsePendingCuration = Persistence.loadDailyPulsePendingCuration()
            dailyPulseExternalSignals = Persistence.loadDailyPulseExternalSignals()
            dailyPulseTasks = Persistence.loadDailyPulseTasks()
        }

        if options.contains(.usageStats) {
            usageStatsDayBundles = Persistence.loadUsageStatsDayBundles()
        }

        if options.contains(.fontFiles) {
            fontFiles = FontLibrary.loadAssets().compactMap { record in
                guard let data = Persistence.loadFont(fileName: record.fileName) else { return nil }
                return SyncedFontFile(
                    assetID: record.id,
                    displayName: record.displayName,
                    postScriptName: record.postScriptName,
                    filename: record.fileName,
                    data: data,
                    isEnabled: record.isEnabled
                )
            }
            fontRouteConfigurationData = FontLibrary.loadRouteConfigurationData()
        }

        if options.contains(.appStorage) {
            let snapshot = collectAppStorageSnapshot(userDefaults: userDefaults)
            appStorageSnapshot = encodeAppStorageSnapshot(snapshot)
        }

        var audioFileNamesToInclude = Set<String>()
        if options.contains(.audioFiles) {
            let directory = Persistence.getAudioDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    audioFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !audioFileNamesToInclude.isEmpty {
            audioFiles = audioFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadAudio(fileName: fileName) else { return nil }
                return SyncedAudio(filename: fileName, data: data)
            }
        }

        var imageFileNamesToInclude = referencedImageFileNames
        if options.contains(.imageFiles) {
            let directory = Persistence.getImageDirectory()
            let fileManager = FileManager.default
            if let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in fileURLs {
                    imageFileNamesToInclude.insert(url.lastPathComponent)
                }
            }
        }
        if !imageFileNamesToInclude.isEmpty {
            imageFiles = imageFileNamesToInclude.compactMap { fileName in
                guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
                return SyncedImage(filename: fileName, data: data)
            }
        }

        return SyncPackage(
            options: options,
            sourcePlatform: currentPlatformName,
            providers: providers,
            backgrounds: backgrounds,
            mcpServers: mcpServers,
            audioFiles: audioFiles,
            imageFiles: imageFiles,
            skills: skills,
            shortcutTools: shortcutTools,
            feedbackTickets: feedbackTickets,
            dailyPulseRuns: dailyPulseRuns,
            dailyPulseFeedbackHistory: dailyPulseFeedbackHistory,
            dailyPulsePendingCuration: dailyPulsePendingCuration,
            dailyPulseExternalSignals: dailyPulseExternalSignals,
            dailyPulseTasks: dailyPulseTasks,
            usageStatsDayBundles: usageStatsDayBundles,
            fontFiles: fontFiles,
            fontRouteConfigurationData: fontRouteConfigurationData,
            appStorageSnapshot: appStorageSnapshot
        )
    }

    // MARK: - 合并导入

    /// 将对端发来的同步包合并到本地数据
    @discardableResult
    public static func apply(
        package: SyncPackage,
        chatService: ChatService = .shared,
        userDefaults: UserDefaults = .standard
    ) async -> SyncMergeSummary {
        var summary = SyncMergeSummary.empty
        if package.options.contains(.providers) {
            let result = mergeProviders(package.providers, chatService: chatService)
            summary.importedProviders = result.imported
            summary.skippedProviders = result.skipped
        }

        if package.options.contains(.backgrounds) {
            let result = mergeBackgrounds(package.backgrounds)
            summary.importedBackgrounds = result.imported
            summary.skippedBackgrounds = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncBackgroundsUpdated, object: nil)
            }
        }

        if package.options.contains(.mcpServers) {
            let result = mergeMCPServers(package.mcpServers)
            summary.importedMCPServers = result.imported
            summary.skippedMCPServers = result.skipped
        }

        if package.options.contains(.skills) {
            let result = mergeSkills(package.skills)
            summary.importedSkills = result.imported
            summary.skippedSkills = result.skipped
        }

        if package.options.contains(.shortcutTools) {
            let result = mergeShortcutTools(package.shortcutTools)
            summary.importedShortcutTools = result.imported
            summary.skippedShortcutTools = result.skipped
        }

        if package.options.contains(.feedbackTickets) {
            let result = mergeFeedbackTickets(package.feedbackTickets)
            summary.importedFeedbackTickets = result.imported
            summary.skippedFeedbackTickets = result.skipped
        }

        if package.options.contains(.dailyPulse) {
            // 与本机反馈和任务快照共用顺序，避免先合并后被尚未落库的旧写入覆盖。
            let merge = await DailyPulsePersistenceQueue.shared.enqueue {
                [runs = package.dailyPulseRuns, history = package.dailyPulseFeedbackHistory,
                 curation = package.dailyPulsePendingCuration, signals = package.dailyPulseExternalSignals,
                 tasks = package.dailyPulseTasks] in
                mergeDailyPulseArtifacts(runs: runs, feedbackHistory: history,
                    pendingCuration: curation, externalSignals: signals, tasks: tasks)
            }
            let result = await merge.value
            summary.importedDailyPulseRuns = result.imported
            summary.skippedDailyPulseRuns = result.skipped
            if result.imported > 0 {
                NotificationCenter.default.post(name: .syncDailyPulseUpdated, object: nil)
            }
        }

        if package.options.contains(.usageStats) {
            let result = Persistence.mergeUsageStatsDayBundles(package.usageStatsDayBundles)
            summary.importedUsageEvents = result.importedEvents
            summary.skippedUsageEvents = result.skippedEvents
            if result.importedEvents > 0 {
                NotificationCenter.default.post(name: .syncUsageStatsUpdated, object: nil)
            }
        }

        if package.options.contains(.audioFiles) {
            let result = mergeAudioFiles(package.audioFiles)
            summary.importedAudioFiles = result.imported
            summary.skippedAudioFiles = result.skipped
        }

        if package.options.contains(.imageFiles) {
            let result = mergeImageFiles(package.imageFiles)
            summary.importedImageFiles = result.imported
            summary.skippedImageFiles = result.skipped
        }

        if package.options.contains(.fontFiles) {
            let fileResult = mergeFontFiles(package.fontFiles)
            summary.importedFontFiles = fileResult.imported
            summary.skippedFontFiles = fileResult.skipped

            let routeResult = mergeFontRouteConfiguration(
                package.fontRouteConfigurationData,
                idMapping: fileResult.idMapping
            )
            summary.importedFontRouteConfigurations = routeResult.imported
            summary.skippedFontRouteConfigurations = routeResult.skipped

            if fileResult.imported > 0 || routeResult.imported > 0 {
                FontLibrary.registerAllFontsIfNeeded()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .syncFontsUpdated, object: nil)
                }
            }
        }

        if package.options.contains(.appStorage) {
            let result = await mergeAppStorage(
                package.appStorageSnapshot,
                userDefaults: userDefaults
            )
            summary.importedAppStorageValues = result.imported
            summary.skippedAppStorageValues = result.skipped
            if result.imported > 0 {
                Task { @MainActor in
                    ChatAppearanceProfileManager.shared.reloadFromStorage()
                }
            }
        }

        return summary
    }
}
