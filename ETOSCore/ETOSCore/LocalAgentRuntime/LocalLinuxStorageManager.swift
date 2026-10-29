// ============================================================================
// LocalLinuxStorageManager.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux 系统、Home 与工作区保留在 Documents/Linux；Shared 与 Exports 进入
// App Group，供主 App、扩展和 Files 中的 File Provider 使用同一份内容。
// ============================================================================

import Foundation
import ZIPFoundation

public struct LocalLinuxStorageLayout: Equatable, Sendable {
    public let root: URL
    public let system: URL
    public let rootFS: URL
    public let rootFSData: URL
    public let diagnostics: URL
    public let home: URL
    public let shared: URL
    public let workspaces: URL
    public let exports: URL

    public init(
        documentsDirectory: URL,
        sharedDirectory: URL? = nil,
        exportsDirectory: URL? = nil
    ) {
        root = documentsDirectory.appendingPathComponent("Linux", isDirectory: true)
        system = root.appendingPathComponent("System", isDirectory: true)
        rootFS = system.appendingPathComponent("RootFS", isDirectory: true)
        rootFSData = rootFS.appendingPathComponent("data", isDirectory: true)
        diagnostics = system.appendingPathComponent("Diagnostics", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        shared = sharedDirectory ?? root.appendingPathComponent("Shared", isDirectory: true)
        workspaces = root.appendingPathComponent("Workspaces", isDirectory: true)
        exports = exportsDirectory ?? root.appendingPathComponent("Exports", isDirectory: true)
    }
}

public struct LocalLinuxStorageUsage: Equatable, Sendable {
    public let systemBytes: UInt64
    public let homeBytes: UInt64
    public let sharedBytes: UInt64
    public let workspaceBytes: UInt64
    public let exportBytes: UInt64

    public init(
        systemBytes: UInt64,
        homeBytes: UInt64,
        sharedBytes: UInt64,
        workspaceBytes: UInt64,
        exportBytes: UInt64
    ) {
        self.systemBytes = systemBytes
        self.homeBytes = homeBytes
        self.sharedBytes = sharedBytes
        self.workspaceBytes = workspaceBytes
        self.exportBytes = exportBytes
    }

    public var totalBytes: UInt64 {
        systemBytes + homeBytes + sharedBytes + workspaceBytes + exportBytes
    }
}

public struct LocalLinuxRawOutputCursor: Equatable, Hashable, Sendable {
    public let frameOffset: UInt64
    public let payloadOffset: UInt64

    public init(frameOffset: UInt64 = 0, payloadOffset: UInt64 = 0) {
        self.frameOffset = frameOffset
        self.payloadOffset = payloadOffset
    }
}

public struct LocalLinuxRawOutputPage: Equatable, Sendable {
    public let cursor: LocalLinuxRawOutputCursor
    public let text: String
    public let nextCursor: LocalLinuxRawOutputCursor?
    public let isComplete: Bool

