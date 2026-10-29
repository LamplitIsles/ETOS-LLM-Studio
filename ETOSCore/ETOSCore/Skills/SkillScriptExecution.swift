// ============================================================================
// SkillScriptExecution.swift
// ETOS LLM Studio
//
// 技能快照和本机进程使用的冻结文件包。
// ============================================================================

import CryptoKit
import Foundation

public enum SkillRunSnapshotBuilder {
    public static func build(skill: SkillMetadata) throws -> SkillRunSnapshot {
        guard SkillPaths.isValidSkillName(skill.name),
              let skillDirectory = SkillStore.resolveSkillDir(skillName: skill.name) else {
            throw SkillStoreError.invalidSkillName
        }
        let canonicalRoot = SkillStore.skillsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalSkill = skillDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(canonicalSkill, of: canonicalRoot),
              canonicalSkill.lastPathComponent == skill.name else {
            throw SkillExecutionError.invalidScriptPath
        }
        guard let files = SkillStore.readAllSkillFileData(skillName: skill.name), !files.isEmpty else {
            throw SkillStoreError.missingSkillFile
        }

        var scripts: [SkillScriptSnapshot] = []
        var scriptExecutability: [String: Bool] = [:]
        for relativePath in files.keys.sorted() {
            guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath),
                  normalized == relativePath,
                  let fileURL = SkillStore.resolveSkillFile(skillName: skill.name, relativePath: relativePath) else {
                throw SkillExecutionError.invalidScriptPath
            }
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw SkillExecutionError.invalidScriptPath
            }
            let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard isDescendant(canonicalFile, of: canonicalSkill) else {
                throw SkillExecutionError.invalidScriptPath
            }
            let data = files[relativePath]!
            let hash = sha256(data)
            if relativePath.hasPrefix("scripts/") {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let isExecutable = permissions & 0o111 != 0
                scriptExecutability[relativePath] = isExecutable
                scripts.append(
                    SkillScriptSnapshot(
                        relativePath: relativePath,
                        sha256: hash,
                        size: data.count,
                        isExecutable: isExecutable
                    )
                )
            }
        }
        return SkillRunSnapshot(
            skillID: skill.name,
            skillName: skill.name,
            versionDigest: versionDigest(files: files, scriptExecutability: scriptExecutability),
            allowedTools: skill.allowedTools,
            scripts: scripts.sorted { $0.relativePath < $1.relativePath },
            skillDescription: skill.description
        )
    }

    public static func buildEnabled(
        skillNames: Set<String>,
        skills: [SkillMetadata]
    ) -> [SkillRunSnapshot] {
        skills
            .filter { skillNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .compactMap { try? build(skill: $0) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionDigest(
        files: [String: Data],
        scriptExecutability: [String: Bool]
    ) -> String {
        var digestInput = Data()
        for relativePath in files.keys.sorted() {
            let data = files[relativePath]!
            digestInput.append(Data(relativePath.utf8))
            digestInput.append(0)
            digestInput.append(Data(String(data.count).utf8))
            digestInput.append(0)
            digestInput.append(Data(sha256(data).utf8))
            if let isExecutable = scriptExecutability[relativePath] {
                digestInput.append(0)
                digestInput.append(isExecutable ? 0x31 : 0x30)
            }
            digestInput.append(10)
        }
        return sha256(digestInput)
    }

    static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path == "/" ? "/" : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}

public actor SkillExecutionPackageStore {
    public static let shared = SkillExecutionPackageStore()

    private let fileManager = FileManager.default

    /// 物化目录由版本摘要命名且只创建一次。同一版本的并发执行共享同一只读挂载源。
    public func materialize(
        skillName: String,
        frozenSnapshot: SkillRunSnapshot
    ) throws -> URL {
        guard frozenSnapshot.skillName == skillName,
              frozenSnapshot.versionDigest.count == 64,
              frozenSnapshot.versionDigest.allSatisfy({ $0.isHexDigit }),
              let sourceFiles = SkillStore.readAllSkillFileData(skillName: skillName) else {
            throw SkillExecutionError.skillChanged
        }
        let executability = Dictionary(
            uniqueKeysWithValues: frozenSnapshot.scripts.map { ($0.relativePath, $0.isExecutable) }
        )
        guard SkillRunSnapshotBuilder.versionDigest(
            files: sourceFiles,
            scriptExecutability: executability
        ) == frozenSnapshot.versionDigest else {
            throw SkillExecutionError.skillChanged
        }

        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SkillExecutionPackages", isDirectory: true)
        let versionRoot = cacheRoot.appendingPathComponent(frozenSnapshot.versionDigest, isDirectory: true)
        let target = versionRoot.appendingPathComponent(skillName, isDirectory: true)
        let marker = versionRoot.appendingPathComponent(".etos-snapshot-\(skillName)", isDirectory: false)
        var targetIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &targetIsDirectory),
           targetIsDirectory.boolValue,
           (try? String(contentsOf: marker, encoding: .utf8)) == frozenSnapshot.versionDigest {
            return target
        }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let staging = cacheRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for relativePath in sourceFiles.keys.sorted() {
            guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath), normalized == relativePath else {
                throw SkillExecutionError.invalidScriptPath
            }
            let output = staging.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sourceFiles[relativePath]!.write(to: output, options: .atomic)
            let permissions = executability[relativePath] == true ? 0o555 : 0o444
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: output.path)
        }
        try fileManager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: staging, to: target)
        try frozenSnapshot.versionDigest.write(to: marker, atomically: true, encoding: .utf8)
        return target
    }
}

public enum SkillScriptResolver {
    static func requiresExecutablePermission(relativePath: String, data: Data) -> Bool {
        guard let normalized = SkillResourcePolicy.normalizeRelativePath(relativePath),
              normalized == relativePath,
              normalized.hasPrefix("scripts/"),
              normalized != "scripts/" else {
            return false
        }
        return shebangInterpreter(in: data) != nil
    }

    static func shebangInterpreter(in data: Data) -> String? {
        guard data.count >= 3,
              data[data.startIndex] == 0x23,
              data[data.startIndex + 1] == 0x21 else { return nil }
        let prefix = data.prefix(4_096)
        guard let line = String(data: prefix, encoding: .utf8)?.split(whereSeparator: \.isNewline).first else {
            return nil
        }
        let command = line.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, first.hasPrefix("/"), !first.contains("\0") else { return nil }
        if URL(fileURLWithPath: first).lastPathComponent == "env", parts.count >= 2 {
            return parts[1]
        }
        return first
    }

}
