// ============================================================================
// PersistenceAuxiliaryGRDBStoreEnumMigration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责辅助 GRDB 分库中枚举 CHECK 约束修复迁移。
// ============================================================================

import Foundation
import GRDB

extension PersistenceAuxiliaryGRDBStore {
    func registerEnumCheckConstraintMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v5_enforce_enum_check_constraints") { db in
            func tableExists(_ name: String) throws -> Bool {
                (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [name]
                ) ?? 0) > 0
            }

            if try tableExists("mcp_servers"), try tableExists("mcp_tools") {
                try db.execute(sql: "DROP TABLE IF EXISTS mcp_tools_backup")
                try db.execute(sql: """
                    CREATE TABLE mcp_tools_backup (
                        server_id TEXT NOT NULL,
                        tool_name TEXT NOT NULL,
                        description TEXT,
                        sort_index INTEGER NOT NULL DEFAULT 0,
                        updated_at REAL NOT NULL,
                        input_schema_json TEXT,
                        examples_json TEXT,
                        PRIMARY KEY(server_id, tool_name)
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO mcp_tools_backup (
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    )
                    SELECT
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    FROM mcp_tools
                """)

                try db.execute(sql: "DROP TABLE mcp_tools")
                try db.execute(sql: "DROP TABLE IF EXISTS mcp_servers_new")
                try db.execute(sql: """
                    CREATE TABLE mcp_servers_new (
                        id TEXT PRIMARY KEY NOT NULL,
                        display_name TEXT NOT NULL,
                        notes TEXT,
                        is_selected_for_chat INTEGER NOT NULL DEFAULT 0,
                        status TEXT NOT NULL DEFAULT 'idle' CHECK(status IN ('idle', 'ready')),
                        transport_kind TEXT NOT NULL CHECK(transport_kind IN ('http', 'sse', 'oauth', 'built_in_search', 'built_in_app_tool', 'built_in_personal_data')),
                        endpoint_url TEXT,
                        message_endpoint_url TEXT,
                        sse_endpoint_url TEXT,
                        metadata_cached_at REAL,
                        updated_at REAL NOT NULL,
                        api_key TEXT,
                        additional_headers_json TEXT,
                        disabled_tool_ids_json TEXT,
                        tool_approval_policies_json TEXT,
                        oauth_payload_json TEXT,
                        stream_resumption_token TEXT,
                        info_json TEXT,
                        resources_json TEXT,
                        resource_templates_json TEXT,
                        prompts_json TEXT,
                        roots_json TEXT
                    )
                """)

                try db.execute(sql: """
                    INSERT INTO mcp_servers_new (
                        id, display_name, notes, is_selected_for_chat, status, transport_kind,
                        endpoint_url, message_endpoint_url, sse_endpoint_url, metadata_cached_at, updated_at,
                        api_key, additional_headers_json, disabled_tool_ids_json, tool_approval_policies_json,
                        oauth_payload_json, stream_resumption_token, info_json, resources_json,
                        resource_templates_json, prompts_json, roots_json
                    )
                    SELECT
                        id,
                        display_name,
                        notes,
                        is_selected_for_chat,
                        CASE status
                        WHEN 'idle' THEN 'idle'
                        WHEN 'ready' THEN 'ready'
                        ELSE 'idle'
                        END,
                        CASE
                        WHEN transport_kind IN ('http', 'sse', 'oauth', 'built_in_search', 'built_in_app_tool', 'built_in_personal_data') THEN transport_kind
                        WHEN COALESCE(TRIM(message_endpoint_url), '') != '' AND COALESCE(TRIM(sse_endpoint_url), '') != '' THEN 'sse'
                        WHEN COALESCE(TRIM(oauth_payload_json), '') != '' THEN 'oauth'
                        ELSE 'http'
                        END,
                        endpoint_url,
                        message_endpoint_url,
                        sse_endpoint_url,
                        metadata_cached_at,
                        updated_at,
                        api_key,
                        additional_headers_json,
                        disabled_tool_ids_json,
                        tool_approval_policies_json,
                        oauth_payload_json,
                        stream_resumption_token,
                        info_json,
                        resources_json,
                        resource_templates_json,
                        prompts_json,
                        roots_json
                    FROM mcp_servers
                """)

                try db.execute(sql: "DROP TABLE mcp_servers")
                try db.execute(sql: "ALTER TABLE mcp_servers_new RENAME TO mcp_servers")

                try db.execute(sql: """
                    CREATE TABLE mcp_tools (
                        server_id TEXT NOT NULL REFERENCES mcp_servers(id) ON DELETE CASCADE,
                        tool_name TEXT NOT NULL,
                        description TEXT,
                        sort_index INTEGER NOT NULL DEFAULT 0,
                        updated_at REAL NOT NULL,
                        input_schema_json TEXT,
                        examples_json TEXT,
                        PRIMARY KEY(server_id, tool_name)
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO mcp_tools (
                        server_id, tool_name, description, sort_index, updated_at, input_schema_json, examples_json
                    )
                    SELECT
                        backup.server_id,
                        backup.tool_name,
                        backup.description,
                        backup.sort_index,
                        backup.updated_at,
                        backup.input_schema_json,
                        backup.examples_json
                    FROM mcp_tools_backup AS backup
                    WHERE backup.server_id IN (SELECT id FROM mcp_servers)
                """)
                try db.execute(sql: "DROP TABLE mcp_tools_backup")

                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_updated_at ON mcp_servers(updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_selected ON mcp_servers(is_selected_for_chat, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_status ON mcp_servers(status, updated_at DESC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_servers_display_name ON mcp_servers(display_name COLLATE NOCASE)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_server_sort ON mcp_tools(server_id, sort_index ASC)")
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_mcp_tools_updated_at ON mcp_tools(updated_at DESC)")
            }

        }
    }
}
