// ============================================================================
// LocalLinuxRuntimeController.swift
// ============================================================================
// ETOS LLM Studio
//
// 协调本机进程的准备、作业状态与宿主数据操作。
// ============================================================================

import Darwin
import Foundation

public enum LocalLinuxRuntimeTrigger: String, Sendable {
    case agentRequest = "agent_request"
    case userTerminal = "user_terminal"
    case guestFileBrowser = "guest_file_browser"
    case recipe
    case localMCP = "local_mcp"
}

public actor LocalLinuxRuntimeController {
    public static let shared = LocalLinuxRuntimeController()

    private let storage: LocalLinuxStorageManager
    private let executorDeviceID: String

    private var snapshotValue: LocalLinuxRuntimeSnapshot
    private var preparationTask: Task<LocalLinuxRuntimeSnapshot, Error>?
    private var maintenanceTask: Task<LocalLinuxRuntimeSnapshot, Error>?
    private var updateContinuations: [UUID: AsyncStream<LocalLinuxRuntimeSnapshot>.Continuation] = [:]
    private var didRecoverPersistedJobs = false
    private var runtimeStarted = false
    private var cancelActiveWork: (@Sendable () async -> Void)?

    public init(
        storage: LocalLinuxStorageManager = .shared,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.storage = storage
        self.executorDeviceID = executorDeviceID
        snapshotValue = LocalLinuxRuntimeSnapshot(
            phase: AppConfigStore.boolValue(for: .localLinuxEnabled) ? .notInstalled : .disabled
        )
    }

    public func snapshot() -> LocalLinuxRuntimeSnapshot {
        snapshotValue
    }

    public func updates() -> AsyncStream<LocalLinuxRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            updateContinuations[id] = continuation
            continuation.yield(snapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id: id) }
            }
        }
    }

    public func setActiveWorkCancellationHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        cancelActiveWork = handler
    }

    @discardableResult
    public func refreshInstalledState() async -> LocalLinuxRuntimeSnapshot {
        guard let activity = try? LocalLinuxActivityBarrier.shared.begin() else { return snapshotValue }
        defer { activity.finish() }
        // 页面刷新不能把进行中的安装或维护覆盖成“已安装”，否则会放行新的操作。
        guard preparationTask == nil, maintenanceTask == nil else { return snapshotValue }
        await recoverPersistedJobsIfNeeded()
        guard preparationTask == nil, maintenanceTask == nil else { return snapshotValue }
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            updateSnapshot(phase: .disabled, progress: nil, error: nil)
            return snapshotValue
        }
        #if os(macOS)
        updateSnapshot(phase: .ready, progress: nil, error: nil)
        #else
        updateSnapshot(phase: .disabled, progress: nil, error: nil)
        #endif
        return snapshotValue
    }

    public func ensureReady(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        defer { activity.finish() }
        while let maintenanceTask { _ = try await maintenanceTask.value }
        try activity.checkCancellation()
        if let preparationTask { return try await preparationTask.value }

        // 在第一次挂起前登记任务；actor 在 await 期间仍允许其他启动请求进入。
        let task = Task {
            defer { preparationTask = nil }
            return try await prepareIfNeeded(trigger: trigger)
        }
        preparationTask = task
        return try await task.value
    }

    private func prepareIfNeeded(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        await recoverPersistedJobsIfNeeded()
        try Task.checkCancellation()
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }
        #if os(macOS)
        _ = try await storage.prepareLayout()
        runtimeStarted = true
        updateSnapshot(phase: .ready, progress: nil, error: nil)
        return snapshotValue
        #else
        throw LocalLinuxRuntimeError.runtimeUnavailable(NSLocalizedString("本机 shell 仅在 macOS 可用。", comment: "Native shell unavailable"))
        #endif
    }

    public func cancelPreparation() {
        preparationTask?.cancel()
    }

    public func updateActivityCounts(jobs: Int, terminals: Int, localMCP: Int) {
        snapshotValue.activeJobCount = max(0, jobs)
        snapshotValue.activeTerminalCount = max(0, terminals)
        snapshotValue.activeMCPProcessCount = max(0, localMCP)
        snapshotValue.updatedAt = Date()
        publishSnapshot()
    }

    /// 调用方已暂停入口并等待作业收尾；停止内核后才可以替换数据库和挂载记录。
    public func stopForHostDataOperation() async throws {
        precondition(LocalLinuxActivityBarrier.shared.isSuspended)
        if let maintenanceTask { _ = try? await maintenanceTask.value }
        try await stopRuntimeForMaintenance()
        // 恢复的数据库可能包含其他设备的运行态；下一次读取时重新收敛为已中断。
        didRecoverPersistedJobs = false
        #if os(macOS)
        let phase: LocalLinuxRuntimePhase = .ready
        #else
        let phase: LocalLinuxRuntimePhase = .disabled
        #endif
        updateSnapshot(phase: AppConfigStore.boolValue(for: .localLinuxEnabled) ? phase : .disabled, progress: nil, error: nil)
    }

    /// 数据库替换完成后、重新开放执行入口前，先清理导入的运行态和旧租约计数。
    public func prepareForHostResume() async {
        precondition(LocalLinuxActivityBarrier.shared.isSuspended)
        await recoverPersistedJobsIfNeeded()
    }

    private func stopRuntimeForMaintenance() async throws {
        if let task = preparationTask {
            task.cancel()
            _ = try? await task.value
        }
        if let cancelActiveWork { await cancelActiveWork() }

        runtimeStarted = false
        snapshotValue.capabilities = nil
        snapshotValue.activeJobCount = 0
        snapshotValue.activeTerminalCount = 0
        snapshotValue.activeMCPProcessCount = 0
    }

    private func recoverPersistedJobsIfNeeded() async {
        guard !didRecoverPersistedJobs else { return }
        didRecoverPersistedJobs = true
        _ = Persistence.markActiveLocalLinuxJobsInterrupted()
        _ = Persistence.markActiveLocalAgentRunsInterrupted()
    }

    private func updateSnapshot(
        phase: LocalLinuxRuntimePhase,
        progress: LocalLinuxInstallProgress?,
        error: String?
    ) {
        snapshotValue.phase = phase
        snapshotValue.installProgress = progress
        snapshotValue.lastError = error
        snapshotValue.updatedAt = Date()
        _ = Persistence.saveLocalLinuxRuntimeSnapshot(snapshotValue, executorDeviceID: executorDeviceID)
        publishSnapshot()
    }

    private func publishSnapshot() {
        updateContinuations.values.forEach { $0.yield(snapshotValue) }
    }

    private func removeUpdateContinuation(id: UUID) {
        updateContinuations[id] = nil
    }

}
