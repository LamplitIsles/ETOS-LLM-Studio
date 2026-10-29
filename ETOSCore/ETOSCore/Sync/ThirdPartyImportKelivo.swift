// ============================================================================
// ThirdPartyImportKelivo.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 Kelivo 导出的提供商配置。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseKelivo(fileURL: URL) throws -> ParsedPayload {
        var warnings: [String] = []
        var settings = [String: Any]()

        if isDirectory(fileURL) {
            if let parsedSettings = findJSONInDirectory(fileURL, preferredNames: ["settings.json"]) {
                settings = parsedSettings
            }
        } else if let parsed = tryParseDictionaryJSON(from: fileURL) {
            settings = parsed
        } else if isLikelyCompressedBackup(fileURL) {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("当前版本暂不支持直接读取压缩包，请先解压后再导入 settings.json。", comment: "Kelivo import compressed backup unsupported")
            )
        }

        let providers = parseKelivoProviders(settings)

        if providers.isEmpty {
            warnings.append(NSLocalizedString("Kelivo 备份中未识别到 provider_configs。", comment: "Kelivo import missing provider configs warning"))
        }
        if providers.isEmpty {
            throw ThirdPartyImportError.unsupportedBackupFormat(
                reason: NSLocalizedString("未识别到 Kelivo 备份中的可导入数据。", comment: "Kelivo import no importable data")
            )
        }

        return ParsedPayload(
            providers: dedupeProviders(providers),
            warnings: warnings
        )
    }

    static func parseKelivoProviders(_ settings: [String: Any]) -> [Provider] {
        var result: [Provider] = []

        let rawConfigs = settings["provider_configs"] ?? settings["provider_configs_v1"]
        var configs: [String: Any] = [:]

        if let rawString = string(rawConfigs), let parsed = parseJSONStringToDictionary(rawString) {
            configs = parsed
        } else if let rawDict = dictionary(rawConfigs) {
            configs = rawDict
        }

        for (providerID, configAny) in configs {
            guard let config = dictionary(configAny) else { continue }

            let typeHint = nonEmpty(string(config["providerType"]))?.lowercased()
            let modelKeys = normalizeStringArray(config["models"])
            let modelOverrides = dictionary(config["modelOverrides"]) ?? [:]
            var apiModelIDCounts: [String: Int] = [:]
            for modelKey in modelKeys {
                guard let override = dictionary(modelOverrides[modelKey]),
                      let apiModelID = kelivoAPIModelID(from: override) else {
                    continue
                }
                apiModelIDCounts[apiModelID, default: 0] += 1
            }

            let format = normalizeProviderFormat(typeHint: typeHint, modelIDs: modelKeys)
            let name = nonEmpty(string(config["name"])) ?? providerID

            var keys: [String] = []
            if let key = nonEmpty(string(config["apiKey"])) {
                keys.append(key)
            }
            if let apiKeysRaw = array(config["apiKeys"]) {
                for apiKeyAny in apiKeysRaw {
                    guard let map = dictionary(apiKeyAny),
                          bool(map["isEnabled"], defaultValue: true),
                          string(map["status"])?.lowercased() != "disabled",
                          let key = nonEmpty(string(map["key"])) else {
                        continue
                    }
                    keys.append(key)
                }
            }
            keys = dedupeStrings(keys)

            let baseURL = normalizeBaseURL(string(config["baseUrl"]), for: format)
            let enabled = bool(config["enabled"], defaultValue: true)
            let providerUsesResponsesAPI = format == "openai-compatible"
                && bool(config["useResponseApi"], defaultValue: false)

            let modelList: [Model] = modelKeys.map { modelKey in
                let override = dictionary(modelOverrides[modelKey]) ?? [:]
                let apiModelID = kelivoAPIModelID(from: override)
                let shouldKeepLogicalModelName = apiModelID.map { (apiModelIDCounts[$0] ?? 0) > 1 } ?? false
                let modelName = shouldKeepLogicalModelName ? modelKey : (apiModelID ?? modelKey)
                let displayName = nonEmpty(string(override["name"])) ?? modelKey
                let capabilityShape = kelivoModelCapabilityShape(override)
                var customBody = customBodyOverrideParameters(
                    from: override["body"],
                    parseStringValues: true
                )
                if shouldKeepLogicalModelName, let apiModelID {
                    customBody["model"] = .string(apiModelID)
                }

                return importedModel(
                    modelName: modelName,
                    displayName: displayName,
                    isActivated: enabled,
                    useResponsesAPI: providerUsesResponsesAPI,
                    overrideParameters: customBody,
                    kind: capabilityShape.kind,
                    inputModalities: capabilityShape.inputModalities,
                    outputModalities: capabilityShape.outputModalities,
                    capabilities: capabilityShape.capabilities
                )
            }

            let provider = Provider(
                id: stableUUID(from: providerID) ?? UUID(),
                name: name,
                baseURL: baseURL,
                apiKeys: keys,
                apiFormat: format,
                models: normalizeModelsForProviderFormat(modelList, apiFormat: format),
                proxyConfiguration: networkProxyConfiguration(from: config)
            )
            result.append(provider)
        }

        return result
    }

}