    public init(
        cursor: LocalLinuxRawOutputCursor,
        text: String,
        nextCursor: LocalLinuxRawOutputCursor?,
        isComplete: Bool
    ) {
        self.cursor = cursor
        self.text = text
        self.nextCursor = nextCursor
        self.isComplete = isComplete
    }
}

public actor LocalLinuxStorageManager {
    public static let shared = LocalLinuxStorageManager()
    public static let interactiveUserWorkspaceID = UUID(
        uuidString: "7AC179AE-1BEA-444A-B311-C322954DA4A5"
    )!

    private static let receiptPrefix = "format=ish-rootfs-install-v1\nseed_archive_sha256="
    private let fileManager: FileManager
    private nonisolated let workspaceSizeRefresher: LocalLinuxWorkspaceSizeRefresher
    public nonisolated let layout: LocalLinuxStorageLayout

    public init(
        fileManager: FileManager = .default,
        documentsDirectory: URL = StorageUtility.documentsDirectory,
        appGroupLayout: ETOSSharedStorageLayout? = .resolve()
    ) {
        self.fileManager = fileManager
        workspaceSizeRefresher = LocalLinuxWorkspaceSizeRefresher(
            // 后台扫描自建 FileManager，避免跨隔离域捕获调用方可能带 delegate 的实例。
            measure: { directory in Self.directorySize(at: directory, fileManager: FileManager()) }
        )
        layout = LocalLinuxStorageLayout(
            documentsDirectory: documentsDirectory,
            sharedDirectory: appGroupLayout?.shared,
            exportsDirectory: appGroupLayout?.exports
        )
    }

    @discardableResult
    public func prepareLayout() throws -> LocalLinuxStorageLayout {
        for directory in [
            layout.root,
            layout.system,
            layout.diagnostics,
            layout.home,
            layout.shared,
            layout.workspaces,
            layout.exports
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var systemURL = layout.system
        try systemURL.setResourceValues(values)
        return layout
    }

    #if os(macOS)
    public func availableTerminalShellPaths() -> [String] {
        let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8)
        return LocalLinuxTerminalShellConfiguration.candidatePaths(shellsFileContents: contents)
            .filter { fileManager.isExecutableFile(atPath: $0) }
    }
    #endif

    private func executionWorkspacePath(_ relativePath: String) -> String {
        #if os(macOS)
        return layout.root.appendingPathComponent(relativePath, isDirectory: true).path
        #endif
    }

    public func workspace(sessionID: UUID, profileID: UUID? = nil) throws -> LocalAgentWorkspace {
        if var existing = Persistence.loadLocalAgentWorkspaces(sessionID: sessionID).first {
            let directory = layout.root.appendingPathComponent(existing.hostRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existing.guestPath = executionWorkspacePath(existing.hostRelativePath)
            existing.lastUsedAt = Date()
            _ = Persistence.saveLocalAgentWorkspace(existing)
            return existing
        }

        let id = UUID()
        let component = id.uuidString.lowercased()
        let relativePath = "Workspaces/\(component)"
        let directory = layout.root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = LocalAgentWorkspace(
            id: id,
            sessionID: sessionID,
            profileID: profileID,
            guestPath: executionWorkspacePath(relativePath),
            hostRelativePath: relativePath
        )
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 工作区。", comment: "Save Linux workspace failure")
            )
        }
        return workspace
    }

    /// 用户主动创建的终端与 recipe 属于设备上的 Linux 运行时，不归属于任何
    /// 聊天会话。多个用户 PTY 共用这个持久工作区，但各自拥有独立终端状态。
    public func interactiveUserWorkspace() throws -> LocalAgentWorkspace {
        if var existing = Persistence.loadLocalAgentWorkspaces().first(where: {
            $0.id == Self.interactiveUserWorkspaceID
        }) {
            let directory = layout.root.appendingPathComponent(existing.hostRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existing.guestPath = executionWorkspacePath(existing.hostRelativePath)
            existing.lastUsedAt = Date()
            guard Persistence.saveLocalAgentWorkspace(existing) else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("无法更新 Linux 工作区。", comment: "Update interactive user workspace failure")
                )
            }
            return existing
        }

