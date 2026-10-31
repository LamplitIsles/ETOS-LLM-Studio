import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ProviderMultiKeyTests {
    private func provider() -> Provider {
        Provider(name: "多密钥测试", baseURL: "https://example.com/v1", apiKeys: ["key-a", "key-b"],
                 apiFormat: "openai-compatible", apiKeyNotes: ["key-a": "主账户", "key-b": "备用账户"])
    }

    @Test("换 Key 使用独立配置和错误范围，单 Key 不产生无效切换")
    func keyRetryPolicyIsIndependent() {
        var source = provider()
        source.maximumKeyRetries = 2
        #expect(ProviderAPIKeyRetryPolicy.maximumRetries(for: source) == 2)
        source.multiKeyEnabled = false
        #expect(ProviderAPIKeyRetryPolicy.maximumRetries(for: source) == 0)
        source.multiKeyEnabled = true
        source.apiKeys = ["same-key", " same-key "]
        #expect(ProviderAPIKeyRetryPolicy.maximumRetries(for: source) == 0)
        for code in [401, 403, 429, 503] {
            #expect(ProviderAPIKeyRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: code, responseBody: nil)))
        }
        #expect(!ProviderAPIKeyRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: 400, responseBody: nil)))
        #expect(!ProviderAPIKeyRetryPolicy.isRetryable(CancellationError()))
        #expect(!ProviderAPIKeyRetryPolicy.isRetryable(URLError(.cancelled)))
        #expect(!ProviderAPIKeyRetryPolicy.isRetryable(NetworkConnectionSecurityError.denied))
        let keyStatus = ChatRequestRetryStatus(attempt: 1, maximumAttempts: 2, kind: .apiKey)
        let automaticStatus = ChatRequestRetryStatus(attempt: 1, maximumAttempts: 2)
        #expect(keyStatus.kind != automaticStatus.kind)
        #expect(keyStatus.thinkingText != automaticStatus.thinkingText)
    }

    @Test("旧 JSON 自动启用多密钥，新配置往返保留关闭状态、备注和重试次数")
    func codableMigration() throws {
        var source = provider()
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        legacy.removeValue(forKey: "multiKeyEnabled")
        legacy.removeValue(forKey: "apiKeyNotes")
        legacy.removeValue(forKey: "maximumKeyRetries")
        let migrated = try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(migrated.multiKeyEnabled)
        #expect(migrated.maximumKeyRetries == 3)
        source.multiKeyEnabled = false
        source.maximumKeyRetries = 7
        let restored = try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(source))
        #expect(restored == source)
    }

    @Test("关系表迁移识别既有多密钥，备注和停用状态可完整回读")
    func databaseMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceAuxiliaryGRDBStore(
            databaseURL: directory.appendingPathComponent("config-store.sqlite"), loggerCategory: "多密钥测试"
        )
        var source = provider()
        try store.write { db in
            try ConfigLoader.replaceProvidersInRelationalStore(db, providers: [source])
            try db.execute(sql: "ALTER TABLE providers DROP COLUMN multi_key_enabled")
            try db.execute(sql: "ALTER TABLE providers DROP COLUMN maximum_key_retries")
            try db.execute(sql: "ALTER TABLE provider_api_keys DROP COLUMN note")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v23_add_provider_multi_key_configuration'")
        }
        try store.migrateSchemaIfNeeded()
        let migrated = try #require(store.read { try ConfigLoader.loadProvidersFromRelationalStore($0).first })
        #expect(migrated.apiKeys == source.apiKeys)
        #expect(migrated.multiKeyEnabled)
        #expect(migrated.maximumKeyRetries == 3)
        source.multiKeyEnabled = false
        source.maximumKeyRetries = 0
        try store.write { try ConfigLoader.replaceProvidersInRelationalStore($0, providers: [source]) }
        #expect(try store.read { try ConfigLoader.loadProvidersFromRelationalStore($0) } == [source])
    }

    @Test("顺序轮换循环使用全部密钥，关闭模式固定使用第一条")
    func rotationAndDisable() {
        var source = provider()
        let rotation = ProviderAPIKeyRotation()
        #expect((0..<5).compactMap { _ in rotation.next(for: source) } == ["key-a", "key-b", "key-a", "key-b", "key-a"])
        source.multiKeyEnabled = false
        #expect(rotation.next(for: source) == "key-a")
        #expect(rotation.next(for: source) == "key-a")
        #expect(source.apiKeys.count == 2)
        source.multiKeyEnabled = true
        source.apiKeys = ["key-c", "key-d"]
        #expect(rotation.next(for: source) == "key-c")
    }

    @Test("各协议重试更新认证和自定义占位头，但保留请求体")
    func retryAuthentication() throws {
        var source = provider()
        source.headerOverrides = ["X-Custom-Key": "token {api_key}"]
        for format in ["openai-compatible", "openai-responses", "anthropic", "gemini"] {
            let header = format == "anthropic" ? "x-api-key" : (format == "gemini" ? "x-goog-api-key" : "Authorization")
            let prefix = header == "Authorization" ? "Bearer " : ""
            var request = URLRequest(url: URL(string: "https://example.com/request")!)
            request.httpBody = Data("正文".utf8)
            request.setValue(prefix + "key-a", forHTTPHeaderField: header)
            request.setValue("token key-a", forHTTPHeaderField: "X-Custom-Key")
            let rotated = source.rotatingAPIKey(in: request, apiFormat: format)
            #expect(rotated.value(forHTTPHeaderField: header) == prefix + "key-b")
            #expect(rotated.value(forHTTPHeaderField: "X-Custom-Key") == "token key-b")
            #expect(rotated.httpBody == request.httpBody)
            let restored = source.preservingAuthentication(from: rotated, in: request)
            #expect(restored.value(forHTTPHeaderField: header) == prefix + "key-b")
        }
    }

    @Test("逗号粘贴去重并开启多密钥，关闭后保留全部草稿，重试输入严格校验")
    @MainActor
    func draftEditing() {
        var source = provider()
        source.apiKeys = ["key-a"]
        source.multiKeyEnabled = false
        let editor = ProviderAPIKeyEditorModel(provider: source)
        #expect(!editor.hasUnsavedChanges)
        editor.singleKeyText = " key-a, key-b，key-c, key-a "
        #expect(editor.draft.multiKeyEnabled)
        #expect(editor.keyCount == 3)
        #expect(editor.draft.entries.count == 3)
        editor.draft.multiKeyEnabled = false
        editor.apply(to: &source)
        #expect(source.apiKeys == ["key-a", "key-b", "key-c"])
        #expect(source.apiKeyNotes["key-a"] == "主账户")
        editor.draft.multiKeyEnabled = true
        for invalid in ["", "-1", "11", "1.5", "abc"] {
            editor.draft.maximumRetriesText = invalid
            #expect(!editor.isValid)
        }
        editor.draft.maximumRetriesText = "0"
        #expect(editor.isValid)
        editor.apply(to: &source)
        #expect(source.maximumKeyRetries == 0)
    }

    @Test("向导只读取备注和配置状态，明文开关不会暴露现有密钥")
    @MainActor
    func guideSecretIsolation() throws {
        let editor = ProviderAPIKeyEditorModel(provider: provider())
        editor.showsPlaintext = true
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: editor.guideSettings)
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        #expect(!encoded.contains("key-a"))
        #expect(!encoded.contains("key-b"))
        #expect(encoded.contains("主账户"))
        #expect(editor.guideSettings.filter { $0.access == .writeOnly }.count == 3)
        #expect(throws: GuideError.self) {
            try ProviderAPIKeyGuideSupport.validate(["maximum_key_retries": .int(11)])
        }
    }

}
