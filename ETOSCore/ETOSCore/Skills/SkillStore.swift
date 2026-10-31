// ============================================================================
// SkillStore.swift
// ============================================================================
// Agent Skills 持久化存储
// - 目录级技能文件读写（每个技能一个目录）
// - 原子替换保存
// - 文件索引与正文读取
// - 同步导入/导出辅助
// ============================================================================

import Foundation
import os.log

private let skillStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SkillStore")

public enum SkillStore {
    public static let directoryName = "Skills"
    public static let defaultSkillFileName = "SKILL.md"

    public static var builtInSkillNames: [String] {
        builtInSkillSeeds.map(\.name)
    }

    private static var documentsDirectory: URL {
        StorageUtility.documentsDirectory
    }

    public static var skillsDirectory: URL {
        documentsDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        let dir = skillsDirectory
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                skillStoreLogger.info("Skills 目录已创建: \(dir.path, privacy: .public)")
            } catch {
                skillStoreLogger.error("创建 Skills 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return dir
    }

    @discardableResult
    public static func installBuiltInSkillsIfNeeded() -> [String] {
        var installedNames: [String] = []
        for seed in builtInSkillSeeds {
            guard !skillExists(seed.name) else { continue }
            if saveSkillDataFilesAtomically(skillName: seed.name, files: seed.files) {
                installedNames.append(seed.name)
            }
        }
        return installedNames
    }

    public static func listSkills() -> [SkillMetadata] {
        let root = setupDirectoryIfNeeded()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let skills = dirs.compactMap { dir -> SkillMetadata? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let skillFile = dir.appendingPathComponent(defaultSkillFileName, isDirectory: false)
            guard fm.fileExists(atPath: skillFile.path) else { return nil }
            return parseMetadata(from: skillFile)
        }
        return skills.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func listSkillFiles(skillName: String) -> [SkillFileReference] {
        guard let skillDir = resolveSkillDir(skillName: skillName),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return []
        }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: skillDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SkillFileReference] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isDirectory != true else {
                continue
            }
            guard let relativePath = SkillPaths.relativePath(for: fileURL, baseURL: skillDir) else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            let readability = textReadability(fileURL: fileURL, relativePath: relativePath, size: size)
            files.append(
                SkillFileReference(
                    relativePath: relativePath,
                    size: size,
                    modificationDate: values.contentModificationDate,
                    isReadableText: readability.isReadable,
                    readOnlyReason: readability.reason
                )
            )
        }

        return files.sorted { lhs, rhs in
            if lhs.relativePath == defaultSkillFileName { return true }
            if rhs.relativePath == defaultSkillFileName { return false }
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
    }