        let relativePath = "Workspaces/UserTerminal"
        let directory = layout.root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = LocalAgentWorkspace(
            id: Self.interactiveUserWorkspaceID,
            sessionID: nil,
            profileID: nil,
            guestPath: executionWorkspacePath(relativePath),
            hostRelativePath: relativePath
        )
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 工作区。", comment: "Save interactive user workspace failure")
            )
        }
        return workspace
    }

    public func workspace(id: UUID) throws -> LocalAgentWorkspace {
        guard var workspace = Persistence.loadLocalAgentWorkspaces().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("找不到 Agent Run 对应的 Linux 工作区。", comment: "Missing local Agent workspace")
            )
        }
        let directory = layout.root.appendingPathComponent(workspace.hostRelativePath, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace.guestPath = executionWorkspacePath(workspace.hostRelativePath)
        workspace.lastUsedAt = Date()
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 工作区。", comment: "Update local Agent workspace failure")
            )
        }
        return workspace
    }

    public func workspaces() -> [LocalAgentWorkspace] {
        Persistence.loadLocalAgentWorkspaces().sorted { lhs, rhs in
            lhs.lastUsedAt > rhs.lastUsedAt
        }
    }

    public func localMCPWorkspace(serverID: UUID) throws -> LocalAgentWorkspace {
        if var existing = Persistence.loadLocalAgentWorkspaces().first(where: {
            $0.sessionID == nil && $0.profileID == serverID
        }) {
            let directory = layout.root.appendingPathComponent(existing.hostRelativePath, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            existing.guestPath = executionWorkspacePath(existing.hostRelativePath)
            existing.lastUsedAt = Date()
            _ = Persistence.saveLocalAgentWorkspace(existing)
            return existing
        }

        let component = "mcp-" + serverID.uuidString.lowercased()
        let relativePath = "Workspaces/\(component)"
        try fileManager.createDirectory(
            at: layout.root.appendingPathComponent(relativePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        let workspace = LocalAgentWorkspace(
            sessionID: nil,
            profileID: serverID,
            guestPath: executionWorkspacePath(relativePath),
            hostRelativePath: relativePath
        )
        guard Persistence.saveLocalAgentWorkspace(workspace) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 工作区。", comment: "Save local MCP workspace failure")
            )
        }
        return workspace
    }

    public nonisolated func hostURL(for workspace: LocalAgentWorkspace) throws -> URL {
        let candidate = layout.root.appendingPathComponent(workspace.hostRelativePath, isDirectory: true)
        return try checkedDescendant(candidate, of: layout.workspaces)
    }

    public func browserDownloadDirectory(for workspace: LocalAgentWorkspace) throws -> URL {
        let directory = try hostURL(for: workspace)
            .appendingPathComponent("BrowserDownloads", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func guestURI(forHostURL url: URL, workspace: LocalAgentWorkspace) throws -> String {
        let workspaceURL = try hostURL(for: workspace)
        let resolved = try checkedDescendant(url, of: workspaceURL)
        let relativePath = String(resolved.path.dropFirst(workspaceURL.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        #if os(macOS)
        let workspacePath = layout.root.lastPathComponent + "/" + workspace.hostRelativePath
        return "app://" + workspacePath + (relativePath.isEmpty ? "" : "/" + relativePath)
        #endif
    }

    public func outputURLs(jobID: UUID, workspace: LocalAgentWorkspace) throws -> (raw: URL, model: URL) {
        let workspaceURL = try hostURL(for: workspace)
        let outputDirectory = workspaceURL
            .appendingPathComponent(".etos", isDirectory: true)
            .appendingPathComponent("Outputs", isDirectory: true)
            .appendingPathComponent(jobID.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return (
            outputDirectory.appendingPathComponent("raw.log", isDirectory: false),
            outputDirectory.appendingPathComponent("model.log", isDirectory: false)
        )
    }

    public func relativePath(for url: URL) throws -> String {
        let resolved = try checkedDescendant(url, of: layout.root)
        return String(resolved.path.dropFirst(layout.root.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func readOutput(relativePath: String, maximumBytes: Int) throws -> String {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(1, maximumBytes)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        let visible = data.prefix(limit)
        var text = String(decoding: visible, as: UTF8.self)
        if data.count > limit {
            text.append(NSLocalizedString(
                "\n[输出已截断，完整内容保存在工作区附件中。]",
                comment: "Linux output read truncation notice"
            ))
        }
        return text
    }

    public func readRawOutput(relativePath: String, maximumBytes: Int) throws -> String {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = max(1, maximumBytes)
        var pending = Data()
        var preview = Data()
        var lastMarker: UInt8?

        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            pending.append(chunk)
            while pending.count >= 5 {
                let marker = pending[pending.startIndex]
                guard marker == 1 || marker == 2 || marker == 3 else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                    )
                }
                let length = pending[pending.startIndex + 1 ..< pending.startIndex + 5]
                    .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length <= 16 * 1_024 * 1_024 else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                    )
                }
                let frameLength = 5 + Int(length)
                guard pending.count >= frameLength else { break }
                if marker != 3, marker != lastMarker {
                    preview.append(contentsOf: (marker == 1 ? "\n[stdout]\n" : "\n[stderr]\n").utf8)
                }
                preview.append(pending[pending.startIndex + 5 ..< pending.startIndex + frameLength])
                pending.removeFirst(frameLength)
                lastMarker = marker
                if preview.count > limit {
                    preview.removeFirst(preview.count - limit)
                }
            }
        }
        return String(decoding: preview, as: UTF8.self)
    }

    /// 按原始帧位置分页，既不会为找页码解析整份日志，也不会在跨页时丢掉超大帧的尾部。
    public func readRawOutputPage(
        relativePath: String,
        cursor: LocalLinuxRawOutputCursor,
        maximumBytes: Int
    ) throws -> LocalLinuxRawOutputPage {
        let candidate = layout.root.appendingPathComponent(relativePath, isDirectory: false)
        let url = try checkedDescendant(candidate, of: layout.root)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        // stdout/stderr 标签本身也属于页面内容；保留一个最小页宽，避免游标
        // 只写标签却无法推进 payload，导致极小分页参数反复返回同一页。
        let limit = max(16, maximumBytes)
        var frameOffset = cursor.frameOffset
        var payloadOffset = cursor.payloadOffset
        var page = Data()
        var nextCursor: LocalLinuxRawOutputCursor?
        var reachedIncompleteFrame = false

        while page.count < limit, frameOffset < fileSize {
            try handle.seek(toOffset: frameOffset)
            guard let header = try handle.read(upToCount: 5), header.count == 5 else {
                reachedIncompleteFrame = true
                break
            }
            let marker = header[header.startIndex]
            guard marker == 1 || marker == 2 || marker == 3 else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                )
            }
            let payloadLength = header[header.startIndex + 1 ..< header.startIndex + 5]
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard payloadLength <= 16 * 1_024 * 1_024, payloadOffset <= payloadLength else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 原始输出帧已损坏。", comment: "Corrupted Linux raw output frame")
                )
            }

            let frameEnd = frameOffset + 5 + payloadLength
            guard frameEnd <= fileSize else {
                reachedIncompleteFrame = true
                break
            }

            if payloadOffset == 0, marker != 3 {
                page.append(contentsOf: (marker == 1 ? "\n[stdout]\n" : "\n[stderr]\n").utf8)
            }
            let remainingPayload = payloadLength - payloadOffset
            let availablePageBytes = max(0, limit - page.count)
            let readCount = min(remainingPayload, UInt64(availablePageBytes))
            if readCount > 0 {
                try handle.seek(toOffset: frameOffset + 5 + payloadOffset)
                if let data = try handle.read(upToCount: Int(readCount)) {
                    page.append(data)
                    payloadOffset += UInt64(data.count)
                }
            }

            if payloadOffset < payloadLength {
                nextCursor = LocalLinuxRawOutputCursor(
                    frameOffset: frameOffset,
                    payloadOffset: payloadOffset
                )
                break
            }

            frameOffset = frameEnd
            payloadOffset = 0
            if page.count >= limit, frameOffset < fileSize {
                nextCursor = LocalLinuxRawOutputCursor(frameOffset: frameOffset)
            }
        }

        let complete = !reachedIncompleteFrame && nextCursor == nil && frameOffset >= fileSize
        return LocalLinuxRawOutputPage(
            cursor: cursor,
            text: String(decoding: page, as: UTF8.self),
            nextCursor: nextCursor,
            isComplete: complete
        )
    }

    nonisolated func scheduleWorkspaceSizeRefresh(_ workspace: LocalAgentWorkspace) async {
        // Shell/PTY 即使失败也可能已经写入 Shared；同步不依赖工作区统计能否落库。
        ETOSSharedWorkspaceFiles.notifyChange()
        guard let directory = try? hostURL(for: workspace),
              let persist = Persistence.makeLocalAgentWorkspaceSizeWriter() else { return }
        await workspaceSizeRefresher.schedule(workspace, directory: directory, persist: persist)
    }

    public func waitForWorkspaceSizeRefreshes() async {
        await workspaceSizeRefresher.waitForIdle()
    }

    public func refreshWorkspaceSize(_ workspace: LocalAgentWorkspace) async throws -> LocalAgentWorkspace {
        guard let persist = Persistence.makeLocalAgentWorkspaceSizeWriter() else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 工作区统计。", comment: "更新 Linux 工作区统计失败")
            )
        }
        var updated = workspace
        updated.sizeBytes = try await workspaceSizeRefresher.refresh(
            workspace, directory: hostURL(for: workspace), persist: persist
        )
        return updated
    }

    public func exportWorkspace(_ workspace: LocalAgentWorkspace) throws -> URL {
        let source = try hostURL(for: workspace)
        guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LocalLinuxRuntimeError.invalidPath(workspace.guestPath)
        }
        try fileManager.createDirectory(at: layout.exports, withIntermediateDirectories: true)
        let archiveURL = uniqueExportURL(baseName: "Linux-Workspace-\(workspace.id.uuidString)")
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: archiveURL) } }
        let archive = try Archive(url: archiveURL, accessMode: .create)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory != true else { continue }
            let relativePath = String(item.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            try archive.addEntry(with: relativePath, fileURL: item, compressionMethod: .deflate)
        }
        if let enumerationError { throw enumerationError }
        try Task.checkCancellation()
        completed = true
        ETOSSharedWorkspaceFiles.notifyChange()
        return archiveURL
    }

    public func deleteWorkspace(_ workspace: LocalAgentWorkspace) async throws {
        try await LocalLinuxJobScheduler.shared.cancelAndWaitForJobs(workspaceID: workspace.id)
        try Task.checkCancellation()
        // 等待任务时 actor 可以接纳新请求；旧确认不能删除期间重建的同 ID 用户终端工作区。
        guard let current = Persistence.loadLocalAgentWorkspaces().first(where: { $0.id == workspace.id }),
              current.createdAt == workspace.createdAt, current.hostRelativePath == workspace.hostRelativePath else {
            throw LocalLinuxRuntimeError.invalidPath(workspace.guestPath)
        }
        guard !Persistence.loadLocalLinuxJobs(activeOnly: true).contains(where: { $0.workspaceID == workspace.id }) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(NSLocalizedString("工作区仍有任务运行，请稍后重试。", comment: ""))
        }
        let url = try hostURL(for: workspace)
        try Self.removeWorkspaceDirectory(url, fileManager: fileManager) {
            guard Persistence.deleteLocalAgentWorkspace(id: workspace.id) else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("无法删除 Linux 工作区记录。", comment: "Delete Linux workspace record failure")
                )
            }
        }
    }

    /// 先暂存原目录；数据库删除失败时恢复文件，不能留下有记录却已丢失数据的工作区。
    static func removeWorkspaceDirectory(_ url: URL, fileManager: FileManager, deleteRecord: () throws -> Void) throws {
        let backup = url.deletingLastPathComponent().appendingPathComponent(".deleting-\(UUID().uuidString)", isDirectory: true)
        let existed = fileManager.fileExists(atPath: url.path)
        if existed { try fileManager.moveItem(at: url, to: backup) }
        do { try deleteRecord() }
        catch {
            if existed { try fileManager.moveItem(at: backup, to: url) }
            throw error
        }
        if existed { try fileManager.removeItem(at: backup) }
    }

    /// 迁移只推进安装收据代表的基线版本，不覆盖用户自行安装的软件包或配置。
    public func recordInstalledSeedSHA256(_ seedSHA256: String) throws {
        guard seedSHA256.count == 64, seedSHA256.allSatisfy(\.isHexDigit) else {
            throw LocalLinuxRuntimeError.invalidSeedMetadata("migration.targetSeedSHA256")
        }
        let receiptURL = layout.rootFS.appendingPathComponent("rootfs-installation.txt", isDirectory: false)
        guard fileManager.fileExists(atPath: receiptURL.path) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("RootFS 缺少安装收据，无法记录系统更新。", comment: "Missing RootFS receipt during migration")
            )
        }
        let receipt = Self.receiptPrefix + seedSHA256.lowercased() + "\n"
        try Data(receipt.utf8).write(to: receiptURL, options: .atomic)
    }

    public func storageUsage() -> LocalLinuxStorageUsage {
        LocalLinuxStorageUsage(
            systemBytes: directorySize(at: layout.system),
            homeBytes: directorySize(at: layout.home),
            sharedBytes: directorySize(at: layout.shared),
            workspaceBytes: directorySize(at: layout.workspaces),
            exportBytes: directorySize(at: layout.exports)
        )
    }

    private nonisolated func checkedDescendant(_ candidate: URL, of parent: URL) throws -> URL {
        let resolvedCandidate = candidate.standardizedFileURL
        let resolvedParent = parent.standardizedFileURL
        let prefix = resolvedParent.path.hasSuffix("/") ? resolvedParent.path : resolvedParent.path + "/"
        guard resolvedCandidate.path.hasPrefix(prefix) else {
            throw LocalLinuxRuntimeError.invalidPath(candidate.path)
        }
        return resolvedCandidate
    }

    private func directorySize(at directory: URL) -> UInt64 {
        Self.directorySize(at: directory, fileManager: fileManager)
    }

    private nonisolated static func directorySize(at directory: URL, fileManager: FileManager) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: UInt64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
        }
        return total
    }

    private func uniqueExportURL(baseName: String) -> URL {
        var candidate = layout.exports.appendingPathComponent(baseName).appendingPathExtension("zip")
        if fileManager.fileExists(atPath: candidate.path) {
            candidate = layout.exports
                .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
                .appendingPathExtension("zip")
        }
        return candidate
    }
}
