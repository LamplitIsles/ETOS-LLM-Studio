// ============================================================================
// ChatModelsSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 ChatModels.swift 中的消息版本、响应尝试、请求日志与会话模型辅助逻辑。
// ============================================================================

import Foundation

public struct ChatResponseAttemptVersionInfo: Equatable, Sendable {
    public let responseGroupID: UUID
    public let currentAttemptID: UUID
    public let currentIndex: Int
    public let totalCount: Int
}

public struct MessageRewriteReferenceVersion: Identifiable, Equatable, Hashable, Sendable {
    public let versionNumber: Int
    public let content: String

    public var id: Int { versionNumber }

    public init(versionNumber: Int, content: String) {
        self.versionNumber = versionNumber
        self.content = content
    }
}

/// 统一控制思考内容在流式阶段的正文渲染与 Markdown 预处理节奏。
public enum ChatReasoningRenderPolicy {
    public static func shouldSuppressReasoningContentRender(message: ChatMessage, isStreaming: Bool) -> Bool {
        isStreaming && message.role == .assistant
    }

    public static func shouldPrepareReasoningMarkdown(message: ChatMessage, isStreaming: Bool) -> Bool {
        guard hasReasoningContent(message) else { return false }
        guard shouldSuppressReasoningPreparation(message: message, isStreaming: isStreaming) else {
            return true
        }
        return false
    }

    private static func shouldSuppressReasoningPreparation(message: ChatMessage, isStreaming: Bool) -> Bool {
        guard shouldSuppressReasoningContentRender(message: message, isStreaming: isStreaming) else {
            return false
        }
        let metrics = message.responseMetrics
        return metrics?.reasoningCompletedAt == nil && metrics?.responseCompletedAt == nil
    }

    private static func hasReasoningContent(_ message: ChatMessage) -> Bool {
        !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}

public enum ChatQuickRetrySupport {
    public static func canRetryLatestMessage(in messages: [ChatMessage], isSending: Bool) -> Bool {
        guard !isSending else { return false }
        let visibleMessages = ChatResponseAttemptSupport.visibleMessages(from: messages)
        return canRetryLatestMessage(
            visibleMessages.last, hasUserMessage: visibleMessages.contains { $0.role == .user }
        )
    }

    public static func canRetryLatestMessage(_ latestMessage: ChatMessage?, hasUserMessage: Bool) -> Bool {
        guard hasUserMessage, let latestMessage else {
            return false
        }

        switch latestMessage.role {
        case .error:
            return true
        case .assistant:
            return !(latestMessage.toolCalls ?? []).isEmpty
                || isAbnormalStoppedAssistantMessage(latestMessage)
        case .user:
            return true
        case .tool:
            return true
        case .system:
            return false
        }
    }

    public static func isAbnormalStoppedAssistantMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        guard !hasVisibleAssistantBodyContent(message) else { return false }
        guard !hasAssistantMediaContent(message) else { return false }

        let hasReasoning = !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasReasoning {
            return true
        }

        let hasToolCalls = !(message.toolCalls ?? []).isEmpty
        return !hasToolCalls
    }

    private static func hasVisibleAssistantBodyContent(_ message: ChatMessage) -> Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        switch trimmedContent {
        case "[图片]", "[圖片]", "[Image]", "[画像]":
            return false
        default:
            return true
        }
    }

    private static func hasAssistantMediaContent(_ message: ChatMessage) -> Bool {
        message.audioFileName != nil
            || !(message.imageFileNames ?? []).isEmpty
            || !(message.fileFileNames ?? []).isEmpty
    }
}

public enum ChatResponseAttemptSupport {
    public static func shouldMergeAdjacentAssistantTurnMessages(_ message: ChatMessage, _ nextMessage: ChatMessage) -> Bool {
        guard isAssistantTurnMessage(message),
              isAssistantTurnMessage(nextMessage) else {
            return false
        }

        let messageHasAttempt = message.responseGroupID != nil || message.responseAttemptID != nil
        let nextMessageHasAttempt = nextMessage.responseGroupID != nil || nextMessage.responseAttemptID != nil
        guard messageHasAttempt || nextMessageHasAttempt else {
            return true
        }

        guard let messageGroupID = message.responseGroupID,
              let messageAttemptID = message.responseAttemptID,
              let nextMessageGroupID = nextMessage.responseGroupID,
              let nextMessageAttemptID = nextMessage.responseAttemptID else {
            return false
        }

        return messageGroupID == nextMessageGroupID && messageAttemptID == nextMessageAttemptID
    }