    public static func saveSkillDataFilesAtomically(skillName: String, files: [String: Data]) -> Bool {
        let root = setupDirectoryIfNeeded()
        guard let targetDir = SkillPaths.resolveSkillDir(skillsRoot: root, skillName: skillName) else {
            return false
        }
        guard files.keys.contains(defaultSkillFileName) else { return false }
        guard let skillFileData = files[defaultSkillFileName],
              String(data: skillFileData, encoding: .utf8) != nil else {
            return false
        }

        let fm = FileManager.default
        guard let stagingDir = createTempSkillDir(root: root, skillName: skillName, suffix: "staging") else {
            return false
        }
        var backupDir: URL?

        defer {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
            if let backupDir, fm.fileExists(atPath: backupDir.path), fm.fileExists(atPath: targetDir.path) {
                try? fm.removeItem(at: backupDir)
            }
        }

        do {
            for (relativePath, data) in files {
                guard let target = SkillPaths.resolveSkillFile(skillDir: stagingDir, relativePath: relativePath) else {
                    return false
                }
                try target.deletingLastPathComponent().createDirectoryIfNeeded()
                try data.write(to: target, options: .atomic)
                try applySupportedScriptPermissions(
                    relativePath: relativePath,
                    data: data,
                    fileURL: target,
                    fileManager: fm
                )
            }

            let stagingSkillFile = stagingDir.appendingPathComponent(defaultSkillFileName, isDirectory: false)
            guard fm.fileExists(atPath: stagingSkillFile.path) else { return false }

            if fm.fileExists(atPath: targetDir.path) {
                guard let backup = createTempSkillDir(root: root, skillName: skillName, suffix: "backup") else {
                    return false
                }
                backupDir = backup
                try fm.removeItem(at: backup)
                try fm.moveItem(at: targetDir, to: backup)
            }

            do {
                try fm.moveItem(at: stagingDir, to: targetDir)
            } catch {
                if let backupDir, !fm.fileExists(atPath: targetDir.path) {
                    try? fm.moveItem(at: backupDir, to: targetDir)
                }
                throw error
            }

            if let backupDir, fm.fileExists(atPath: backupDir.path) {
                try? fm.removeItem(at: backupDir)
            }
            return true
        } catch {
            skillStoreLogger.error("原子保存技能失败 \(skillName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func skillExists(_ skillName: String) -> Bool {
        guard let skillDir = resolveSkillDir(skillName: skillName) else { return false }
        return FileManager.default.fileExists(atPath: skillDir.path)
    }

    public static func resolveSkillDir(skillName: String) -> URL? {
        let root = setupDirectoryIfNeeded()
        return SkillPaths.resolveSkillDir(skillsRoot: root, skillName: skillName)
    }

    public static func resolveSkillFile(skillName: String, relativePath: String) -> URL? {
        guard let skillDir = resolveSkillDir(skillName: skillName) else { return nil }
        return SkillPaths.resolveSkillFile(skillDir: skillDir, relativePath: relativePath)
    }

    /// 导入过程会重新创建文件，因此宿主包里的 POSIX mode 无法自然保留。这里只为
    /// ETOS 能直接执行的 shebang 与 AArch64 ELF 恢复执行位；普通资源始终保持不可执行。
    private static func applySupportedScriptPermissions(
        relativePath: String,
        data: Data,
        fileURL: URL,
        fileManager: FileManager
    ) throws {
        guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath),
              normalized == relativePath,
              normalized.hasPrefix("scripts/"),
              normalized != "scripts/" else { return }
        let permissions = SkillScriptResolver.requiresExecutablePermission(
            relativePath: relativePath,
            data: data
        ) ? 0o755 : 0o644
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
    }

    public static func readAllSkillFileData(skillName: String) -> [String: Data]? {
        guard let skillDir = resolveSkillDir(skillName: skillName),
              FileManager.default.fileExists(atPath: skillDir.path) else {
            return nil
        }
        let fileRefs = listSkillFiles(skillName: skillName)
        var files: [String: Data] = [:]
        for fileRef in fileRefs {
            guard let fileURL = SkillPaths.resolveSkillFile(skillDir: skillDir, relativePath: fileRef.relativePath),
                  let data = try? Data(contentsOf: fileURL) else {
                return nil
            }
            files[fileRef.relativePath] = data
        }
        return files
    }

    static func builtInSkillContentForTests(name: String) -> String? {
        builtInSkillSeeds.first { $0.name == name }?.content
    }

    private static func parseMetadata(from skillFile: URL) -> SkillMetadata? {
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let fallbackName = skillFile.deletingLastPathComponent().lastPathComponent
        guard let manifest = try? SkillManifestResolver.resolve(content: content, fallbackName: fallbackName) else {
            return nil
        }

        let updateTime = ((try? skillFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? Date()
        return SkillMetadata(
            name: manifest.name,
            description: manifest.description,
            compatibility: manifest.compatibility,
            allowedTools: manifest.allowedTools,
            updatedAt: updateTime
        )
    }

    private static func textReadability(fileURL: URL, relativePath: String, size: Int64) -> (isReadable: Bool, reason: String?) {
        let candidate = SkillResourcePolicy.candidateTextReadability(relativePath: relativePath, size: size)
        guard candidate.canAttemptRead else {
            if SkillResourcePolicy.normalizeRelativePath(relativePath) != nil,
               SkillResourcePolicy.isKnownTextPath(relativePath),
               size > SkillResourcePolicy.maxReadableTextBytes {
                return (true, NSLocalizedString("可分块读取", comment: "Skill resource chunk-readable marker"))
            }
            return (false, candidate.reason)
        }
        if SkillResourcePolicy.isKnownTextPath(relativePath) {
            return (true, nil)
        }
        if SkillResourcePolicy.isExtractableDocumentPath(relativePath) {
            return (true, nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return (false, NSLocalizedString("无法读取文件", comment: "Skill resource unreadable reason"))
        }
        if SkillResourcePolicy.isOCRImagePath(relativePath) {
            return isRecognizableImageData(data, relativePath: relativePath)
                ? (true, nil)
                : (false, NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
        }
        return canExtractSkillPlainText(data: data, relativePath: relativePath)
            ? (true, nil)
            : (false, NSLocalizedString("非 UTF-8 文本资源，仅列出不读取", comment: "Skill resource unreadable reason"))
    }

    private static func canExtractSkillPlainText(data: Data, relativePath: String) -> Bool {
        (try? FileAttachmentTextExtractor().extractText(from: makeAttachment(data: data, relativePath: relativePath))) != nil
    }

    private static func makeAttachment(data: Data, relativePath: String) -> FileAttachment {
        FileAttachment(
            data: data,
            mimeType: resolvedMimeType(for: relativePath),
            fileName: URL(fileURLWithPath: relativePath).lastPathComponent
        )
    }

    private static func resolvedMimeType(for relativePath: String) -> String {
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }

    private static func createTempSkillDir(root: URL, skillName: String, suffix: String) -> URL? {
        let fm = FileManager.default
        for attempt in 0..<100 {
            let candidate = root.appendingPathComponent(".\(skillName).\(suffix).\(attempt).tmp", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) {
                do {
                    try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                    return candidate
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private static func isRecognizableImageData(_ data: Data, relativePath: String) -> Bool {
        guard SkillResourcePolicy.isOCRImagePath(relativePath) else { return false }
        let bytes = Array(data.prefix(64))
        return hasPrefix([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], in: bytes)
            || hasPrefix([0xFF, 0xD8, 0xFF], in: bytes)
            || hasPrefix(Array("GIF87a".utf8), in: bytes)
            || hasPrefix(Array("GIF89a".utf8), in: bytes)
            || hasPrefix(Array("BM".utf8), in: bytes)
            || hasPrefix(Array("II*\0".utf8), in: bytes)
            || hasPrefix(Array("MM\0*".utf8), in: bytes)
            || isRecognizableWebP(bytes)
            || hasRecognizableISOImageBrand(bytes)
    }

    private static func hasPrefix(_ prefix: [UInt8], in bytes: [UInt8]) -> Bool {
        bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
    }

    private static func isRecognizableWebP(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 12
            && asciiString(bytes[0..<4]) == "RIFF"
            && asciiString(bytes[8..<12]) == "WEBP"
    }

    private static func hasRecognizableISOImageBrand(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12, asciiString(bytes[4..<8]) == "ftyp" else {
            return false
        }
        let imageBrands: Set<String> = [
            "avif",
            "heic",
            "heix",
            "hevc",
            "hevx",
            "heis",
            "hevm",
            "hevs",
            "mif1",
            "msf1"
        ]
        for start in stride(from: 8, through: bytes.count - 4, by: 4) {
            let brand = asciiString(bytes[start..<start + 4])
            if imageBrands.contains(brand) {
                return true
            }
        }
        return false
    }

    private static func asciiString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

private struct BuiltInSkillSeed {
    let name: String
    let content: String

    var files: [String: Data] {
        [SkillStore.defaultSkillFileName: Data(content.utf8)]
    }
}

private let builtInSkillSeeds: [BuiltInSkillSeed] = [
    BuiltInSkillSeed(
        name: "create-skill",
        content: #"""
        ---
        name: create-skill
        description: Extract workflows and create reusable Agent Skills for ETOS LLM Studio (ELS). Trigger this when the user asks to create a skill, package a workflow, or save the current logic as a skill.
        allowed-tools:
          - app_create_sandbox_directory
          - app_write_sandbox_file
        ---

        # ELS Skill Creator Guide
        You are an advanced skill-building agent within the ELS framework. Your task is to extract user requirements, complex workflows, or specific interaction logic, package them into a standardized skill file, and save them to the local file system.

        ## 1. Extract
        - Carefully review the current conversation history. If the user has been following a multi-step workflow, debugging methodology, or specific standards, distill these into reusable skill components.
        - Key elements to extract: step-by-step execution processes, decision points, and final quality check criteria.

        ## 2. Clarify if Needed
        - If a clear workflow cannot be derived from the conversation, or if the user only provides a vague concept, you must ask questions to clarify.
        - Directions for clarification include, but are not limited to: What is the expected final output of this skill? Is it a simple checklist or a complex multi-step reasoning flow? What is the expected interaction style?
        - Do not call tools to generate files until the requirements are completely clear.

        ## 3. Drafting
        - The skill directory name (`skill-name`) must contain only lowercase letters and hyphens.
        - The top of the file MUST contain YAML metadata wrapped in `---`.
          ```yaml
          ---
          name: [skill-name]
          description: [Detailed explanation of the skill's use case and trigger conditions to improve intent recognition recall]
          ---
          ```
        - Below the YAML header, write the Markdown body of the skill, ensuring the content allows other Agents to accurately understand and execute the task.

        ## 4. Execution (Tool Permission Check)
        Before attempting to generate and write the skill file, you must first check your available tools.
        - Pre-check: Verify if you have the `app_create_sandbox_directory` and `app_write_sandbox_file` tools.
        - Missing Permissions: If these tools are unavailable or not displayed, you must immediately abort the creation process and inform the user: "To automatically package and write the skill, please first enable the built-in file/sandbox operation tools in ELS Settings."
        - Execute Writing: If the tools are available, strictly follow these steps to call them:
          1. Call `app_create_sandbox_directory` to create the directory `Skills/<skill-name>`.
          2. Call `app_write_sandbox_file` to write the complete skill content into `Skills/<skill-name>/SKILL.md`.

        ## 5. Delivery
        - Upon successful writing, briefly summarize the core function of the skill to the user, and provide 1-2 example prompts that can directly trigger this skill.
        - Important Reminder: Inform the user that the newly created skill is saved but disabled by default. They need to go to ELS Settings and manually enable it for the system to recognize and trigger it. No restart is required.
        """#
    )
]

private extension URL {
    func createDirectoryIfNeeded() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(at: self, withIntermediateDirectories: true)
        }
    }
}
