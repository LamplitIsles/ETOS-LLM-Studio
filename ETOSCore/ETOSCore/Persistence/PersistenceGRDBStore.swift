// ============================================================================
// PersistenceGRDBStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责基于 GRDB 的会话、消息、请求日志、Daily Pulse 与辅助数据持久化。
// ============================================================================

import Foundation
import GRDB
import os.log

enum DatabaseMaintenanceLaunchDeferral {
    static let delayNanoseconds: UInt64 = {
        #if os(watchOS)
        return 30_000_000_000
        #else
        return 8_000_000_000
        #endif
    }()
}

/// GRDB 持久化存储实现（会话、消息、请求日志、Daily Pulse 等）。
final class PersistenceGRDBStore {
    enum MetaKey {
        static let jsonImportCompleted = "json_import_completed"
        static let jsonCleanupCompleted = "json_cleanup_completed"
        static let legacyJSONImportCompleted = "json_import_completed_v1"
        static let legacyJSONCleanupCompleted = "json_cleanup_completed_v1"

        static let jsonImportCompletedCandidates = [jsonImportCompleted, legacyJSONImportCompleted]
        static let jsonCleanupCompletedCandidates = [jsonCleanupCompleted, legacyJSONCleanupCompleted]
    }

    enum BlobKey {
        static let dailyPulseRuns = "daily_pulse_runs"
        static let dailyPulseFeedbackHistory = "daily_pulse_feedback_history"
        static let dailyPulsePendingCuration = "daily_pulse_pending_curation"
        static let dailyPulseExternalSignals = "daily_pulse_external_signals"
        static let dailyPulseTasks = "daily_pulse_tasks"
        static let dailyPulseGenerationRuntime = "daily_pulse_generation_runtime"
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PersistenceGRDB")
    static let incrementalVacuumTriggerPages = 8_192
    static let incrementalVacuumTriggerRatio = 0.2
    static let incrementalVacuumBatchPages = 4_096
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    let chatsDirectory: URL
    let databaseURL: URL
    let dbPool: DatabasePool
    let messageWriteQueue = DispatchQueue(
        label: "com.etos.persistence.messages.write.queue",
        qos: .userInitiated
    )
    let messageWriteQueueSpecificKey = DispatchSpecificKey<UInt8>()

    init(chatsDirectory: URL, configuration: Configuration? = nil, schedulesMaintenance: Bool = true) throws {
        self.chatsDirectory = chatsDirectory
        self.databaseURL = chatsDirectory.appendingPathComponent("runtime-store.sqlite")

        let configuration = configuration ?? Persistence.makeDatabaseConfiguration(
            qos: .userInitiated,
            mmapSize: 134_217_728
        )
        let databasePath = databaseURL.path
        self.dbPool = try {
            let interval = TelemetrySignpost.begin(.databaseConnectionOpen)
            defer { TelemetrySignpost.end(interval) }
            return try DatabasePool(path: databasePath, configuration: configuration)
        }()
        messageWriteQueue.setSpecific(key: messageWriteQueueSpecificKey, value: 1)

        do {
            let interval = TelemetrySignpost.begin(.databaseSchemaMigration)
            defer { TelemetrySignpost.end(interval) }
            try migrateSchemaIfNeeded()
        } catch { try? dbPool.close(); throw error }
        if schedulesMaintenance { scheduleDatabaseMaintenanceIfNeeded() }
    }

    func flushPendingMessageWrites() {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        messageWriteQueue.sync {}
    }

    func flushPendingMessageWritesAsync() async {
        if DispatchQueue.getSpecific(key: messageWriteQueueSpecificKey) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            messageWriteQueue.async {
                continuation.resume()
            }
        }
    }

    private func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_core_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS request_logs (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id TEXT NOT NULL,
                    session_id TEXT,
                    provider_id TEXT,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    requested_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    is_streaming INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    token_usage_json BLOB
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")

        }

