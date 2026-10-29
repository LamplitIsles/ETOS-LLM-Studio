// ============================================================================
// ThirdPartyImportChatBox.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 ChatBox 导出的提供商配置。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    struct ChatBoxProviderReference {
        var provider: Provider
        var modelByChatBoxModelID: [String: Model]
    }

    struct ChatBoxProviderBundle {
        var providers: [Provider]
        var referenceByChatBoxProviderID: [String: ChatBoxProviderReference]
    }

    struct ChatBoxProviderDefinition {
        var name: String
        var apiFormat: String
        var defaultBaseURL: String
        var isSupported: Bool
    }

    static func parseChatBox(fileURL: URL) throws -> ParsedPayload {
        let root = try loadChatBoxRoot(fileURL: fileURL)

        var warnings: [String] = []
        let settings = chatBoxSettings(from: root)
        if settings == nil {
            warnings.append(NSLocalizedString("ChatBox 导出未找到 settings，提供商配置未导入。", comment: "ChatBox import missing settings warning"))
        }

        let sessionEntries = chatBoxSessionEntries(from: root)
        let referencedModels = collectChatBoxReferencedModels(
            settings: settings,
            sessionEntries: sessionEntries
        )
        let providerBundle = parseChatBoxProviders(
            settings,
            referencedModelsByProvider: referencedModels,
            warnings: &warnings
        )
        if providerBundle.providers.isEmpty {
            warnings.append(NSLocalizedString("ChatBox 导出未识别到可导入的提供商配置。", comment: "ChatBox import missing providers warning"))
        }
        if providerBundle.providers.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未识别到 ChatBox 导出中的可导入数据。", comment: "ChatBox import no importable data")
            )
        }

        return ParsedPayload(
            providers: providerBundle.providers,
            warnings: dedupeStrings(warnings)
        )
    }

    static func loadChatBoxRoot(fileURL: URL) throws -> [String: Any] {
        if isDirectory(fileURL),
           let root = try findFirstDictionaryJSON(inDirectory: fileURL, where: looksLikeChatBoxRoot) {
            return root
        }

        if isDirectory(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("ChatBox 导出不是可识别的 JSON 备份。", comment: "ChatBox import unrecognized backup")
            )
        }

        if let root = tryParseDictionaryJSON(from: fileURL), looksLikeChatBoxRoot(root) {
            return root
        }

        if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后导入 ChatBox 导出的 JSON。", comment: "ChatBox import compressed backup unsupported")
            )
        }

        if tryParseDictionaryJSON(from: fileURL) == nil {
            throw ThirdPartyImportError.invalidJSON
        }

        throw ThirdPartyImportError.unsupportedBackupFormat(
            reason: NSLocalizedString("ChatBox 导出不是可识别的 JSON 备份。", comment: "ChatBox import unrecognized backup")
        )
    }

    static func looksLikeChatBoxRoot(_ root: [String: Any]) -> Bool {
        if root["settings"] != nil
            || root["chat-sessions-list"] != nil
            || root["chat-sessions"] != nil
            || root["__exported_items"] != nil {
            return true
        }

        if root.keys.contains(where: { $0.hasPrefix("session:") }) {
            return true
        }

        return looksLikeChatBoxSettings(root) || looksLikeChatBoxSession(root)
    }

    static func looksLikeChatBoxSettings(_ root: [String: Any]) -> Bool {
        root["providers"] != nil
            || root["customProviders"] != nil
            || root["defaultChatModel"] != nil
            || root["defaultPrompt"] != nil
    }

    static func looksLikeChatBoxSession(_ root: [String: Any]) -> Bool {
        root["messages"] != nil
            && root["id"] != nil
            && root["name"] != nil
    }

    static func chatBoxSettings(from root: [String: Any]) -> [String: Any]? {
        if let settings = chatBoxDictionary(root["settings"]) {
            return unwrapChatBoxPersistedState(settings)
        }

        if looksLikeChatBoxSettings(root) {
            return unwrapChatBoxPersistedState(root)
        }

        return nil
    }

    static func unwrapChatBoxPersistedState(_ value: [String: Any]) -> [String: Any] {
        if let state = chatBoxDictionary(value["state"]) {
            return state
        }
        return value
    }

    static func chatBoxSessionEntries(from root: [String: Any]) -> [(sourceID: String, session: [String: Any])] {
        if looksLikeChatBoxSession(root) {
            return [(nonEmpty(string(root["id"])) ?? "single-session", root)]
        }

        var sessionByID: [String: [String: Any]] = [:]
        for (key, value) in root where key.hasPrefix("session:") {
            guard let session = chatBoxDictionary(value) else { continue }
            let fallbackID = String(key.dropFirst("session:".count))
            let sessionID = nonEmpty(string(session["id"])) ?? fallbackID
            sessionByID[sessionID] = session
        }

        var orderedIDs: [String] = []
        for metaAny in normalizeJSONArray(root["chat-sessions-list"]) {
            guard let meta = chatBoxDictionary(metaAny),
                  let id = nonEmpty(string(meta["id"])) else {
                continue
            }
            orderedIDs.append(id)
        }

        var result: [(sourceID: String, session: [String: Any])] = []
        var emitted = Set<String>()
        for id in orderedIDs {
            guard let session = sessionByID[id], emitted.insert(id).inserted else { continue }
            result.append((id, session))
        }

        for id in sessionByID.keys.sorted() where !emitted.contains(id) {
            guard let session = sessionByID[id] else { continue }
            emitted.insert(id)
            result.append((id, session))
        }

        for (index, sessionAny) in normalizeJSONArray(root["chat-sessions"]).enumerated() {
            guard let session = chatBoxDictionary(sessionAny) else { continue }
            let sessionID = nonEmpty(string(session["id"])) ?? "legacy-\(index)"
            guard emitted.insert(sessionID).inserted else { continue }
            result.append((sessionID, session))
        }

        return result
    }

    static func collectChatBoxReferencedModels(
        settings: [String: Any]?,
        sessionEntries: [(sourceID: String, session: [String: Any])]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]

        func record(provider: String?, model: String?) {
            guard let provider = nonEmpty(provider),
                  let model = nonEmpty(model) else {
                return
            }
            result[provider, default: []].insert(model)
        }

        if let settings {
            for key in ["defaultChatModel", "threadNamingModel", "searchTermConstructionModel", "ocrModel"] {
                guard let modelRef = chatBoxDictionary(settings[key]) else { continue }
                record(provider: string(modelRef["provider"]), model: string(modelRef["model"]))
            }

            for favoriteAny in normalizeJSONArray(settings["favoritedModels"]) {
                guard let favorite = chatBoxDictionary(favoriteAny) else { continue }
                record(provider: string(favorite["provider"]), model: string(favorite["model"]))
            }
        }

        for entry in sessionEntries {
            let session = entry.session
            let sessionSettings = chatBoxDictionary(session["settings"])
            let fallbackProvider = string(sessionSettings?["provider"])
            let fallbackModel = string(sessionSettings?["modelId"])
            record(provider: fallbackProvider, model: fallbackModel)

            forEachChatBoxMessageMap(in: session) { message in
                record(
                    provider: string(message["aiProvider"]) ?? fallbackProvider,
                    model: string(message["model"]) ?? fallbackModel
                )
            }
        }

        return result
    }

    static func parseChatBoxProviders(
        _ settings: [String: Any]?,
        referencedModelsByProvider: [String: Set<String>],
        warnings: inout [String]
    ) -> ChatBoxProviderBundle {
        guard let settings else {
            return ChatBoxProviderBundle(providers: [], referenceByChatBoxProviderID: [:])
        }

        let providerSettingsByID = chatBoxDictionary(settings["providers"]) ?? [:]
        let customProviderByID = normalizeJSONArray(settings["customProviders"]).reduce(into: [String: [String: Any]]()) { result, customAny in
            guard let custom = chatBoxDictionary(customAny),
                  let id = nonEmpty(string(custom["id"])) else {
                return
            }
            result[id] = custom
        }
        let candidateIDs = Set(providerSettingsByID.keys).union(customProviderByID.keys)
        var providers: [Provider] = []
        var references: [String: ChatBoxProviderReference] = [:]
        var warnedUnsupported = Set<String>()
        var warnedChatBoxAI = false

        for providerID in candidateIDs.sorted() {
            if providerID == "chatbox-ai" {
                if !warnedChatBoxAI {
                    warnings.append(NSLocalizedString("ChatBox 导出包含 Chatbox AI 专用授权或内置服务配置，ELS 无法直接迁移这类账号授权。", comment: "ChatBox import skips Chatbox AI warning"))
                    warnedChatBoxAI = true
                }
                continue
            }

            let settingsMap = chatBoxDictionary(providerSettingsByID[providerID]) ?? [:]
            let customInfo = customProviderByID[providerID]
            let typeHint = nonEmpty(string(customInfo?["type"]))
            let definition = chatBoxProviderDefinition(providerID: providerID, typeHint: typeHint)
            guard definition.isSupported else {
                if warnedUnsupported.insert(providerID).inserted {
                    warnings.append(
                        String(
                            format: NSLocalizedString("ChatBox 提供商 %@ 使用了暂不支持的专用配置，已跳过。", comment: "ChatBox import skips unsupported provider warning"),
                            nonEmpty(string(customInfo?["name"])) ?? definition.name
                        )
                    )
                }
                continue
            }

            let models = chatBoxImportedModels(
                providerID: providerID,
                settingsMap: settingsMap,
                customInfo: customInfo,
                referencedModelIDs: referencedModelsByProvider[providerID] ?? []
            )
            let name = nonEmpty(string(customInfo?["name"])) ?? definition.name
            let baseURL = normalizeBaseURL(
                nonEmpty(string(settingsMap["apiHost"]))
                    ?? nonEmpty(string(settingsMap["endpoint"]))
                    ?? chatBoxDefaultSettingsBaseURL(customInfo)
                    ?? definition.defaultBaseURL,
                for: definition.apiFormat
            )
            let provider = Provider(
                id: stableUUID(from: "chatbox-provider:\(providerID)") ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: splitAPIKeys(string(settingsMap["apiKey"]) ?? ""),
                apiFormat: definition.apiFormat,
                models: normalizeModelsForProviderFormat(models, apiFormat: definition.apiFormat)
            )
            providers.append(provider)
            references[providerID] = ChatBoxProviderReference(
                provider: provider,
                modelByChatBoxModelID: Dictionary(uniqueKeysWithValues: provider.models.map { ($0.modelName, $0) })
            )
        }

        return ChatBoxProviderBundle(
            providers: dedupeProviders(providers),
            referenceByChatBoxProviderID: references
        )
    }

    static func chatBoxDefaultSettingsBaseURL(_ customInfo: [String: Any]?) -> String? {
        guard let defaultSettings = chatBoxDictionary(customInfo?["defaultSettings"]) else {
            return nil
        }
        return nonEmpty(string(defaultSettings["apiHost"]))
    }

    static func chatBoxImportedModels(
        providerID: String,
        settingsMap: [String: Any],
        customInfo: [String: Any]?,
        referencedModelIDs: Set<String>
    ) -> [Model] {
        let excludedModels = Set(normalizeStringArray(settingsMap["excludedModels"]))
        var modelMaps = normalizeJSONArray(settingsMap["models"]).compactMap(chatBoxDictionary)
        if modelMaps.isEmpty,
           let defaultSettings = chatBoxDictionary(customInfo?["defaultSettings"]) {
            modelMaps = normalizeJSONArray(defaultSettings["models"]).compactMap(chatBoxDictionary)
        }

        var result: [Model] = []
        var seenModelIDs = Set<String>()

        for modelMap in modelMaps {
            let modelID = nonEmpty(string(modelMap["modelId"]) ?? string(modelMap["id"])) ?? ""
            guard let model = chatBoxImportedModel(
                providerID: providerID,
                modelMap: modelMap,
                isActivated: !excludedModels.contains(modelID)
            ) else {
                continue
            }
            if seenModelIDs.insert(model.modelName).inserted {
                result.append(model)
            }
        }

        for modelID in referencedModelIDs.sorted() where !seenModelIDs.contains(modelID) {
            var model = importedModel(
                modelName: modelID,
                displayName: modelID,
                isActivated: !excludedModels.contains(modelID),
                kind: nil,
                capabilities: nil
            ).applyingInferredCapabilityHints()
            if let id = stableUUID(from: "chatbox-model:\(providerID):\(modelID)") {
                model.id = id
            }
            result.append(model)
            seenModelIDs.insert(modelID)
        }

        return result
    }

    static func chatBoxImportedModel(
        providerID: String,
        modelMap: [String: Any],
        isActivated: Bool
    ) -> Model? {
        guard let modelID = nonEmpty(string(modelMap["modelId"]) ?? string(modelMap["id"])) else {
            return nil
        }

        let displayName = nonEmpty(string(modelMap["nickname"]))
            ?? nonEmpty(string(modelMap["name"]))
            ?? nonEmpty(string(modelMap["displayName"]))
            ?? modelID
        let rawType = string(modelMap["type"])
        let kind = modelKind(from: rawType)
        let capabilityValues = Set(normalizeStringArray(modelMap["capabilities"]).map(normalizedTypeString))
        let hasCapabilityField = modelMap.keys.contains("capabilities")
        let inputModalities: [ModelModality]? = capabilityValues.contains("vision")
            ? [.text, .image]
            : nil
        let capabilities = chatBoxModelCapabilities(
            from: capabilityValues,
            fieldPresent: hasCapabilityField,
            kind: kind
        )

        var model = importedModel(
            modelName: modelID,
            displayName: displayName,
            isActivated: isActivated,
            kind: kind,
            inputModalities: inputModalities,
            capabilities: capabilities
        )
        if !hasCapabilityField && kind == nil {
            model = model.applyingInferredCapabilityHints()
        }
        if let id = stableUUID(from: "chatbox-model:\(providerID):\(modelID)") {
            model.id = id
        }
        return model
    }

    static func chatBoxModelCapabilities(
        from values: Set<String>,
        fieldPresent: Bool,
        kind: ModelKind?
    ) -> [ModelCapability]? {
        if kind == .embedding {
            return []
        }

        var result: [ModelCapability] = []
        if values.contains("tool-use")
            || values.contains("tool")
            || values.contains("tools")
            || values.contains("function-calling")
            || values.contains("tool-calling") {
            result.append(.toolCalling)
        }
        if values.contains("reasoning") {
            result.append(.reasoning)
        }

        if result.isEmpty {
            return fieldPresent ? [] : nil
        }
        return Model.orderedCapabilities(result)
    }

    static func chatBoxProviderDefinition(providerID: String, typeHint: String?) -> ChatBoxProviderDefinition {
        switch providerID {
        case "openai":
            return ChatBoxProviderDefinition(name: "OpenAI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.openai.com", isSupported: true)
        case "openai-responses":
            return ChatBoxProviderDefinition(name: "OpenAI Responses", apiFormat: "openai-responses", defaultBaseURL: "https://api.openai.com", isSupported: true)
        case "claude":
            return ChatBoxProviderDefinition(name: "Claude", apiFormat: "anthropic", defaultBaseURL: "https://api.anthropic.com", isSupported: true)
        case "gemini":
            return ChatBoxProviderDefinition(name: "Gemini", apiFormat: "gemini", defaultBaseURL: "https://generativelanguage.googleapis.com", isSupported: true)
        case "ollama":
            return ChatBoxProviderDefinition(name: "Ollama", apiFormat: "openai-compatible", defaultBaseURL: "http://127.0.0.1:11434", isSupported: true)
        case "groq":
            return ChatBoxProviderDefinition(name: "Groq", apiFormat: "openai-compatible", defaultBaseURL: "https://api.groq.com/openai", isSupported: true)
        case "deepseek":
            return ChatBoxProviderDefinition(name: "DeepSeek", apiFormat: "openai-compatible", defaultBaseURL: "https://api.deepseek.com", isSupported: true)
        case "siliconflow":
            return ChatBoxProviderDefinition(name: "SiliconFlow", apiFormat: "openai-compatible", defaultBaseURL: "https://api.siliconflow.cn", isSupported: true)
        case "volcengine":
            return ChatBoxProviderDefinition(name: "VolcEngine", apiFormat: "openai-compatible", defaultBaseURL: "https://ark.cn-beijing.volces.com", isSupported: true)
        case "mistral-ai":
            return ChatBoxProviderDefinition(name: "Mistral AI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.mistral.ai/v1", isSupported: true)
        case "lm-studio":
            return ChatBoxProviderDefinition(name: "LM Studio", apiFormat: "openai-compatible", defaultBaseURL: "http://127.0.0.1:1234", isSupported: true)
        case "perplexity":
            return ChatBoxProviderDefinition(name: "Perplexity", apiFormat: "openai-compatible", defaultBaseURL: "https://api.perplexity.ai", isSupported: true)
        case "xAI", "xai":
            return ChatBoxProviderDefinition(name: "xAI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.x.ai", isSupported: true)
        case "openrouter":
            return ChatBoxProviderDefinition(name: "OpenRouter", apiFormat: "openai-compatible", defaultBaseURL: "https://openrouter.ai/api/v1", isSupported: true)
        case "chatglm-6b":
            return ChatBoxProviderDefinition(name: "ChatGLM6B", apiFormat: "openai-compatible", defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4", isSupported: true)
        case "qwen":
            return ChatBoxProviderDefinition(name: "Qwen", apiFormat: "openai-compatible", defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", isSupported: true)
        case "qwen-portal":
            return ChatBoxProviderDefinition(name: "Qwen Portal", apiFormat: "openai-compatible", defaultBaseURL: "https://portal.qwen.ai/v1", isSupported: true)
        case "minimax":
            return ChatBoxProviderDefinition(name: "MiniMax Global", apiFormat: "openai-compatible", defaultBaseURL: "https://api.minimax.io/v1", isSupported: true)
        case "minimax-cn":
            return ChatBoxProviderDefinition(name: "MiniMax CN", apiFormat: "openai-compatible", defaultBaseURL: "https://api.minimaxi.com/v1", isSupported: true)
        case "moonshot":
            return ChatBoxProviderDefinition(name: "Moonshot AI", apiFormat: "openai-compatible", defaultBaseURL: "https://api.moonshot.ai/v1", isSupported: true)
        case "moonshot-cn":
            return ChatBoxProviderDefinition(name: "Moonshot CN", apiFormat: "openai-compatible", defaultBaseURL: "https://api.moonshot.cn/v1", isSupported: true)
        case "azure", "bedrock":
            return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-compatible", defaultBaseURL: "", isSupported: false)
        default:
            let normalized = normalizedTypeString(typeHint)
            if normalized == "claude" || normalized == "anthropic" {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "anthropic", defaultBaseURL: "https://api.anthropic.com", isSupported: true)
            }
            if normalized == "gemini" || normalized == "google" {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "gemini", defaultBaseURL: "https://generativelanguage.googleapis.com", isSupported: true)
            }
            if isOpenAIResponsesType(normalized) {
                return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-responses", defaultBaseURL: "https://api.openai.com", isSupported: true)
            }
            return ChatBoxProviderDefinition(name: providerID, apiFormat: "openai-compatible", defaultBaseURL: "https://api.openai.com", isSupported: true)
        }
    }

    static func chatBoxAllMessageMaps(in session: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        forEachChatBoxMessageMap(in: session) { message in
            result.append(message)
        }
        return result
    }

    static func forEachChatBoxMessageMap(
        in session: [String: Any],
        _ body: ([String: Any]) -> Void
    ) {
        for messageAny in normalizeJSONArray(session["messages"]) {
            guard let message = chatBoxDictionary(messageAny) else { continue }
            body(message)
        }

        for threadAny in normalizeJSONArray(session["threads"]) {
            guard let thread = chatBoxDictionary(threadAny) else { continue }
            for messageAny in normalizeJSONArray(thread["messages"]) {
                guard let message = chatBoxDictionary(messageAny) else { continue }
                body(message)
            }
        }

        let forks = dictionary(session["messageForksHash"]) ?? [:]
        for forkAny in forks.values {
            guard let fork = chatBoxDictionary(forkAny) else { continue }
            for listAny in normalizeJSONArray(fork["lists"]) {
                guard let list = chatBoxDictionary(listAny) else { continue }
                for messageAny in normalizeJSONArray(list["messages"]) {
                    guard let message = chatBoxDictionary(messageAny) else { continue }
                    body(message)
                }
            }
        }
    }

    static func chatBoxDictionary(_ any: Any?) -> [String: Any]? {
        if let dict = any as? [String: Any] {
            return dict
        }
        if let text = any as? String,
           let parsed = parseJSONStringToDictionary(text) {
            return parsed
        }
        return nil
    }

}
