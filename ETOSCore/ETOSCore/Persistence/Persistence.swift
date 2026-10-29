// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 的入口与共享状态定义；具体存储逻辑已拆分到相邻文件。
// ============================================================================

import Foundation
import os.log
import GRDB

public enum Persistence {
    static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")
    static let sessionStoreSchemaVersion = 3
    static let sessionFoldersFileSchemaVersion = 1
    static let sessionTagsFileSchemaVersion = 1
    static let messagesFileSchemaVersion = 2
    static let requestLogSchemaVersion = 1
    static let defaultRequestLogRetentionLimit = 10_000
    static let migrationLogPrefix = "[(迁移)]"
    static let compatibilityReminderPrefix = "[(迁移)][兼容提醒]"
    static let compatibilityReminderLock = NSLock()
    static let requestLogLock = NSLock()
    static let grdbStoreLock = NSLock()
    static let databaseReplacementLock = NSRecursiveLock()
    // 分别由对应的缓存锁保护；关闭连接到文件替换完成之间不能重新打开数据库。
    static var isGRDBStoreReplacementInProgress = false
    static var isAuxiliaryStoreReplacementInProgress = false
    static var cachedGRDBStore: PersistenceGRDBStore?
    static var lastGRDBStoreInitializationFailedAt: Date?
    static let grdbStoreRetryInterval: TimeInterval = 2
    static let auxiliaryStoreLock = NSLock()
    static var cachedAuxiliaryStores: [AuxiliaryStoreKind: PersistenceAuxiliaryGRDBStore] = [:]
    static var lastAuxiliaryStoreInitializationFailedAt: [AuxiliaryStoreKind: Date] = [:]
    static let auxiliaryStoreRetryInterval: TimeInterval = 2
    static let auxiliaryConfigBlobKeys: Set<String> = [
        "providers",
        "providers_v1",
        "shortcut_tools",
        "shortcut_tools_v1",
        "feedback_tickets",
        "feedback_tickets_v1",
        "survey_client_state_v1",
        "mcp_servers_records",
        "mcp_servers_records_v1",
        "roleplay_library_v1",
        "roleplay_variables_v1"
    ]
    static var grdbEnabledOverrideForTests: Bool?
    static var requestLogRetentionLimitOverride: Int?
    static var hasLoggedCompatibilityReminder = false
    public static let launchBackupEnabledKey = "sync.backup.createOnLaunch"
    static let launchRecoveryNoticeKey = "persistence.launchRecoveryNotice"
    static let launchBackupDirectoryName = "StartupBackups"
    static let launchBackupAndRecoveryLock = NSLock()
    static var hasPreparedLaunchDatabases = false
    static var launchPreparationResult = LaunchPreparationResult()
    static var pendingLaunchRecoveryNotice: String?
    static var pendingLaunchRecoveryRequest: LaunchRecoveryRequest?
    static var pendingLaunchRecoveryKinds: [LaunchDatabaseKind] = []
    static var hasCreatedLaunchBackupPoint = false
    static var hasScheduledLaunchBackupPoint = false

    /// 数据写入允许在后台完成，但驱动 SwiftUI 刷新的通知必须始终从主线程发出。
    static func postCloudSyncLocalDataDidChange(
        notificationCenter: NotificationCenter = .default
    ) {
        guard !Thread.isMainThread else {
            notificationCenter.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }
        DispatchQueue.main.async {
            notificationCenter.post(name: .cloudSyncLocalDataDidChange, object: nil)
        }
    }

    static var deferredLaunchBackupDelay: TimeInterval {
        #if os(watchOS)
        120
        #else
        30
        #endif
    }

    struct LaunchPreparationResult {
        var recoverableKinds: [LaunchDatabaseKind] = []
        var restoredKinds: [LaunchDatabaseKind] = []
        var failedKinds: [LaunchDatabaseKind] = []
        var missingBackupKinds: [LaunchDatabaseKind] = []

        var hasPendingRecoveryRequest: Bool {
            !recoverableKinds.isEmpty
        }
    }

    public struct LaunchRecoveryRequest: Identifiable, Equatable, Sendable {
        public let id: String
        public let message: String
        public let databaseNames: [String]

        init(kinds: [LaunchDatabaseKind], message: String) {
            self.id = kinds.map(\.requestIdentifier).joined(separator: ".")
            self.message = message
            self.databaseNames = kinds.map(\.localizedDisplayName)
        }
    }

    enum LaunchDatabaseKind: CaseIterable, Sendable {
        case chat
        case config

        var requestIdentifier: String {
            switch self {
            case .chat:
                return "chat"
            case .config:
                return "config"
            }
        }

        var displayName: String {
            switch self {
            case .chat:
                return "运行时数据库"
            case .config:
                return "配置数据库"
            }
        }

        var localizedDisplayName: String {
            NSLocalizedString(displayName, comment: "Launch recovery database name")
        }
    }

    enum AuxiliaryStoreKind: String {
        case config = "config-store.sqlite"

        var loggerCategory: String {
            switch self {
            case .config:
                return "PersistenceAuxConfig"
            }
        }
    }

    static var documentsDirectory: URL {
        StorageUtility.documentsDirectory
    }

    static let sessionIndexFileName = "index.json"
    static let sessionFoldersFileName = "folders.json"
    static let sessionTagsFileName = "tags.json"
    static let sessionRecordsDirectoryName = "sessions"
    static let requestLogsDirectoryName = "RequestLogs"
    static let requestLogsFileName = "index.json"
    static let dailyPulseDirectoryName = "DailyPulse"
    static let dailyPulseRunsFileName = "runs.json"
    static let dailyPulseFeedbackHistoryFileName = "feedback-history.json"
    static let dailyPulsePendingCurationFileName = "pending-curation.json"
    static let dailyPulseExternalSignalsFileName = "external-signals.json"
    static let dailyPulseTasksFileName = "tasks.json"
    static let dailyPulseGenerationRuntimeFileName = "generation-runtime.json"
    static let legacySessionDirectoryName = "v3"
    static let legacyArchiveDirectoryName = "legacy"

}
