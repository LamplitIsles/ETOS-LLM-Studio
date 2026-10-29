// ============================================================================
// PersistenceAuxiliaryGRDBStoreSchema.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责辅助 GRDB 分库的 JSON Blob、配置域与记忆域关系表 schema 迁移。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceAuxiliaryGRDBStore {
    func migrateSchemaIfNeeded() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_json_blobs") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS json_blobs (
                    key TEXT PRIMARY KEY NOT NULL,
                    json_data BLOB NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_json_blobs_updated_at ON json_blobs(updated_at DESC)")
        }

        if supportsConfigRelationalSchema {
            migrator.registerMigration("v3_create_config_domain_tables") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS providers (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        base_url TEXT NOT NULL,
                        chat_endpoint_path TEXT NOT NULL DEFAULT '/chat/completions',
                        api_format TEXT NOT NULL,
                        proxy_is_enabled INTEGER,
                        proxy_type TEXT,
                        proxy_host TEXT,
                        proxy_port INTEGER,
                        proxy_username TEXT,
                        proxy_password TEXT,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_providers_updated_at ON providers(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_api_keys (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        key_index INTEGER NOT NULL,
                        api_key TEXT NOT NULL,
                        PRIMARY KEY(provider_id, key_index)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_api_keys_provider ON provider_api_keys(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_header_overrides (
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        header_key TEXT NOT NULL,
                        header_value TEXT NOT NULL,
                        PRIMARY KEY(provider_id, header_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_headers_provider ON provider_header_overrides(provider_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_models (
                        id TEXT PRIMARY KEY NOT NULL,
                        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
                        model_name TEXT NOT NULL,
                        display_name TEXT NOT NULL,
                        picker_group_name TEXT,
                        api_format_override TEXT,
                        is_activated INTEGER NOT NULL,
                        kind TEXT,
                        input_modalities_json TEXT,
                        output_modalities_json TEXT,
                        request_body_override_mode TEXT NOT NULL,
                        raw_request_body_json TEXT,
                        request_body_controls_json TEXT,
                        pricing_json TEXT,
                        sort_index INTEGER NOT NULL,
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_models_provider_sort ON provider_models(provider_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_capabilities (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        capability TEXT NOT NULL,
                        sort_index INTEGER NOT NULL,
                        PRIMARY KEY(model_id, capability)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_capabilities_model ON provider_model_capabilities(model_id, sort_index ASC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS provider_model_override_parameters (
                        model_id TEXT NOT NULL REFERENCES provider_models(id) ON DELETE CASCADE,
                        param_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(model_id, param_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_provider_model_override_model ON provider_model_override_parameters(model_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tools (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        external_id TEXT,
                        source TEXT,
                        run_mode_hint TEXT NOT NULL,
                        is_enabled INTEGER NOT NULL,
                        user_description TEXT,
                        generated_description TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        last_imported_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tools_updated_at ON shortcut_tools(updated_at DESC)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS shortcut_tool_metadata (
                        tool_id TEXT NOT NULL REFERENCES shortcut_tools(id) ON DELETE CASCADE,
                        meta_key TEXT NOT NULL,
                        value_type TEXT NOT NULL,
                        string_value TEXT,
                        number_value REAL,
                        bool_value INTEGER,
                        json_value_text TEXT,
                        PRIMARY KEY(tool_id, meta_key)
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_shortcut_tool_metadata_tool ON shortcut_tool_metadata(tool_id)")

                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS feedback_tickets (
                        issue_number INTEGER PRIMARY KEY NOT NULL,
                        ticket_token TEXT NOT NULL,
                        category TEXT NOT NULL,
                        title TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        last_known_status TEXT NOT NULL,
                        last_checked_at REAL,
                        last_known_updated_at REAL,
                        public_url TEXT,
                        moderation_blocked INTEGER,
                        moderation_message TEXT,
                        archive_id TEXT,
                        submitted_title TEXT,
                        submitted_detail TEXT,
                        submitted_reproduction_steps TEXT,
                        submitted_expected_behavior TEXT,
                        submitted_actual_behavior TEXT,
                        submitted_extra_context TEXT,
                        last_known_comment_count INTEGER,
                        last_known_developer_comment_id TEXT,
                        last_known_developer_comment_at REAL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_checked ON feedback_tickets(last_checked_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_feedback_tickets_created ON feedback_tickets(created_at DESC)")
            }

            migrator.registerMigration("v7_add_provider_model_capability_shape") { db in
                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                if !(try tableHasColumn("provider_models", columnName: "kind")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN kind TEXT")
                }
                if !(try tableHasColumn("provider_models", columnName: "input_modalities_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN input_modalities_json TEXT")
                }
                if !(try tableHasColumn("provider_models", columnName: "output_modalities_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN output_modalities_json TEXT")
                }
            }

            migrator.registerMigration("v8_add_provider_model_request_body_controls") { db in
                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                if !(try tableHasColumn("provider_models", columnName: "request_body_controls_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN request_body_controls_json TEXT")
                }
            }

            migrator.registerMigration("v9_create_app_config_table") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS app_config (
                        key TEXT PRIMARY KEY NOT NULL,
                        value_text TEXT,
                        value_real REAL,
                        value_integer INTEGER,
                        type_hint TEXT NOT NULL DEFAULT 'text',
                        updated_at REAL NOT NULL
                    )
                """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_app_config_updated_at ON app_config(updated_at DESC)")
            }

            migrator.registerMigration("v10_add_provider_model_pricing") { db in
                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                if !(try tableHasColumn("provider_models", columnName: "pricing_json")) {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN pricing_json TEXT")
                }
            }

            migrator.registerMigration("v13_add_provider_chat_endpoint_path") { db in
                func tableExists(_ name: String) throws -> Bool {
                    (try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                        arguments: [name]
                    ) ?? 0) > 0
                }

                func tableHasColumn(_ tableName: String, columnName: String) throws -> Bool {
                    let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
                    return columns.contains { row in
                        let name: String = row["name"]
                        return name == columnName
                    }
                }

                guard try tableExists("providers") else { return }
                if !(try tableHasColumn("providers", columnName: "chat_endpoint_path")) {
                    try db.execute(sql: "ALTER TABLE providers ADD COLUMN chat_endpoint_path TEXT NOT NULL DEFAULT '/chat/completions'")
                }
            }

            migrator.registerMigration("v14_add_provider_model_picker_group") { db in
                let tableExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'provider_models'"
                ) ?? 0) > 0
                guard tableExists else { return }

                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(provider_models)")
                let hasPickerGroupName = columns.contains { row in
                    let name: String = row["name"]
                    return name == "picker_group_name"
                }
                if !hasPickerGroupName {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN picker_group_name TEXT")
                }
            }

            migrator.registerMigration("v15_remove_speech_to_text_model_marker") { db in
                let providerModelsExist = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'provider_models'"
                ) ?? 0) > 0
                if providerModelsExist {
                    try db.execute(
                        sql: "UPDATE provider_models SET kind = 'chat' WHERE kind = 'speechToText'"
                    )
                }

                let capabilitiesExist = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'provider_model_capabilities'"
                ) ?? 0) > 0
                if capabilitiesExist {
                    try db.execute(
                        sql: "DELETE FROM provider_model_capabilities WHERE capability = 'speechToText'"
                    )
                }
            }

            migrator.registerMigration("v16_add_provider_model_api_format_override") { db in
                let providerModelsExist = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'provider_models'"
                ) ?? 0) > 0
                guard providerModelsExist else { return }

                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(provider_models)")
                let hasAPIFormatOverride = columns.contains { row in
                    let name: String = row["name"]
                    return name == "api_format_override"
                }
                if !hasAPIFormatOverride {
                    try db.execute(sql: "ALTER TABLE provider_models ADD COLUMN api_format_override TEXT")
                }
            }

            migrator.registerMigration("v17_create_official_data_action_state") { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS official_data_action_state (
                        action_id TEXT PRIMARY KEY NOT NULL,
                        revision INTEGER NOT NULL,
                        payload_sha256 TEXT NOT NULL,
                        provider_id TEXT NOT NULL,
                        official_snapshot_json TEXT NOT NULL,
                        applied_at REAL NOT NULL
                    )
                """)
                try db.execute(
                    sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_official_data_action_provider ON official_data_action_state(provider_id)"
                )
            }

            migrator.registerMigration("v18_create_local_linux_configuration") { db in
                try Self.createLocalLinuxConfigurationTables(db)
            }

            migrator.registerMigration("v20_add_local_linux_command_rule_suffix") { db in
                try Self.migrateLocalLinuxCommandRuleSuffix(db)
            }

            migrator.registerMigration("v21_add_feedback_referenced_commit_tracking") { db in
                try db.alter(table: "feedback_tickets") { table in
                    table.add(column: "last_known_referenced_commit_ids", .text)
                }
            }
        }

        if supportsConfigRelationalSchema {
            migrator.registerMigration("v23_add_provider_multi_key_configuration") { db in
                try db.execute(sql: "ALTER TABLE providers ADD COLUMN multi_key_enabled BOOLEAN NOT NULL DEFAULT 0")
                try db.execute(sql: "ALTER TABLE providers ADD COLUMN maximum_key_retries INTEGER NOT NULL DEFAULT 3")
                try db.execute(sql: "ALTER TABLE provider_api_keys ADD COLUMN note TEXT NOT NULL DEFAULT ''")
                // 已有多凭据配置继续使用全部密钥，升级不能悄悄禁用其他凭据。
                try db.execute(sql: """
                    UPDATE providers SET multi_key_enabled = 1
                    WHERE (SELECT COUNT(*) FROM provider_api_keys WHERE provider_id = providers.id) > 1
                    """)
            }
        }

        try migrator.migrate(self.dbPool)
        self.logger.info("辅助存储已启用，数据库路径: \(self.databaseURL.path)")
    }

}
