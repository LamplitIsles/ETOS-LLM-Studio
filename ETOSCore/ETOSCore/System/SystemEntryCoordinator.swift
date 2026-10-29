// ============================================================================
// SystemEntryCoordinator.swift
// ETOS LLM Studio
// ============================================================================

import Foundation
import Combine

public enum ETOSSystemEntryError: LocalizedError {
    case emptyPrompt
    case sessionNotFound
    case requestInProgress
    case persistenceUnavailable
    case busy
    case outcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return NSLocalizedString("请输入要处理的内容。", comment: "Empty system-entry prompt")
        case .sessionNotFound:
            return NSLocalizedString("找不到指定会话。", comment: "Missing system-entry session")
        case .requestInProgress:
            return NSLocalizedString("该请求正在处理中。", comment: "System-entry request is already claimed")
        case .persistenceUnavailable:
            return NSLocalizedString("暂时无法写入本地数据库。", comment: "System-entry persistence unavailable")
        case .busy:
            return NSLocalizedString("当前会话正在处理，请稍后再发送。", comment: "System-entry session busy")
        case .outcomeUnknown:
            return NSLocalizedString("该请求已有记录，发送结果尚未确认。请先查看会话，再决定下一步。", comment: "System-entry outcome unknown")
        }
    }
}

/// True only when the caller can still present the complete original input.
public typealias ETOSSystemEntrySourceRetained = @MainActor @Sendable () -> Bool

public struct ETOSSystemEntryTaskResult: Sendable {
    public enum Outcome: Sendable {
        case locallyAccepted
        case alreadyRecorded
    }
    public let sessionID: UUID
    public let outcome: Outcome
    public init(sessionID: UUID, outcome: Outcome) {
        self.sessionID = sessionID
        self.outcome = outcome
    }
}

/// System-entry state is process-local and does not reuse the widget snapshot schema.
public enum ETOSSystemEntryProcessStatus: Sendable {
    case running
    case toolOutcomeUnknown
    case unknown
}

public struct ETOSSystemEntryStatus: Sendable {
    public let sessionID: UUID
    public let sessionName: String
    public let status: ETOSSystemEntryProcessStatus
    public let unknownToolOutcomes: [ChatUnknownToolOutcome]
    public let observedAt: Date

    public init(sessionID: UUID, sessionName: String, status: ETOSSystemEntryProcessStatus,
                unknownToolOutcomes: [ChatUnknownToolOutcome], observedAt: Date) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.status = status
        self.unknownToolOutcomes = unknownToolOutcomes
        self.observedAt = observedAt
    }
}

/// 系统入口只负责参数收束和幂等治理，消息仍通过 ChatService 的正式发送链路执行。
@MainActor
public final class SystemEntryCoordinator {
    public static let shared = SystemEntryCoordinator()

    private let chatService: ChatService

    public init(chatService: ChatService = .shared) {
        self.chatService = chatService
    }

    public func startTask(
        prompt: String,
        mode: LocalAgentMode = .agent,
        title: String? = nil,
        requestID: UUID,
        kind: ETOSSystemEntryRequestKind = .appIntent,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = [],
        sourceRetained: ETOSSystemEntrySourceRetained? = nil
    ) async throws -> ETOSSystemEntryTaskResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !fileAttachments.isEmpty || !imageAttachments.isEmpty else {
            throw ETOSSystemEntryError.emptyPrompt
        }

