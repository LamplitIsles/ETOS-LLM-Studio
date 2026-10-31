import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct SkillLibraryPersistenceTests {
    @Test("损坏的启用列表读取失败且保持原值")
    func malformedSettingsRejectReads() throws {
        let queue = try database()
        try queue.write { try $0.execute(sql: "INSERT INTO app_config (key, value_text) VALUES ('skills.enabledNames', 'broken')") }
        #expect(throws: SkillLibraryError.self) {
            try queue.read { try SkillLibrarySettings.read(in: $0) }
        }
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config") } == "broken")
    }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: """
            CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL,
                                     value_integer INTEGER, type_hint TEXT, updated_at REAL)
            """) }
        return queue
    }
}
