// ============================================================================
// ThirdPartyImportCherryStudio.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 Cherry Studio 导出的提供商配置。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseCherryStudio(fileURL: URL) throws -> ParsedPayload {
        let root = try loadCherryRoot(fileURL: fileURL)

        var warnings: [String] = []
        var providers: [Provider] = []

        let localStorage = dictionary(root["localStorage"])
        let indexedDB = dictionary(root["indexedDB"])

        if localStorage == nil {
            warnings.append(NSLocalizedString("Cherry 备份未找到 localStorage。", comment: "Cherry import missing localStorage warning"))
        }
        if indexedDB == nil {
            warnings.append(NSLocalizedString("Cherry 备份未找到 indexedDB。", comment: "Cherry import missing indexedDB warning"))
        }

        let persistRaw = string(localStorage?["persist:cherry-studio"])
        var persist = [String: Any]()
        if let persistRaw, let parsed = parseJSONStringToDictionary(persistRaw) {
            persist = parsed
        }

        if let llmRaw = string(persist["llm"]),
           let llm = parseJSONStringToDictionary(llmRaw),
           let providerList = array(llm["providers"]) {
            providers = parseCherryProviders(providerList)
        }

        if providers.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("Cherry 备份格式无法识别，或文件中没有可导入数据。", comment: "Cherry import unrecognized or empty backup")
            )
        }

        return ParsedPayload(
            providers: dedupeProviders(providers),
            warnings: warnings
        )
    }

    static func loadCherryRoot(fileURL: URL) throws -> [String: Any] {
        if let root = tryParseDictionaryJSON(from: fileURL), looksLikeCherryRoot(root) {
            return root
        }

        if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后选择包含 JSON 的文件或目录。", comment: "Cherry import compressed backup unsupported")
            )
        }

        if isDirectory(fileURL),
           let root = try findFirstDictionaryJSON(inDirectory: fileURL, where: looksLikeCherryRoot) {
            return root
        }

        throw ThirdPartyImportError.unsupportedBackupFormat(
            reason: NSLocalizedString("无法识别 Cherry 备份结构（需包含 localStorage 与 indexedDB）。", comment: "Cherry import unrecognized backup structure")
        )
    }

    static func looksLikeCherryRoot(_ root: [String: Any]) -> Bool {
        root["localStorage"] != nil && root["indexedDB"] != nil
    }

    static func parseCherryProviders(_ providerList: [Any]) -> [Provider] {
        var result: [Provider] = []
        result.reserveCapacity(providerList.count)

        for providerAny in providerList {
            guard let provider = dictionary(providerAny) else { continue }

            let type = string(provider["type"])?.lowercased()
            let name = nonEmpty(string(provider["name"])) ?? "Cherry Studio"
            let rawHost = nonEmpty(string(provider["apiHost"]))
            let rawApiKey = string(provider["apiKey"]) ?? ""
            let apiKeys = splitAPIKeys(rawApiKey)
            let modelEntries = normalizeJSONArray(provider["models"])
            let providerUsesResponsesAPI = isOpenAIResponsesType(type)
            let enabled = bool(provider["enabled"], defaultValue: true)
            let headerOverrides = stringDictionary(provider["extra_headers"])

            let modelList: [Model] = modelEntries.compactMap { modelAny in
                guard let modelMap = dictionary(modelAny) else { return nil }
                let modelID = nonEmpty(string(modelMap["id"]))
                    ?? nonEmpty(string(modelMap["modelId"]))
                guard let modelID else { return nil }
                let displayName = nonEmpty(string(modelMap["name"]))
                    ?? nonEmpty(string(modelMap["displayName"]))
                    ?? modelID
                let modelUsesResponsesAPI = providerUsesResponsesAPI
                    || isOpenAIResponsesType(string(modelMap["endpoint_type"]))
                let capabilityShape = cherryModelCapabilityShape(modelMap)
                return importedModel(
                    modelName: modelID,
                    displayName: displayName,
                    isActivated: enabled,
                    useResponsesAPI: modelUsesResponsesAPI,
                    kind: capabilityShape.kind,
                    inputModalities: capabilityShape.inputModalities,
                    outputModalities: capabilityShape.outputModalities,
                    capabilities: capabilityShape.capabilities
                )
            }

            let format = normalizeProviderFormat(typeHint: type, modelIDs: modelList.map(\.modelName))
            let baseURL = normalizeBaseURL(rawHost, for: format)
            let normalizedModels = normalizeModelsForProviderFormat(modelList, apiFormat: format)

            let imported = Provider(
                id: stableUUID(from: string(provider["id"])) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: apiKeys,
                apiFormat: format,
                models: normalizedModels,
                headerOverrides: headerOverrides
            )
            result.append(imported)
        }

        return result
    }

}
