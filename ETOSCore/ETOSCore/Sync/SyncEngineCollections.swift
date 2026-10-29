// ============================================================================
// SyncEngineCollections.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载媒体、字体、技能与快捷工具同步逻辑。
// ============================================================================

import Foundation
import Combine

extension SyncEngine {
    // MARK: - Audio Files

    static func mergeAudioFiles(_ incoming: [SyncedAudio]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0
        let existingFileNames = Set(Persistence.getAllAudioFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadAudio(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }

        for audio in incoming {
            if existingChecksums.contains(audio.checksum) {
                skipped += 1
                continue
            }

            var targetFileName = audio.filename
            if existingFileNames.contains(audio.filename) {
                let ext = (audio.filename as NSString).pathExtension
                let name = (audio.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }

            if Persistence.saveAudio(audio.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(audio.checksum)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    static func mergeImageFiles(_ incoming: [SyncedImage]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0
        let existingFileNames = Set(Persistence.getAllImageFileNames())
        var existingChecksums = Set<String>()
        for fileName in existingFileNames {
            if let data = Persistence.loadImage(fileName: fileName) {
                existingChecksums.insert(data.sha256Hex)
            }
        }

        for image in incoming {
            if existingChecksums.contains(image.checksum) {
                skipped += 1
                continue
            }

            var targetFileName = image.filename
            if existingFileNames.contains(image.filename) {
                let ext = (image.filename as NSString).pathExtension
                let name = (image.filename as NSString).deletingPathExtension
                targetFileName = "\(name)_\(UUID().uuidString.prefix(8)).\(ext)"
            }

            if Persistence.saveImage(image.data, fileName: targetFileName) != nil {
                imported += 1
                existingChecksums.insert(image.checksum)
            } else {
                skipped += 1
            }
        }

        return (imported, skipped)
    }

    static func mergeFontFiles(_ incoming: [SyncedFontFile]) -> (imported: Int, skipped: Int, idMapping: [UUID: UUID]) {
        guard !incoming.isEmpty else { return (0, 0, [:]) }

        var imported = 0
        var skipped = 0
        var idMapping: [UUID: UUID] = [:]
        let existingAssets = FontLibrary.loadAssets()
        var knownChecksums = Set(existingAssets.map(\.checksum))
        var knownEnabledStatesByChecksum = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.checksum, $0.isEnabled) })

        for fontFile in incoming {
            do {
                let existedBefore = knownChecksums.contains(fontFile.checksum)
                let previousEnabledState = knownEnabledStatesByChecksum[fontFile.checksum]
                let record = try FontLibrary.importFont(
                    data: fontFile.data,
                    fileName: fontFile.filename,
                    preferredDisplayName: fontFile.displayName
                )

                _ = FontLibrary.setAssetEnabled(id: record.id, isEnabled: fontFile.isEnabled)
                idMapping[fontFile.assetID] = record.id
                knownChecksums.insert(record.checksum)
                knownEnabledStatesByChecksum[record.checksum] = fontFile.isEnabled

                if existedBefore, previousEnabledState == fontFile.isEnabled {
                    skipped += 1
                } else {
                    imported += 1
                }
            } catch {
                skipped += 1
            }
        }

        return (imported, skipped, idMapping)
    }

    static func mergeFontRouteConfiguration(
        _ incomingData: Data?,
        idMapping: [UUID: UUID]
    ) -> (imported: Int, skipped: Int) {
        guard let incomingData else { return (0, 0) }
        guard let incoming = try? JSONDecoder().decode(FontRouteConfiguration.self, from: incomingData) else {
            return (0, 1)
        }

        let existingIDs = Set(FontLibrary.loadAssets().map(\.id))
        var normalized = FontRouteConfiguration(
            body: normalizeRouteIDs(incoming.body, idMapping: idMapping, validIDs: existingIDs),
            emphasis: normalizeRouteIDs(incoming.emphasis, idMapping: idMapping, validIDs: existingIDs),
            strong: normalizeRouteIDs(incoming.strong, idMapping: idMapping, validIDs: existingIDs),
            code: normalizeRouteIDs(incoming.code, idMapping: idMapping, validIDs: existingIDs),
            languageBuckets: [:],
            customTextRules: incoming.customTextRules.map { rule in
                var normalizedRule = rule
                normalizedRule.fontAssetIDs = normalizeRouteIDs(
                    rule.fontAssetIDs,
                    idMapping: idMapping,
                    validIDs: existingIDs
                )
                return normalizedRule
            }
        )

        for (bucketKey, bucketValue) in incoming.languageBuckets {
            normalized.languageBuckets[bucketKey] = FontRouteConfiguration.LanguageBucketConfiguration(
                body: normalizeRouteIDs(bucketValue.body, idMapping: idMapping, validIDs: existingIDs),
                emphasis: normalizeRouteIDs(bucketValue.emphasis, idMapping: idMapping, validIDs: existingIDs),
                strong: normalizeRouteIDs(bucketValue.strong, idMapping: idMapping, validIDs: existingIDs),
                code: normalizeRouteIDs(bucketValue.code, idMapping: idMapping, validIDs: existingIDs)
            )
        }

        let current = FontLibrary.loadRouteConfiguration()
        if current == normalized {
            return (0, 1)
        }

        _ = FontLibrary.saveRouteConfiguration(normalized)
        return (1, 0)
    }

    static func normalizeRouteIDs(
        _ ids: [UUID],
        idMapping: [UUID: UUID],
        validIDs: Set<UUID>
    ) -> [UUID] {
        var seen = Set<UUID>()
        var normalized: [UUID] = []

        for id in ids {
            let mapped = idMapping[id] ?? id
            guard validIDs.contains(mapped) else { continue }
            guard seen.insert(mapped).inserted else { continue }
            normalized.append(mapped)
        }

        return normalized
    }

    // MARK: - Skills

    static func mergeSkills(_ incoming: [SyncedSkillBundle]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var imported = 0
        var skipped = 0

        for bundle in incoming {
            let skillName = bundle.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard SkillPaths.isValidSkillName(skillName), !bundle.files.isEmpty else {
                skipped += 1
                continue
            }

            var incomingFiles: [String: Data] = [:]
            var hasDuplicatePath = false
            for file in bundle.files {
                let relativePath = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !relativePath.isEmpty else {
                    hasDuplicatePath = true
                    break
                }
                if incomingFiles.updateValue(file.fileData, forKey: relativePath) != nil {
                    hasDuplicatePath = true
                    break
                }
            }
            guard !hasDuplicatePath else {
                skipped += 1
                continue
            }
            guard incomingFiles.keys.contains("SKILL.md") else {
                skipped += 1
                continue
            }

            let localFiles = SkillStore.readAllSkillFileData(skillName: skillName)
            if let localFiles {
                let localBundle = SyncedSkillBundle(
                    name: skillName,
                    files: localFiles
                        .map { SyncedSkillFile(relativePath: $0.key, data: $0.value) }
                )
                if localBundle.checksum == bundle.checksum {
                    skipped += 1
                    continue
                }
            }

            if SkillStore.saveSkillDataFilesAtomically(skillName: skillName, files: incomingFiles) {
                imported += 1
            } else {
                skipped += 1
            }
        }

        if imported > 0 {
            Task { @MainActor in
                #if os(macOS)
                let manager = await SkillManager.prepareSharedInBackground()
                try? await manager.reloadLibraryInBackground()
                #else
                SkillManager.shared.reloadFromDisk()
                #endif
            }
        }

        return (imported, skipped)
    }

    // MARK: - Shortcut Tools

    static func mergeShortcutTools(_ incoming: [ShortcutToolDefinition]) -> (imported: Int, skipped: Int) {
        guard !incoming.isEmpty else { return (0, 0) }

        var local = ShortcutToolStore.loadTools()
        var imported = 0
        var skipped = 0

        for incomingTool in incoming {
            if local.contains(where: { $0.isEquivalent(to: incomingTool) }) {
                skipped += 1
                continue
            }

            let incomingName = ShortcutToolNaming.normalizeExecutableName(incomingTool.name)
            if local.contains(where: { ShortcutToolNaming.normalizeExecutableName($0.name) == incomingName }) {
                skipped += 1
                continue
            }

            var copied = incomingTool
            copied.id = UUID()
            copied.createdAt = Date()
            copied.updatedAt = Date()
            copied.lastImportedAt = Date()
            local.append(copied)
            imported += 1
        }

        if imported > 0 {
            ShortcutToolStore.saveTools(local)
            Task { @MainActor in
                ShortcutToolManager.shared.reloadFromDisk()
            }
        }

        return (imported, skipped)
    }

}
