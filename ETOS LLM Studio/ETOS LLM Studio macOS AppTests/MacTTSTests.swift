import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacTTSTests {
    @Test("语音服务目录保留顺序和选择，但向导不含接口地址、密钥或专有指令")
    func catalogPrivacy() {
        var service = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible)
        service.apiKey = "private-key"; service.baseURL = "https://private.example/v1"
        service.advanced?.instruction = "private-instruction"
        let snapshot = TTSConfigurationSnapshot(settings: .defaultValue, services: [service], selectedServiceID: service.id, revision: [:])
        let prepared = MacTTSPresentation.prepare(snapshot)
        #expect(prepared.selected == service); #expect(prepared.identifiers == [service.id.uuidString])
        #expect(prepared.rows.first?.ready == true)
        let encoded = GuideToolArguments.encodedResult(prepared.guideValue)
        #expect(!encoded.contains("private-key")); #expect(!encoded.contains("private.example")); #expect(!encoded.contains("private-instruction"))
    }

    @Test("服务切换保留尚未保存的全局参数，旧页面保存和删除被拒绝")
    @MainActor
    func draftAndEpoch() async {
        let store = MacTTSStoreStub()
        let model = makeModel(store)
        model.resume(); await model.waitForPendingOperations()
        let oldEpoch = model.epoch
        model.draft.speechRate = 2
        var service = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible); service.apiKey = "key"
        #expect(await model.saveService(service, expectedEpoch: oldEpoch))
        #expect(model.draft.speechRate == 2); #expect(model.presentation?.snapshot.settings.speechRate == 1)
        #expect(!(await model.saveService(service, expectedEpoch: oldEpoch)))
        model.deleteService(service.id, expectedEpoch: oldEpoch)
        await model.waitForPendingOperations()
        #expect(await store.writeCount == 1)
        model.suspend(); await model.waitForPendingOperations()
    }

    @Test("锁定期间等待已开始的保存，迟到结果不能回填；恢复后重读已保存值")
    @MainActor
    func suspendedWrite() async {
        let store = MacTTSStoreStub(blocksSave: true)
        let model = makeModel(store)
        model.resume(); await model.waitForPendingOperations()
        model.draft.speechRate = 2; model.saveSettings()
        await store.waitForSave()
        model.suspend()
        await store.releaseSave(); await model.waitForPendingOperations()
        #expect(model.presentation == nil); #expect(model.draft == .defaultValue); #expect(!model.isSaving)
        model.resume(); await model.waitForPendingOperations()
        #expect(model.presentation?.snapshot.settings.speechRate == 2)
        model.suspend(); await model.waitForPendingOperations()
    }

    @Test("切换协议同步更新草稿和可用字段，后台保存限制用户输入的音频整数范围")
    @MainActor
    func protocolDraft() async {
        var source = TTSServiceConfiguration.defaultConfiguration(for: .openAICompatible); source.apiKey = "old-secret"
        let draft = MacTTSServiceDraft(source)
        draft.changeProvider(.fishAudio)
        draft.service.apiKey = "new-secret"
        draft.advanced.sampleRate = Int.max; draft.advanced.bitrate = Int.max
        let prepared = await draft.preparedService()
        #expect(prepared.providerKind == .fishAudio); #expect(prepared.apiKey == "new-secret")
        #expect(draft.fields.contains(.temperature)); #expect(!draft.fields.contains(.workspace))
        #expect(prepared.advancedSettings.sampleRate == 48_000); #expect(prepared.advancedSettings.bitrate == 256_000)
        draft.cancel()
    }

    @MainActor
    private func makeModel(_ store: MacTTSStoreStub) -> MacTTSModel {
        MacTTSModel(loadSnapshot: { await store.load() }, saveSnapshot: { candidate, _ in await store.save(candidate) }, loadVoices: { [] })
    }
}

private actor MacTTSStoreStub {
    let blocksSave: Bool
    var writeCount = 0
    private var snapshot = TTSConfigurationSnapshot(settings: .defaultValue, services: [], selectedServiceID: nil, revision: [:])
    private var gate: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(blocksSave: Bool = false) { self.blocksSave = blocksSave }
    func load() -> TTSConfigurationSnapshot { snapshot }
    func save(_ candidate: TTSConfigurationSnapshot) async -> TTSConfigurationSnapshot {
        writeCount += 1; waiter?.resume(); waiter = nil
        if blocksSave { await withCheckedContinuation { gate = $0 } }
        snapshot = candidate
        return snapshot
    }
    func waitForSave() async { if writeCount == 0 { await withCheckedContinuation { waiter = $0 } } }
    func releaseSave() { gate?.resume(); gate = nil }
}