        migrator.registerMigration("v3_usage_analytics_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_request_events (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    request_source TEXT NOT NULL,
                    session_id TEXT,
                    provider_id TEXT,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    requested_at REAL NOT NULL,
                    finished_at REAL NOT NULL,
                    day_key TEXT NOT NULL,
                    is_streaming INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    http_status_code INTEGER,
                    error_kind TEXT,
                    prompt_tokens INTEGER,
                    completion_tokens INTEGER,
                    thinking_tokens INTEGER,
                    cache_write_tokens INTEGER,
                    cache_read_tokens INTEGER,
                    total_tokens INTEGER,
                    origin_device_id TEXT NOT NULL,
                    origin_platform TEXT NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_daily_totals (
                    day_key TEXT PRIMARY KEY NOT NULL,
                    request_count INTEGER NOT NULL,
                    success_count INTEGER NOT NULL,
                    failed_count INTEGER NOT NULL,
                    cancelled_count INTEGER NOT NULL,
                    sent_tokens INTEGER NOT NULL,
                    received_tokens INTEGER NOT NULL,
                    thinking_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS usage_daily_model_totals (
                    day_key TEXT NOT NULL,
                    provider_name TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    request_source TEXT NOT NULL,
                    request_count INTEGER NOT NULL,
                    success_count INTEGER NOT NULL,
                    failed_count INTEGER NOT NULL,
                    cancelled_count INTEGER NOT NULL,
                    sent_tokens INTEGER NOT NULL,
                    received_tokens INTEGER NOT NULL,
                    thinking_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day_key, provider_name, model_id, request_source)
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_day_requested ON usage_request_events(day_key, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_provider_model ON usage_request_events(provider_name, model_id, day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_origin_device ON usage_request_events(origin_device_id, day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_daily_model_totals_day_key ON usage_daily_model_totals(day_key)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_daily_model_totals_model ON usage_daily_model_totals(provider_name, model_id, day_key)")
        }

        migrator.registerMigration("v13_local_agent_runtime") { db in
            try Self.createLocalAgentRuntimeTables(db)
        }

        migrator.registerMigration("v14_browser_agent_governance") { db in
            try Self.migrateLocalAgentBrowserSchema(db)
        }

        migrator.registerMigration("v15_skill_execution_governance") { db in
            try Self.createSkillExecutionGovernanceTables(db)
        }

        migrator.registerMigration("v16_system_entry_receipts") { db in
            try Self.createSystemEntryReceiptTable(db)
        }

        migrator.registerMigration("v18_anthropic_cache_pricing_usage") { db in
            for table in ["usage_request_events", "usage_daily_totals", "usage_daily_model_totals"] {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN cache_write_five_minute_tokens INTEGER")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN cache_write_one_hour_tokens INTEGER")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN uncached_input_tokens INTEGER")
            }
        }

        migrator.registerMigration("v19_session_usage_analytics_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_usage_request_events_session_requested ON usage_request_events(session_id, requested_at, event_id)")
        }

        try migrator.migrate(dbPool)
        try repairCoreSchemaIfNeeded()
    }

    private func repairCoreSchemaIfNeeded() throws {
        try dbPool.write { db in
            try createCoreTablesIfMissing(db)
            try Self.migrateLocalAgentBrowserSchema(db)
            try Self.createSkillExecutionGovernanceTables(db)
            try Self.createSystemEntryReceiptTable(db)
            try requireColumns(db, table: "request_logs", columns: ["id", "request_id", "provider_name", "model_id"])
            try ensureColumn(db, table: "request_logs", column: "session_id", definition: "session_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "provider_id", definition: "provider_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "requested_at", definition: "requested_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "finished_at", definition: "finished_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "is_streaming", definition: "is_streaming INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "status", definition: "status TEXT NOT NULL DEFAULT 'failed'")
            try ensureColumn(db, table: "request_logs", column: "token_usage_json", definition: "token_usage_json BLOB")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")
        }
    }

    static func createSystemEntryReceiptTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS system_entry_receipts (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                session_id TEXT,
                created_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_system_entry_receipts_created_at
            ON system_entry_receipts(created_at DESC)
        """)
    }

    private func createCoreTablesIfMissing(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS request_logs (
                id TEXT PRIMARY KEY NOT NULL,
                request_id TEXT NOT NULL,
                session_id TEXT,
                provider_id TEXT,
                provider_name TEXT NOT NULL,
                model_id TEXT NOT NULL,
                requested_at REAL NOT NULL DEFAULT 0,
                finished_at REAL NOT NULL DEFAULT 0,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'failed',
                token_usage_json BLOB
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS json_blobs (
                key TEXT PRIMARY KEY NOT NULL,
                json_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }

    private func requireColumns(_ db: Database, table: String, columns: [String]) throws {
        let existing = try columnNames(db, table: table)
        for column in columns where !existing.contains(column) {
            throw NSError(domain: "PersistenceGRDBStore.SchemaRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(format: NSLocalizedString("数据库表 %@ 缺少关键字段 %@，需要自动重建。", comment: "Database schema repair missing column error"), table, column)
            ])
        }
    }

    private func ensureColumn(_ db: Database, table: String, column: String, definition: String) throws {
        guard !(try columnNames(db, table: table).contains(column)) else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
        logger.info("已自动补齐数据库字段 \(table).\(column)。")
    }

    private func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { row in
            let name: String? = row["name"]
            return name
        })
    }

    private func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            // 延迟期间不持有 Store，避免已被释放的测试数据库稍后仍触发维护。
            guard let self else { return }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    private func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("主数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("主数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("主数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

}