    public static func visibleMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        let selectedByGroup = selectedAttemptIDsByGroup(in: messages)
        return messages.filter { message in
            guard let groupID = message.responseGroupID,
                  let attemptID = message.responseAttemptID,
                  let selectedAttemptID = selectedByGroup[groupID] else {
                return true
            }
            return attemptID == selectedAttemptID
        }
    }

    public static func versionInfo(for message: ChatMessage, in messages: [ChatMessage]) -> ChatResponseAttemptVersionInfo? {
        guard let groupID = responseGroupID(for: message, in: messages) else {
            return nil
        }

        let attempts = orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.count > 1,
              let selectedAttemptID = selectedAttemptIDsByGroup(in: messages)[groupID],
              let currentIndex = attempts.firstIndex(of: selectedAttemptID) else {
            return nil
        }

        if let messageAttemptID = message.responseAttemptID,
           messageAttemptID != selectedAttemptID {
            return nil
        }

        return ChatResponseAttemptVersionInfo(
            responseGroupID: groupID,
            currentAttemptID: selectedAttemptID,
            currentIndex: currentIndex,
            totalCount: attempts.count
        )
    }

    /// 一份会话快照只整理一次分组、排序与轮次；气泡按 ID 查询，避免逐行扫描整段会话。
    public static func versionInfoByMessageID(in messages: [ChatMessage]) -> [UUID: ChatResponseAttemptVersionInfo] {
        let selectedByGroup = selectedAttemptIDsByGroup(in: messages)
        var ordersByGroup: [UUID: [UUID: AttemptOrder]] = [:]
        var visible: [ChatMessage] = []
        for (position, message) in messages.enumerated() {
            if let group = message.responseGroupID, let attempt = message.responseAttemptID {
                recordAttemptOrder(attemptID: attempt, explicitIndex: message.responseAttemptIndex, position: position, in: &ordersByGroup[group, default: [:]])
                if let selected = selectedByGroup[group], selected != attempt { continue }
            }
            visible.append(message)
        }

        var infoByGroup: [UUID: ChatResponseAttemptVersionInfo] = [:]
        for (group, orders) in ordersByGroup {
            let attempts = orderedAttemptIDs(from: orders)
            guard attempts.count > 1, let selected = selectedByGroup[group],
                  let index = attempts.firstIndex(of: selected) else { continue }
            infoByGroup[group] = ChatResponseAttemptVersionInfo(responseGroupID: group, currentAttemptID: selected, currentIndex: index, totalCount: attempts.count)
        }

        var inferredGroups: [UUID: UUID] = [:]
        for turn in ChatConversationTurnSupport.turns(in: visible) {
            guard let anchor = turn.responseGroupAnchorIndex else { continue }
            let group = visible[anchor].id
            for index in turn.range { inferredGroups[visible[index].id] = group }
        }
        var result: [UUID: ChatResponseAttemptVersionInfo] = [:]
        for message in messages {
            guard let group = message.responseGroupID ?? inferredGroups[message.id],
                  let info = infoByGroup[group] else { continue }
            if let attempt = message.responseAttemptID, attempt != info.currentAttemptID { continue }
            result[message.id] = info
        }
        return result
    }

    public static func selectPreviousAttempt(for message: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage]? {
        guard let info = versionInfo(for: message, in: messages), info.currentIndex > 0 else { return nil }
        return selectAttempt(attemptID: orderedAttemptIDs(for: info.responseGroupID, in: messages)[info.currentIndex - 1], groupID: info.responseGroupID, in: messages)
    }

    public static func selectNextAttempt(for message: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage]? {
        guard let info = versionInfo(for: message, in: messages), info.currentIndex + 1 < info.totalCount else { return nil }
        return selectAttempt(attemptID: orderedAttemptIDs(for: info.responseGroupID, in: messages)[info.currentIndex + 1], groupID: info.responseGroupID, in: messages)
    }

    public static func selectAttempt(attemptID: UUID, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            let shouldStoreSelection = (message.id == groupID && message.role == .user)
                || message.responseGroupID == groupID
            guard shouldStoreSelection else { return message }
            var updated = message
            updated.selectedResponseAttemptID = attemptID
            return updated
        }
    }

    public static func deleteAttempt(at index: Int, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage]? {
        let attempts = orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.indices.contains(index) else { return nil }

        let targetAttemptID = attempts[index]
        let selectedAttemptID = selectedAttemptID(for: groupID, in: messages)
        let remainingAttempts = attempts.filter { $0 != targetAttemptID }
        var updatedMessages = messages.filter {
            !($0.responseGroupID == groupID && $0.responseAttemptID == targetAttemptID)
        }

        guard selectedAttemptID == targetAttemptID else {
            return updatedMessages
        }

        let replacementIndex = max(0, min(index, remainingAttempts.count - 1))
        if remainingAttempts.indices.contains(replacementIndex) {
            return selectAttempt(
                attemptID: remainingAttempts[replacementIndex],
                groupID: groupID,
                in: updatedMessages
            )
        }

        if let anchorIndex = updatedMessages.firstIndex(where: { $0.id == groupID && $0.role == .user }) {
            updatedMessages[anchorIndex].selectedResponseAttemptID = nil
        }
        return updatedMessages
    }

    public static func orderedAttemptIDs(for groupID: UUID, in messages: [ChatMessage]) -> [UUID] {
        var orderByID: [UUID: AttemptOrder] = [:]
        for (position, message) in messages.enumerated() {
            guard message.responseGroupID == groupID,
                  let attemptID = message.responseAttemptID else {
                continue
            }
            recordAttemptOrder(
                attemptID: attemptID,
                explicitIndex: message.responseAttemptIndex,
                position: position,
                in: &orderByID
            )
        }

        return orderedAttemptIDs(from: orderByID)
    }

    private struct AttemptOrder {
        let id: UUID
        let explicitIndex: Int
        let firstPosition: Int
    }

    private static func recordAttemptOrder(
        attemptID: UUID,
        explicitIndex: Int?,
        position: Int,
        in orderByID: inout [UUID: AttemptOrder]
    ) {
        let normalizedIndex = explicitIndex ?? Int.max
        if let existing = orderByID[attemptID] {
            orderByID[attemptID] = AttemptOrder(
                id: attemptID,
                explicitIndex: min(existing.explicitIndex, normalizedIndex),
                firstPosition: min(existing.firstPosition, position)
            )
        } else {
            orderByID[attemptID] = AttemptOrder(
                id: attemptID,
                explicitIndex: normalizedIndex,
                firstPosition: position
            )
        }
    }

    private static func orderedAttemptIDs(from orderByID: [UUID: AttemptOrder]) -> [UUID] {
        return orderByID.values
            .sorted {
                if $0.explicitIndex != $1.explicitIndex {
                    return $0.explicitIndex < $1.explicitIndex
                }
                return $0.firstPosition < $1.firstPosition
            }
            .map(\.id)
    }

    public static func selectedAttemptID(for groupID: UUID, in messages: [ChatMessage]) -> UUID? {
        selectedAttemptIDsByGroup(in: messages)[groupID]
    }

    private static func selectedAttemptIDsByGroup(in messages: [ChatMessage]) -> [UUID: UUID] {
        var anchorSelectionByGroup: [UUID: UUID] = [:]
        var storedSelectionByGroup: [UUID: UUID] = [:]
        var orderByGroup: [UUID: [UUID: AttemptOrder]] = [:]

        for (position, message) in messages.enumerated() {
            if message.role == .user,
               let selectedAttemptID = message.selectedResponseAttemptID {
                anchorSelectionByGroup[message.id] = selectedAttemptID
            }

            guard let groupID = message.responseGroupID else { continue }
            if (message.role == .assistant || message.role == .error),
               let selectedAttemptID = message.selectedResponseAttemptID {
                storedSelectionByGroup[groupID] = selectedAttemptID
            }

            guard let attemptID = message.responseAttemptID else { continue }
            recordAttemptOrder(
                attemptID: attemptID,
                explicitIndex: message.responseAttemptIndex,
                position: position,
                in: &orderByGroup[groupID, default: [:]]
            )
        }

        var selectedByGroup = anchorSelectionByGroup
        for (groupID, selectedAttemptID) in storedSelectionByGroup {
            selectedByGroup[groupID] = selectedAttemptID
        }

        for (groupID, orderByID) in orderByGroup {
            let attempts = orderedAttemptIDs(from: orderByID)
            guard let fallbackAttemptID = attempts.last else { continue }
            if let selectedAttemptID = selectedByGroup[groupID],
               attempts.contains(selectedAttemptID) {
                continue
            }
            selectedByGroup[groupID] = fallbackAttemptID
        }
        return selectedByGroup
    }

    private static func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        }
    }

    private static func responseGroupID(for message: ChatMessage, in messages: [ChatMessage]) -> UUID? {
        if let responseGroupID = message.responseGroupID {
            return responseGroupID
        }

        let visibleMessages = visibleMessages(from: messages)
        guard let turn = ChatConversationTurnSupport.turn(
            containingMessageID: message.id,
            in: visibleMessages
        ),
        let anchorIndex = turn.responseGroupAnchorIndex else {
            return nil
        }
        return visibleMessages[anchorIndex].id
    }
}

