// ============================================================================
// ChatServiceModelConfiguration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的模型列表、模型排序、Provider 重载与当前模型选择。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public var configuredRunnableModels: [RunnableModel] {
        let remoteModels = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0) }
        }
        return orderedRunnableModels(from: remoteModels)
    }

    public var activatedRunnableModels: [RunnableModel] {
        configuredRunnableModels.filter { $0.model.isActivated }
    }

    public var activatedConversationModels: [RunnableModel] {
        activatedRunnableModels.filter { $0.model.isConversationModel }
    }

    public var activatedChatModels: [RunnableModel] {
        activatedConversationModels.filter { $0.model.isChatModel }
    }

    public var activatedSpeechModels: [RunnableModel] {
        // 专用模型设置决定转写用途，不要求模型携带额外能力标记。
#if canImport(Speech) && canImport(AVFoundation)
        // 系统键盘听写不代表平台开放 Speech 框架，模型目录必须与实际转写实现一致。
        var candidates = configuredRunnableModels
        if !candidates.contains(where: { $0.id == Self.systemSpeechRecognizerRunnableModel.id }) {
            candidates.insert(Self.systemSpeechRecognizerRunnableModel, at: 0)
        }
        return candidates
#else
        return configuredRunnableModels
#endif
    }

    public var activatedOCRModels: [RunnableModel] {
        activatedChatModels.filter { $0.model.supportsVisionInput }
    }

    func orderedRunnableModels(from models: [RunnableModel]) -> [RunnableModel] {
        guard !models.isEmpty else { return [] }
        let currentIDs = models.map(\.id)
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .modelOrderRunnableModels,
            legacyUserDefaultsKey: Self.modelOrderStorageKey,
            defaultValue: []
        ) ?? []
        let providerIDByModelID = Dictionary(uniqueKeysWithValues: models.map {
            ($0.id, $0.provider.id.uuidString)
        })
        let orderedIDs = ModelOrderIndex.hierarchicalOrder(
            storedModelIDs: storedIDs,
            currentModelIDs: currentIDs,
            providerIDByModelID: providerIDByModelID,
            orderedProviderIDs: providers.map { $0.id.uuidString }
        )
        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        return orderedIDs.compactMap { modelByID[$0] }
    }

    func reconcileStoredModelOrder() {
        let currentIDs = providers.flatMap { provider in
            provider.models.map { RunnableModel(provider: provider, model: $0).id }
        }
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .modelOrderRunnableModels,
            legacyUserDefaultsKey: Self.modelOrderStorageKey,
            defaultValue: []
        ) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        AppConfigStore.persistStringArray(mergedIDs, for: .modelOrderRunnableModels)
    }

    func reconcileStoredProviderOrder() {
        let currentIDs = providers.map { $0.id.uuidString }
        let storedIDs = AppConfigStore.stringArrayValue(
            for: .providerOrderIDs,
            defaultValue: []
        ) ?? []
        let mergedIDs = ModelOrderIndex.merge(storedIDs: storedIDs, currentIDs: currentIDs)
        guard mergedIDs != storedIDs else { return }
        AppConfigStore.persistStringArray(mergedIDs, for: .providerOrderIDs)
    }

    func persistSelectedRunnableModelID(_ modelID: String?) {
        AppConfigStore.persistSynchronously(
            .text(modelID ?? ""),
            for: .selectedRunnableModelID
        )
    }

    public func reloadProviders() {
        logger.info("正在重新加载提供商配置...")
        let currentSelectedID = selectedModelSubject.value?.id

        self.providers = ConfigLoader.loadProviders()
        self.reconcileStoredProviderOrder()
        self.reconcileStoredModelOrder()

        let allRunnable = activatedConversationModels
        var newSelectedModel: RunnableModel?
        if let currentID = currentSelectedID {
            newSelectedModel = allRunnable.first { $0.id == currentID }
        }
        if newSelectedModel == nil {
            newSelectedModel = allRunnable.first
        }

        selectedModelSubject.send(newSelectedModel)
        persistSelectedRunnableModelID(newSelectedModel?.id)
        providersSubject.send(self.providers)

        logger.info("提供商配置已刷新，并已更新当前选中模型。")
    }

    public func deleteProvider(_ provider: Provider) {
        ConfigLoader.deleteProvider(provider)
        reloadProviders()
    }

    public func setSelectedModel(_ model: RunnableModel?) {
        guard model?.model.isConversationModel ?? true else { return }
        guard selectedModelSubject.value?.id != model?.id else { return }
        selectedModelSubject.send(model)
        persistSelectedRunnableModelID(model?.id)
        logger.info("已将模型切换为: \(model?.model.displayName ?? "无")")
    }


}
