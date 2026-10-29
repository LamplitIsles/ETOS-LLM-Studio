import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("枚举约束迁移测试")
struct EnumConstraintMigrationTests {
    @Test("聊天库 v2 迁移会为 messages 角色字段补齐 CHECK 约束")
    func testChatStoreMessageRoleConstraintMigration() throws {
        let chatsDirectory = try makeTempChatsDirectory()
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        try prepareChatDatabaseBeforeV2(at: databaseURL)

        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let migrated = try queue.read { db -> (String, String?) in
            let role = try String.fetchOne(db, sql: "SELECT role FROM messages LIMIT 1") ?? ""
            let placement = try String.fetchOne(db, sql: "SELECT tool_calls_placement FROM messages LIMIT 1")
            return (role, placement)
        }

        #expect(migrated.0 == "user")
        #expect(migrated.1 == nil)

        let invalidInsertRejected = try queue.write { db -> Bool in
            let sessionID = try String.fetchOne(db, sql: "SELECT id FROM sessions LIMIT 1") ?? UUID().uuidString
            do {
                try db.execute(
                    sql: """
                    INSERT INTO messages (
                        id, session_id, role, requested_at, content, content_versions_json, current_version_index,
                        reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json, audio_file_name,
                        image_file_names_json, file_file_names_json, full_error_content, response_metrics_json, position, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString, sessionID, "broken-role", Date().timeIntervalSince1970, "content", Data("[]".utf8), 0,
                        "", Data("[]".utf8), "afterReasoning", Data("{}".utf8), "", Data("[]".utf8), Data("[]".utf8), "", Data("{}".utf8), 1, Date().timeIntervalSince1970
                    ]
                )
                return false
            } catch {
                return true
            }
        }

        #expect(invalidInsertRejected)
    }

    @Test("聊天库初始化会自动补齐缺失的非关键字段")
    func testChatStoreRepairsMissingOptionalColumnsOnStartup() throws {
        let chatsDirectory = try makeTempChatsDirectory()
        defer { try? FileManager.default.removeItem(at: chatsDirectory) }

        let databaseURL = chatsDirectory.appendingPathComponent("chat-store.sqlite")
        try prepareChatDatabaseWithMissingColumns(at: databaseURL)

        _ = try PersistenceGRDBStore(chatsDirectory: chatsDirectory)

        let queue = try DatabaseQueue(path: databaseURL.path)
        let repairedColumns = try queue.read { db -> [Bool] in
            [
                try tableHasColumn(db, tableName: "sessions", columnName: "worldbook_context_isolation_enabled"),
                try tableHasColumn(db, tableName: "sessions", columnName: "memory_context_isolation_enabled"),
                try tableHasColumn(db, tableName: "sessions", columnName: "tool_context_isolation_enabled"),
                try tableHasColumn(db, tableName: "messages", columnName: "response_metrics_json"),
                try tableHasColumn(db, tableName: "messages", columnName: "file_file_names_json"),
                try tableHasColumn(db, tableName: "messages", columnName: "response_group_id"),
                try tableHasColumn(db, tableName: "messages", columnName: "response_attempt_id"),
                try tableHasColumn(db, tableName: "messages", columnName: "response_attempt_index"),
                try tableHasColumn(db, tableName: "messages", columnName: "selected_response_attempt_id"),
                try tableHasColumn(db, tableName: "session_folders", columnName: "parent_id")
            ]
        }

        #expect(repairedColumns.allSatisfy { $0 })
    }
}

private func makeTempChatsDirectory() throws -> URL {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EnumConstraintChats-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    return rootDirectory
}

private func prepareChatDatabaseBeforeV2(at databaseURL: URL) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(
            sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES (?)",
            arguments: ["v1_create_core_tables"]
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                topic_prompt TEXT,
                enhanced_prompt TEXT,
                folder_id TEXT,
                lorebook_ids_json BLOB NOT NULL,
                worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0,
                is_temporary INTEGER NOT NULL DEFAULT 0,
                sort_index INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                conversation_summary TEXT,
                conversation_summary_updated_at REAL
            )
        """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                requested_at REAL,
                content TEXT NOT NULL,
                content_versions_json BLOB NOT NULL,
                current_version_index INTEGER NOT NULL DEFAULT 0,
                reasoning_content TEXT,
                tool_calls_json BLOB,
                tool_calls_placement TEXT,
                token_usage_json BLOB,
                audio_file_name TEXT,
                image_file_names_json BLOB,
                file_file_names_json BLOB,
                full_error_content TEXT,
                response_metrics_json BLOB,
                position INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
        """)

        let sessionID = UUID().uuidString
        try db.execute(
            sql: """
            INSERT INTO sessions (
                id, name, lorebook_ids_json, worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [sessionID, "legacy", Data("[]".utf8), 0, 0, 0, Date().timeIntervalSince1970]
        )

        try db.execute(
            sql: """
            INSERT INTO messages (
                id, session_id, role, requested_at, content, content_versions_json, current_version_index,
                reasoning_content, tool_calls_json, tool_calls_placement, token_usage_json, audio_file_name,
                image_file_names_json, file_file_names_json, full_error_content, response_metrics_json, position, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                UUID().uuidString, sessionID, "legacy-role", Date().timeIntervalSince1970, "legacy-content", Data("[]".utf8), 0,
                "", Data("[]".utf8), "legacy-placement", Data("{}".utf8), "", Data("[]".utf8), Data("[]".utf8), "", Data("{}".utf8), 0, Date().timeIntervalSince1970
            ]
        )
    }
}

private func prepareChatDatabaseWithMissingColumns(at databaseURL: URL) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        // 夹具没有创建用量表，让 v3 正常执行；不能声明不存在的结构已经迁移完成。
        for migration in ["v1_create_core_tables", "v2_enforce_message_enum_constraints"] {
            try db.execute(
                sql: "INSERT OR IGNORE INTO grdb_migrations(identifier) VALUES (?)",
                arguments: [migration]
            )
        }

        try db.execute(sql: """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                lorebook_ids_json BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE messages (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                content_versions_json BLOB NOT NULL,
                current_version_index INTEGER NOT NULL DEFAULT 0,
                position INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE session_folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE request_logs (
                id TEXT PRIMARY KEY NOT NULL,
                request_id TEXT NOT NULL,
                provider_name TEXT NOT NULL,
                model_id TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE json_blobs (
                key TEXT PRIMARY KEY NOT NULL,
                json_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }
}

private func tableHasColumn(_ db: Database, tableName: String, columnName: String) throws -> Bool {
    let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
    return rows.contains { row in
        let name: String? = row["name"]
        return name == columnName
    }
}