public enum MessageRewriteReferenceSupport {
    public static func referenceVersions(
        for message: ChatMessage,
        in messages: [ChatMessage]
    ) -> [MessageRewriteReferenceVersion] {
        if let responseAttemptReferences = responseAttemptReferenceVersions(for: message, in: messages) {
            return responseAttemptReferences
        }
        return legacyReferenceVersions(for: message)
    }

    private static func responseAttemptReferenceVersions(
        for message: ChatMessage,
        in messages: [ChatMessage]
    ) -> [MessageRewriteReferenceVersion]? {
        guard let groupID = message.responseGroupID,
              let currentAttemptID = message.responseAttemptID else {
            return nil
        }

        let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: groupID, in: messages)
        guard attempts.count > 1, attempts.contains(currentAttemptID) else { return nil }

        return attempts.enumerated().compactMap { index, attemptID in
            guard attemptID != currentAttemptID,
                  let content = representativeContent(
                    forAttemptID: attemptID,
                    groupID: groupID,
                    in: messages
                  ) else {
                return nil
            }
            return MessageRewriteReferenceVersion(versionNumber: index + 1, content: content)
        }
    }

    private static func representativeContent(
        forAttemptID attemptID: UUID,
        groupID: UUID,
        in messages: [ChatMessage]
    ) -> String? {
        messages
            .reversed()
            .first {
                $0.responseGroupID == groupID
                    && $0.responseAttemptID == attemptID
                    && ($0.role == .assistant || $0.role == .error)
                    && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }?
            .content
    }

    private static func legacyReferenceVersions(for message: ChatMessage) -> [MessageRewriteReferenceVersion] {
        let currentIndex = message.getCurrentVersionIndex()
        return message.getAllVersions().enumerated().compactMap { index, content in
            guard index != currentIndex,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return MessageRewriteReferenceVersion(versionNumber: index + 1, content: content)
        }
    }
}