        if let receipt = await Task.detached(priority: .userInitiated, operation: {
            Persistence.loadSystemEntryReceipt(id: requestID)
        }).value {
            guard let sessionID = receipt.sessionID else { throw ETOSSystemEntryError.outcomeUnknown }
            return ETOSSystemEntryTaskResult(sessionID: sessionID, outcome: .alreadyRecorded)
        }
        let session = await SystemEntryNewSessionClaim.createIfClaimed {
            await Task.detached(priority: .userInitiated) {
                Persistence.claimSystemEntryRequest(id: requestID, kind: kind)
            }.value
        } create: {
            chatService.createSavedSession(name: resolvedTitle(title, prompt: trimmed))
        }
        guard let session else {
            if let sessionID = await Task.detached(priority: .userInitiated, operation: {
                Persistence.loadSystemEntryReceipt(id: requestID)?.sessionID
            }).value {
                return ETOSSystemEntryTaskResult(sessionID: sessionID, outcome: .alreadyRecorded)
            }
            throw ETOSSystemEntryError.outcomeUnknown
        }
        let lease: ChatRequestLease
        do { lease = try reserve(sessionID: session.id) }
        catch { throw ETOSSystemEntryError.outcomeUnknown }
        defer { lease.release() }
        let persisted = await Task.detached(priority: .userInitiated) {
            guard Persistence.saveLocalAgentMode(mode, sessionID: session.id) else { return false }
            return Persistence.saveSystemEntryReceipt(
                ETOSSystemEntryReceipt(id: requestID, kind: kind, sessionID: session.id)
            )
        }.value
        guard persisted else {
            throw ETOSSystemEntryError.outcomeUnknown
        }
        guard await send(trimmed, to: session.id, mode: mode, fileAttachments: fileAttachments,
                         imageAttachments: imageAttachments, requestLease: lease, sourceRetained: sourceRetained) else {
            throw ETOSSystemEntryError.outcomeUnknown
        }
        return ETOSSystemEntryTaskResult(sessionID: session.id, outcome: .locallyAccepted)
    }

    public func continueTask(
        sessionID: UUID,
        prompt: String,
        requestID: UUID,
        kind: ETOSSystemEntryRequestKind = .appIntent,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = [],
        sourceRetained: ETOSSystemEntrySourceRetained? = nil
    ) async throws -> ETOSSystemEntryTaskResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !fileAttachments.isEmpty || !imageAttachments.isEmpty else {
            throw ETOSSystemEntryError.emptyPrompt
        }
        if let receipt = await Task.detached(priority: .userInitiated, operation: {
            Persistence.loadSystemEntryReceipt(id: requestID)
        }).value {
            guard let handledSessionID = receipt.sessionID else { throw ETOSSystemEntryError.outcomeUnknown }
            return ETOSSystemEntryTaskResult(sessionID: handledSessionID, outcome: .alreadyRecorded)
        }
        guard chatService.conversationSession(withID: sessionID) != nil else { throw ETOSSystemEntryError.sessionNotFound }
        let lease = try reserve(sessionID: sessionID)
        defer { lease.release() }
        let persisted = await Task.detached(priority: .userInitiated) {
            guard Persistence.claimSystemEntryRequest(id: requestID, kind: kind) else { return false }
            return Persistence.saveSystemEntryReceipt(
                ETOSSystemEntryReceipt(id: requestID, kind: kind, sessionID: sessionID)
            )
        }.value
        guard persisted else {
            if let existing = await Task.detached(priority: .userInitiated, operation: {
                Persistence.loadSystemEntryReceipt(id: requestID)?.sessionID
            }).value {
                return ETOSSystemEntryTaskResult(sessionID: existing, outcome: .alreadyRecorded)
            }
            throw ETOSSystemEntryError.outcomeUnknown
        }
        guard await send(
            trimmed,
            to: sessionID,
            fileAttachments: fileAttachments,
            imageAttachments: imageAttachments,
            requestLease: lease,
            sourceRetained: sourceRetained
        ) else { throw ETOSSystemEntryError.outcomeUnknown }
        return ETOSSystemEntryTaskResult(sessionID: sessionID, outcome: .locallyAccepted)
    }

    public func stop(sessionID: UUID) async throws {
        guard chatService.conversationSession(withID: sessionID) != nil else { throw ETOSSystemEntryError.sessionNotFound }
        await chatService.cancelRequest(for: sessionID)
    }

    public func status(sessionID: UUID? = nil) async throws -> ETOSSystemEntryStatus {
        let session = sessionID.flatMap { chatService.conversationSession(withID: $0) }
            ?? (sessionID == nil ? chatService.currentSessionSubject.value : nil)
        guard let session else { throw ETOSSystemEntryError.sessionNotFound }
        let unknownTools = chatService.unknownToolOutcomes(for: session.id)
        let state: ETOSSystemEntryProcessStatus = !unknownTools.isEmpty
            ? .toolOutcomeUnknown
            : (chatService.runningSessionIDsSubject.value.contains(session.id) ? .running : .unknown)
        return ETOSSystemEntryStatus(
            sessionID: session.id,
            sessionName: String(session.name.prefix(80)),
            status: state,
            unknownToolOutcomes: unknownTools,
            observedAt: Date()
        )
    }

    private func send(
        _ content: String,
        to sessionID: UUID,
        mode: LocalAgentMode? = nil,
        fileAttachments: [FileAttachment] = [],
        imageAttachments: [ImageAttachment] = [],
        requestLease: ChatRequestLease,
        sourceRetained: ETOSSystemEntrySourceRetained?
    ) async -> Bool {
        await chatService.sendAndProcessMessage(
            content: content,
            aiTemperature: realConfig(.aiTemperature),
            aiTopP: realConfig(.aiTopP),
            maxChatHistory: AppConfigStore.integerValue(for: .maxChatHistory),
            enableStreaming: AppConfigStore.boolValue(for: .enableStreaming),
            includeSystemTime: AppConfigStore.boolValue(for: .includeSystemTimeInPrompt),
            systemTimeInjectionPosition: SystemTimeInjectionPosition(
                rawValue: textConfig(.systemTimeInjectionPosition)
            ) ?? .front,
            enablePeriodicTimeLandmark: AppConfigStore.boolValue(for: .enablePeriodicTimeLandmark),
            periodicTimeLandmarkIntervalMinutes: AppConfigStore.integerValue(for: .periodicTimeLandmarkIntervalMinutes),
            enableResponseSpeedMetrics: AppConfigStore.boolValue(for: .enableResponseSpeedMetrics),
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments,
            targetSessionID: sessionID,
            requestedLocalAgentMode: mode,
            requestLease: requestLease,
            onInputAccepted: { _, _ in sourceRetained?() ?? false }
        )
        return requestLease.wasInputAccepted
    }

    private func reserve(sessionID: UUID) throws -> ChatRequestLease {
        switch chatService.beginRequest(sessionID: sessionID) {
        case .success(let lease): return lease
        case .failure(.busy): throw ETOSSystemEntryError.busy
        case .failure(.sessionMissing): throw ETOSSystemEntryError.sessionNotFound
        }
    }

    private func resolvedTitle(_ title: String?, prompt: String) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return String(title.prefix(80))
        }
        let firstLine = prompt.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty
            ? NSLocalizedString("新的 Agent 任务", comment: "Default external Agent task title")
            : String(firstLine.prefix(80))
    }

    private func textConfig(_ key: AppConfigKey) -> String {
        AppConfigStore.textValue(for: key)
    }

    private func realConfig(_ key: AppConfigKey) -> Double {
        if let stored = Persistence.readAppConfigReal(key: key.rawValue) { return stored }
        if case .real(let value) = key.defaultValue { return value }
        return 0
    }

}
