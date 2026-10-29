// ============================================================================
// SyncEnginePrimaryMerge.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步导入时的 Provider 与背景文件顶层合并入口。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - Providers

    static func mergeProviders(
        _ incoming: [Provider],
        chatService: ChatService
    ) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = ConfigLoader.loadProviders()
        var imported = 0
        var skipped = 0
        var didMutateProviderStore = false

        let localCompaction = compactProvidersByIdentity(local)
        if localCompaction.changed {
            for removedProvider in localCompaction.removedProviders {
                ConfigLoader.deleteProvider(removedProvider)
            }
            for updatedProvider in localCompaction.updatedProviders {
                ConfigLoader.saveProvider(updatedProvider)
            }
            local = localCompaction.providers
            didMutateProviderStore = true
        }

        let incomingProviders = compactProvidersByIdentity(incoming).providers

        for provider in incomingProviders {
            let incomingHash = computeProviderContentHash(provider)

            if let exactIndex = local.firstIndex(where: { computeProviderContentHash($0) == incomingHash }) {
                let mergedAPIKeys = mergeProviderAPIKeys(local[exactIndex].apiKeys, provider.apiKeys)
                if mergedAPIKeys == local[exactIndex].apiKeys {
                    skipped += 1
                } else {
                    local[exactIndex].apiKeys = mergedAPIKeys
                    ConfigLoader.saveProvider(local[exactIndex])
                    imported += 1
                    didMutateProviderStore = true
                }
                continue
            }

            if let candidateIndex = providerMergeCandidateIndex(for: provider, localProviders: local) {
                switch mergeProviderDeep(local[candidateIndex], with: provider) {
                case .unchanged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    skipped += 1
                    continue
                case .merged(let mergedProvider):
                    local[candidateIndex] = mergedProvider
                    ConfigLoader.saveProvider(mergedProvider)
                    imported += 1
                    didMutateProviderStore = true
                    continue
                case .conflict:
                    guard providerMergeIdentity(local[candidateIndex]) == providerMergeIdentity(provider) else {
                        break
                    }
                    let conservativeResult = mergeProviderConservatively(
                        local[candidateIndex],
                        with: provider,
                        preferIncomingModelCapabilityShape: true
                    )
                    if conservativeResult.changed {
                        local[candidateIndex] = conservativeResult.provider
                        ConfigLoader.saveProvider(conservativeResult.provider)
                        imported += 1
                        didMutateProviderStore = true
                    } else {
                        skipped += 1
                    }
                    continue
                }
            }

            var copied = provider
            copied = reassignProviderIdentifiersIfNeeded(copied, existingProviders: local)
            ConfigLoader.saveProvider(copied)
            local.append(copied)
            imported += 1
            didMutateProviderStore = true
        }

        if didMutateProviderStore {
            chatService.reloadProviders()
        }

        return (imported, skipped)
    }

    // MARK: - Sessions

    static func mergeBackgrounds(_ incoming: [SyncedBackground]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        ConfigLoader.setupBackgroundsDirectory()
        let directory = ConfigLoader.getBackgroundsDirectory()
        let fileManager = FileManager.default
        var checksumMap: [String: URL] = [:]

        if let localFiles = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in localFiles {
                if let data = try? Data(contentsOf: url) {
                    checksumMap[data.sha256Hex] = url
                }
            }
        }

        var imported = 0
        var skipped = 0

        for background in incoming {
            if checksumMap[background.checksum] != nil {
                skipped += 1
                continue
            }

            var targetName = background.filename
            var targetURL = directory.appendingPathComponent(targetName)

            while fileManager.fileExists(atPath: targetURL.path) {
                let name = targetName.replacingOccurrences(of: ".\(targetURL.pathExtension)", with: "")
                targetName = "\(name)-sync-\(background.checksum.prefix(6)).\(targetURL.pathExtension)"
                targetURL = directory.appendingPathComponent(targetName)
            }

            do {
                try background.data.write(to: targetURL, options: [.atomic])
                checksumMap[background.checksum] = targetURL
                imported += 1
            } catch {
                skipped += 1
            }
        }

        return (imported, skipped)
    }
}