public enum RequestLogStatus: String, Codable, Hashable, Sendable {
    case success
    case failed
    case cancelled
}

public struct RequestLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var requestID: UUID
    public var sessionID: UUID?
    public var providerID: UUID?
    public var providerName: String
    public var modelID: String
    public var requestedAt: Date
    public var finishedAt: Date
    public var isStreaming: Bool
    public var status: RequestLogStatus
    public var tokenUsage: MessageTokenUsage?

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        sessionID: UUID?,
        providerID: UUID?,
        providerName: String,
        modelID: String,
        requestedAt: Date,
        finishedAt: Date,
        isStreaming: Bool,
        status: RequestLogStatus,
        tokenUsage: MessageTokenUsage? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.requestedAt = requestedAt
        self.finishedAt = finishedAt
        self.isStreaming = isStreaming
        self.status = status
        self.tokenUsage = tokenUsage
    }
}

public struct RequestLogQuery: Hashable, Sendable {
    public var from: Date?
    public var to: Date?
    public var providerID: UUID?
    public var modelID: String?
    public var statuses: Set<RequestLogStatus>?
    public var limit: Int?

    public init(
        from: Date? = nil,
        to: Date? = nil,
        providerID: UUID? = nil,
        modelID: String? = nil,
        statuses: Set<RequestLogStatus>? = nil,
        limit: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.providerID = providerID
        self.modelID = modelID
        self.statuses = statuses
        self.limit = limit
    }
}

