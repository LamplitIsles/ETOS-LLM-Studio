// ============================================================================
// LocalLinuxMountManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 宿主路径仅在这里解析。桥接层只接收已打开的目录 fd；security scope 在
// mount 存续期间保持，guest 与诊断始终只看到稳定 UUID 和 /mnt 路径。
// ============================================================================

import Darwin
import Foundation

public final class LocalLinuxDirectoryAccess: @unchecked Sendable {
    public let url: URL
    private let securityScopedURL: URL
    private let shouldStop: Bool

    fileprivate init(url: URL, securityScopedURL: URL, shouldStop: Bool) {
        self.url = url
        self.securityScopedURL = securityScopedURL
        self.shouldStop = shouldStop
    }

    deinit {
        if shouldStop { securityScopedURL.stopAccessingSecurityScopedResource() }
    }
}

public actor LocalLinuxMountManager {
    public static let shared = LocalLinuxMountManager()

    public static let homeMountID = UUID(uuidString: "4203E597-D916-424B-B584-1569682C9A4C")!
    public static let workspaceMountID = UUID(uuidString: "B0081364-EF17-4F76-9EA8-3FA3BEC990A2")!
    public static let sharedMountID = UUID(uuidString: "D76E20A8-628B-4C6A-AD29-7F3D7DF1DF1E")!
    public static let iCloudMountID = UUID(uuidString: "62046572-CAD6-4F86-BF4F-4B83C36A43BB")!
    public static let homeMountGuestPath = "/mnt/home"
    public static let workspaceMountGuestPath = "/mnt/workspaces"
    public static let sharedMountGuestPath = "/mnt/shared"
    public static let iCloudGuestPath = "/mnt/icloud"
    public static let appMountsDirectoryName = "ETOSMounts"
    public static let appMountsDisplayPath = "Documents/ETOSMounts"

    public static func appMountDisplayPath(id: UUID) -> String {
        "\(appMountsDisplayPath)/\(id.uuidString.lowercased())"
    }

    public static func appMountURI(id: UUID) -> String {
        "app://\(appMountsDirectoryName)/\(id.uuidString.lowercased())"
    }

    private let resolveBookmark: @Sendable (Data) throws -> (url: URL, isStale: Bool)
    private var mutatingMountIDs: Set<UUID> = []

    public init() {
        resolveBookmark = { try LocalLinuxExternalDirectory.resolveBookmark($0) }
    }

    public func records() -> [LocalLinuxMountRecord] {
        Persistence.loadLocalLinuxMounts()
    }

    /// 为宿主界面保留一次安全作用域访问，调用方应在文件浏览界面存续期间持有返回值。
    public func accessExternalDirectory(id: UUID) throws -> LocalLinuxDirectoryAccess {
        guard let record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        let resource = try prepareExternalDirectory(record)
        persistAuthorizationState(record, state: .available)
        return resource
    }

    public func addExternalDirectory(
        _ url: URL,
        displayName: String,
        access: LocalLinuxMountAccess
    ) async throws -> LocalLinuxMountRecord {
        let bookmark = try LocalLinuxExternalDirectory.createBookmark(for: url)
        let id = UUID()
        let record = LocalLinuxMountRecord(
            id: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? url.lastPathComponent
                : displayName,
            bookmark: bookmark,
            access: access,
            guestPath: "/mnt/etos/\(id.uuidString.lowercased())"
        )
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 挂载。", comment: "Save Linux mount failure")
            )
        }
        return record
    }

    public func update(_ record: LocalLinuxMountRecord) throws {
        try beginMutation(id: record.id)
        defer { mutatingMountIDs.remove(record.id) }
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 挂载。", comment: "Update Linux mount failure")
            )
        }
    }

    public func reauthorize(
        id: UUID,
        with url: URL,
        access: LocalLinuxMountAccess,
        expected: LocalLinuxMountRecord? = nil
    ) async throws -> LocalLinuxMountRecord {
        try beginMutation(id: id)
        defer { mutatingMountIDs.remove(id) }
        guard var record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        try validateExpected(expected, current: record)
        record.bookmark = try LocalLinuxExternalDirectory.createBookmark(for: url)
        record.displayName = url.lastPathComponent
        record.access = access
        record.authorizationState = .available
        record.updatedAt = Date()

        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存重新授权的 Linux 挂载。", comment: "Save reauthorized Linux mount failure")
            )
        }
        return records().first(where: { $0.id == id }) ?? record
    }

    public func setEnabled(_ isEnabled: Bool, id: UUID, expected: LocalLinuxMountRecord? = nil) async throws -> LocalLinuxMountRecord {
        try beginMutation(id: id)
        defer { mutatingMountIDs.remove(id) }
        guard var record = records().first(where: { $0.id == id }) else {
            throw LocalLinuxRuntimeError.invalidPath(id.uuidString)
        }
        try validateExpected(expected, current: record)
        guard record.isEnabled != isEnabled else { return record }
        record.isEnabled = isEnabled
        record.updatedAt = Date()
        guard Persistence.saveLocalLinuxMount(record) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 挂载状态。", comment: "Update Linux mount enabled state failure")
            )
        }
        return records().first(where: { $0.id == id }) ?? record
    }

    public func delete(id: UUID, expected: LocalLinuxMountRecord? = nil) async throws {
        try beginMutation(id: id)
        defer { mutatingMountIDs.remove(id) }
        if let expected { try validateExpected(expected, current: records().first { $0.id == id }) }
        guard Persistence.deleteLocalLinuxMount(id: id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除 Linux 挂载。", comment: "Delete Linux mount failure")
            )
        }
    }

    private func validateExpected(_ expected: LocalLinuxMountRecord?, current: LocalLinuxMountRecord?) throws {
        guard let expected else { return }
        guard current?.matchesConfiguration(expected) == true else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(NSLocalizedString("挂载配置已变化，请刷新后重试。", comment: ""))
        }
    }

    private func prepareExternalDirectory(
        _ record: LocalLinuxMountRecord,
        persistState: Bool = true
    ) throws -> LocalLinuxDirectoryAccess {
        guard let bookmark = record.bookmark else {
            if persistState { persistAuthorizationState(record, state: .needsReauthorization) }
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("挂载缺少文件访问授权。", comment: "Linux mount bookmark missing error")
            )
        }
        let resolved: (url: URL, isStale: Bool)
        do {
            resolved = try resolveBookmark(bookmark)
        } catch {
            // 重装后的书签可能直接抛错，而不是返回 stale；同样不能沿用快照中的 available。
            if persistState { persistAuthorizationState(record, state: .needsReauthorization) }
            LocalLinuxExternalDirectory.recordFailure("恢复目录授权", error: error)
            throw error
        }
        let url = resolved.url
        let shouldStop = url.startAccessingSecurityScopedResource()
        if persistState { persistAuthorizationState(record, state: .materializing) }
        do {
            let directoryURL = try LocalLinuxExternalDirectory.coordinateRead(at: url) { $0 }
            if resolved.isStale, persistState {
                // stale 表示书签元数据需要更新，不等于系统撤销授权。先确认目录可访问，
                // 再保存新书签，保留原挂载身份、权限与并发变化的租约计数。
                let refreshed = try LocalLinuxExternalDirectory.createBookmark(for: directoryURL)
                guard Persistence.refreshLocalLinuxMountBookmark(id: record.id, replacing: bookmark, with: refreshed) else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("无法保存重新授权的 Linux 挂载。", comment: "Save reauthorized Linux mount failure")
                    )
                }
            }
            // 文件提供者可能在协调期间更新目录位置；使用新 URL，释放时仍配对原授权 URL。
            return LocalLinuxDirectoryAccess(
                url: directoryURL,
                securityScopedURL: url,
                shouldStop: shouldStop
            )
        } catch {
            if shouldStop { url.stopAccessingSecurityScopedResource() }
            if persistState { persistAuthorizationState(record, state: .unavailable) }
            LocalLinuxExternalDirectory.recordFailure("准备目录", error: error, didStartAccess: shouldStop)
            #if os(macOS)
            let message = NSLocalizedString(
                "外部目录尚未在本机准备好。请先在 Finder 中打开该目录，等待 iCloud 或文件提供者下载完成后重试。",
                comment: "Mac 外部目录尚未准备好"
            )
            #else
            let message = NSLocalizedString(
                "外部目录尚未在本机准备好。请先在“文件”App 中打开该目录，等待 iCloud 或文件提供者下载完成后重试。",
                comment: "Linux mount File Provider materialization error"
            )
            #endif
            throw LocalLinuxRuntimeError.runtimeUnavailable(message)
        }
    }

    private func persistAuthorizationState(
        _ record: LocalLinuxMountRecord,
        state: LocalLinuxMountAuthorizationState
    ) {
        _ = Persistence.updateLocalLinuxMountAuthorizationState(id: record.id, state: state)
    }

    private func beginMutation(id: UUID) throws {
        // actor 在调用桥接层的 await 处可重入；同一记录的切换与删除不能交错提交。
        guard mutatingMountIDs.insert(id).inserted else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法更新 Linux 挂载。", comment: "Update Linux mount failure")
            )
        }
    }

}
