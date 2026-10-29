// ============================================================================
// SyncConflictStrategyTests.swift
// ============================================================================
// SyncConflictStrategyTests 测试文件
// - 覆盖会话增量合并与 Provider 深度合并策略
// - 防止同步引擎退回到“轻微更新也直接分叉”的旧行为
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

@Suite("同步冲突策略测试", .serialized)
struct SyncConflictStrategyTests {

    @Test("提供商新增嵌套键值时会深度合并")
    func testProvidersDeepMergeWhenIncomingAddsNestedValues() async throws {
        let previousPersistenceOverride = enableRelationalPersistence()
        defer { restorePersistenceOverride(previousPersistenceOverride) }

        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "同步提供商",
            baseURL: "https://provider.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "gpt-sync",
                    isActivated: false,
                    overrideParameters: [
                        "response": .dictionary([
                            "format": .string("json")
                        ])
                    ]
                )
            ],
            headerOverrides: [
                "Authorization": "Bearer {{apiKey}}"
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.apiKeys = ["incoming-key"]
        incomingProvider.headerOverrides["X-Trace-Id"] = "sync"
        incomingProvider.models[0].isActivated = true
        incomingProvider.models[0].overrideParameters["response"] = .dictionary([
            "format": .string("json"),
            "schema": .dictionary([
                "name": .string("sync-schema")
            ])
        ])

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter { $0.baseURL == localProvider.baseURL }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        let mergedProvider = try #require(mergedProviders.first)
        let mergedModel = try #require(mergedProvider.models.first)
        #expect(mergedProvider.apiKeys == ["local-key", "incoming-key"])
        #expect(mergedProvider.headerOverrides["Authorization"] == "Bearer {{apiKey}}")
        #expect(mergedProvider.headerOverrides["X-Trace-Id"] == "sync")
        #expect(mergedModel.isActivated == true)

        if case let .dictionary(responseDict)? = mergedModel.overrideParameters["response"] {
            #expect(responseDict["format"] == .string("json"))
            #expect(responseDict["schema"] == .dictionary(["name": .string("sync-schema")]))
        } else {
            Issue.record("嵌套 overrideParameters 没有按预期合并。")
        }
    }

    @Test("同步导入会使用对端模型能力形状覆盖本地")
    func testProviderSyncUsesIncomingModelCapabilityShape() async {
        let previousPersistenceOverride = enableRelationalPersistence()
        defer { restorePersistenceOverride(previousPersistenceOverride) }

        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "能力同步提供商",
            baseURL: "https://capability-sync.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "gpt-sync",
                    isActivated: true,
                    inputModalities: [.text, .image],
                    outputModalities: [.text, .image],
                    capabilities: [.toolCalling, .reasoning]
                )
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.models[0].inputModalities = [.text]
        incomingProvider.models[0].outputModalities = [.text]
        incomingProvider.models[0].capabilities = [.toolCalling]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedModel = ConfigLoader.loadProviders()
            .first { $0.id == localProvider.id }?
            .models
            .first { $0.modelName == "gpt-sync" }

        #expect(summary.importedProviders == 1)
        #expect(mergedModel?.inputModalities == [.text])
        #expect(mergedModel?.outputModalities == [.text])
        #expect(mergedModel?.capabilities == [.toolCalling])
        #expect(mergedModel?.supportsImageGeneration == false)
        #expect(mergedModel?.supportsReasoning == false)
    }

    @Test("提供商同键不同值时会优先保留本地且不生成重复项")
    func testProvidersPreferLocalWhenSameHeaderKeyHasDifferentValue() async throws {
        let previousPersistenceOverride = enableRelationalPersistence()
        defer { restorePersistenceOverride(previousPersistenceOverride) }

        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "冲突提供商",
            baseURL: "https://conflict.example.com",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "conflict-model")],
            headerOverrides: [
                "X-Mode": "local"
            ]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.headerOverrides["X-Mode"] = "remote"
        incomingProvider.apiKeys = ["remote-key"]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter { $0.baseURL == localProvider.baseURL }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        let mergedProvider = try #require(mergedProviders.first)
        #expect(mergedProvider.headerOverrides["X-Mode"] == "local")
        #expect(mergedProvider.apiKeys == ["local-key", "remote-key"])
    }

    @Test("提供商 API 格式别名冲突时会归一化并合并")
    func testProvidersNormalizeAliasFormatWithoutDuplication() async throws {
        let previousPersistenceOverride = enableRelationalPersistence()
        defer { restorePersistenceOverride(previousPersistenceOverride) }

        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let localProvider = Provider(
            id: UUID(),
            name: "别名提供商",
            baseURL: "https://api.minimaxi.com/v1",
            apiKeys: ["local-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "abab6.5-chat")],
            headerOverrides: [:]
        )
        ConfigLoader.saveProvider(localProvider)

        let chatService = ChatService()
        var incomingProvider = localProvider
        incomingProvider.apiFormat = "minimax"
        incomingProvider.apiKeys = ["remote-key"]

        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [incomingProvider]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter {
            $0.baseURL == localProvider.baseURL && $0.name == localProvider.name
        }

        #expect(summary.importedProviders == 1)
        #expect(mergedProviders.count == 1)
        let mergedProvider = try #require(mergedProviders.first)
        #expect(mergedProvider.apiFormat == "openai-compatible")
        #expect(mergedProvider.apiKeys == ["local-key", "remote-key"])
    }

    @Test("同步前已有同名同地址重复项时会自动压缩为一份")
    func testProvidersCompactedBeforeApplyingIncomingPackage() async throws {
        let previousPersistenceOverride = enableRelationalPersistence()
        defer { restorePersistenceOverride(previousPersistenceOverride) }

        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
        }

        resetProviders(to: [])
        let providerA = Provider(
            id: UUID(),
            name: "重复提供商",
            baseURL: "https://api.siliconflow.cn/v1",
            apiKeys: ["a-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "deepseek-chat")],
            headerOverrides: [:]
        )
        var providerB = providerA
        providerB.id = UUID()
        providerB.apiFormat = "openai"
        providerB.apiKeys = ["b-key"]
        providerB.models = [Model(modelName: "deepseek-chat"), Model(modelName: "qwen-plus")]

        ConfigLoader.saveProvider(providerA)
        ConfigLoader.saveProvider(providerB)

        let chatService = ChatService()
        let summary = await SyncEngine.apply(
            package: SyncPackage(options: [.providers], providers: [providerA]),
            chatService: chatService
        )
        let mergedProviders = ConfigLoader.loadProviders().filter {
            $0.baseURL == providerA.baseURL && $0.name == providerA.name
        }

        #expect(summary.importedProviders == 0)
        #expect(mergedProviders.count == 1)
        let mergedProvider = try #require(mergedProviders.first)
        #expect(mergedProvider.apiKeys == ["a-key", "b-key"])
        #expect(mergedProvider.models.count == 2)
    }

    @MainActor
    @Test("AppStorage 导出会过滤内部同步状态键")
    func testAppStorageExportFiltersInternalSyncKeys() {
        let suite = "com.ETOS.tests.sync.appstorage.export.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = backupAppConfigValues([.appLanguage])
        defer { AppConfigStore.shared.apply(snapshot: backup) }

        AppConfigStore.shared.appLanguage = "zh-Hans"
        defaults.set("device-a", forKey: "cloudSync.deviceIdentifier")
        defaults.set(Data([0x01]), forKey: "sync.delta.version-tracker.watch.connectivity")
        defaults.set(Data([0x02]), forKey: "sync.delta.checkpoint.cloud.sync")

        let package = SyncEngine.buildPackage(options: [.appStorage], userDefaults: defaults)
        let snapshot = decodeAppStorageSnapshot(package.appStorageSnapshot)

        #expect(snapshot[AppConfigKey.appLanguage.rawValue] as? String == "zh-Hans")
        #expect(snapshot["cloudSync.deviceIdentifier"] == nil)
        #expect(snapshot["sync.delta.version-tracker.watch.connectivity"] == nil)
        #expect(snapshot["sync.delta.checkpoint.cloud.sync"] == nil)
    }

    @MainActor
    @Test("AppStorage 导入会忽略内部同步状态键")
    func testAppStorageImportSkipsInternalSyncKeys() async {
        let suite = "com.ETOS.tests.sync.appstorage.apply.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = backupAppConfigValues([.appLanguage])
        defer { AppConfigStore.shared.apply(snapshot: backup) }

        AppConfigStore.shared.appLanguage = "system"
        defaults.set("local-device", forKey: "cloudSync.deviceIdentifier")
        defaults.set(Data([0xAA]), forKey: "sync.delta.checkpoint.cloud.sync")

        let incoming: [String: Any] = [
            AppConfigKey.appLanguage.rawValue: "zh-Hans",
            "cloudSync.deviceIdentifier": "remote-device",
            "sync.delta.checkpoint.cloud.sync": Data([0xBB])
        ]
        let snapshotData = try? PropertyListSerialization.data(
            fromPropertyList: incoming,
            format: .binary,
            options: 0
        )
        let package = SyncPackage(
            options: [.appStorage],
            appStorageSnapshot: snapshotData
        )

        let summary = await SyncEngine.apply(package: package, userDefaults: defaults)

        #expect(AppConfigStore.shared.appLanguage == "zh-Hans")
        #expect(defaults.string(forKey: "cloudSync.deviceIdentifier") == "local-device")
        #expect(defaults.data(forKey: "sync.delta.checkpoint.cloud.sync") == Data([0xAA]))
        #expect(summary.importedAppStorageValues == 1)
        #expect(summary.skippedAppStorageValues == 2)
    }

    @MainActor
    private func backupAppConfigValues(_ keys: [AppConfigKey]) -> [String: Any] {
        let snapshot = AppConfigStore.shared.snapshot()
        return keys.reduce(into: [String: Any]()) { result, key in
            result[key.rawValue] = snapshot[key.rawValue]
        }
    }

    private func resetProviders(to providers: [Provider]) {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        for provider in providers {
            ConfigLoader.saveProvider(provider)
        }
    }

    private func enableRelationalPersistence() -> Bool? {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        return previousOverride
    }

    private func restorePersistenceOverride(_ previousOverride: Bool?) {
        Persistence.grdbEnabledOverrideForTests = previousOverride
        Persistence.resetGRDBStoreForTests()
    }

    private func decodeAppStorageSnapshot(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }
}