public struct RequestLogTokenTotals: Codable, Hashable, Sendable {
    public var sentTokens: Int
    public var receivedTokens: Int
    public var thinkingTokens: Int
    public var cacheWriteTokens: Int
    public var cacheWriteFiveMinuteTokens: Int?
    public var cacheWriteOneHourTokens: Int?
    public var uncachedInputTokens: Int?
    public var cacheReadTokens: Int
    public var totalTokens: Int

    public init(
        sentTokens: Int = 0,
        receivedTokens: Int = 0,
        thinkingTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        cacheWriteFiveMinuteTokens: Int? = nil,
        cacheWriteOneHourTokens: Int? = nil,
        cacheReadTokens: Int = 0,
        totalTokens: Int = 0,
        uncachedInputTokens: Int? = nil
    ) {
        self.sentTokens = sentTokens
        self.receivedTokens = receivedTokens
        self.thinkingTokens = thinkingTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWriteFiveMinuteTokens = cacheWriteFiveMinuteTokens
        self.cacheWriteOneHourTokens = cacheWriteOneHourTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
    }
}

public struct RequestLogSummaryBucket: Codable, Hashable, Sendable {
    public var key: String
    public var requestCount: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals

    public init(
        key: String,
        requestCount: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init()
    ) {
        self.key = key
        self.requestCount = requestCount
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
    }
}

public struct RequestLogSummary: Codable, Hashable, Sendable {
    public var totalRequests: Int
    public var successCount: Int
    public var failedCount: Int
    public var cancelledCount: Int
    public var tokenTotals: RequestLogTokenTotals
    public var byProvider: [RequestLogSummaryBucket]
    public var byModel: [RequestLogSummaryBucket]

    public init(
        totalRequests: Int = 0,
        successCount: Int = 0,
        failedCount: Int = 0,
        cancelledCount: Int = 0,
        tokenTotals: RequestLogTokenTotals = .init(),
        byProvider: [RequestLogSummaryBucket] = [],
        byModel: [RequestLogSummaryBucket] = []
    ) {
        self.totalRequests = totalRequests
        self.successCount = successCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
        self.tokenTotals = tokenTotals
        self.byProvider = byProvider
        self.byModel = byModel
    }
}

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var preferredModelIdentifier: String?
    public var folderID: UUID?
    public var containerSessionID: UUID?
    public var tagIDs: [UUID]
    public var toolContextIsolationEnabled: Bool
    public var isTemporary: Bool = false

    public var isEmbeddedSubagent: Bool { containerSessionID != nil }
    public var isToolContextIsolationActive: Bool { toolContextIsolationEnabled }

    public init(
        id: UUID,
        name: String,
        preferredModelIdentifier: String? = nil,
        tagIDs: [UUID] = [],
        toolContextIsolationEnabled: Bool = false,
        folderID: UUID? = nil,
        containerSessionID: UUID? = nil,
        isTemporary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.preferredModelIdentifier = preferredModelIdentifier
        self.folderID = folderID
        self.containerSessionID = containerSessionID
        self.tagIDs = tagIDs
        self.toolContextIsolationEnabled = toolContextIsolationEnabled
        self.isTemporary = isTemporary
    }

    enum CodingKeys: String, CodingKey {
        case id, name, preferredModelIdentifier, folderID, containerSessionID, tagIDs, toolContextIsolationEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        preferredModelIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredModelIdentifier)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        containerSessionID = try container.decodeIfPresent(UUID.self, forKey: .containerSessionID)
        tagIDs = try container.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        toolContextIsolationEnabled = try container.decodeIfPresent(Bool.self, forKey: .toolContextIsolationEnabled) ?? false
        isTemporary = false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(preferredModelIdentifier, forKey: .preferredModelIdentifier)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encodeIfPresent(containerSessionID, forKey: .containerSessionID)
        try container.encode(tagIDs, forKey: .tagIDs)
        try container.encode(toolContextIsolationEnabled, forKey: .toolContextIsolationEnabled)
    }
}

public struct SessionFolder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// 父文件夹 ID，nil 表示根目录。
    public var parentID: UUID?
    /// 用于记录文件夹元数据最近更新时间。
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.updatedAt = updatedAt
    }
}
