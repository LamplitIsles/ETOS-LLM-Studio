// ============================================================================
// ChatService.swift
// ============================================================================
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================

import Foundation
import Combine
import os.log
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public class ChatService {
    
    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatService")
    static let modelOrderStorageKey = "modelOrder.runnableModels"
    static let selectedRunnableModelStorageKey = "selectedRunnableModelID"
    public static let systemSpeechRecognizerProviderID = UUID(uuidString: "2FB43D6B-8E40-4D65-9EA6-C13AB41D8A2E")!
    public static let systemSpeechRecognizerModelID = UUID(uuidString: "EE2F84DF-F640-47B8-9A83-BE438905C4F3")!
    public static let systemOCRProviderID = UUID(uuidString: "4301D30F-D7C6-4A4F-A45B-F8721CD68099")!
    public static let systemOCRModelID = UUID(uuidString: "40B2DA2B-3E72-4A29-954E-29FECAD1C1DF")!
    public static let systemSpeechRecognizerRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemSpeechRecognizerProviderID,
            name: "SFSpeechRecognizer",
            baseURL: "local://sf-speech-recognizer",
            apiKeys: [],
            apiFormat: "local-speech"
        )
        let model = Model(
            id: systemSpeechRecognizerModelID,
            modelName: "sf-speech-recognizer",
            displayName: "SFSpeechRecognizer",
            isActivated: true
        )
        return RunnableModel(provider: provider, model: model)
    }()

    public static func isSystemSpeechRecognizerModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemSpeechRecognizerRunnableModel.id
    }

    public static let systemOCRRunnableModel: RunnableModel = {
        let provider = Provider(
            id: systemOCRProviderID,
            name: NSLocalizedString("系统 OCR", comment: "System OCR provider name"),
            baseURL: "local://system-ocr",
            apiKeys: [],
            apiFormat: "local-ocr"
        )
        let model = Model(
            id: systemOCRModelID,
            modelName: "vision-ocr",
            displayName: NSLocalizedString("系统 OCR", comment: "System OCR model display name"),
            isActivated: true,
            kind: .chat,
            inputModalities: [.text, .image],
            outputModalities: [.text],
            capabilities: []
        )
        return RunnableModel(provider: provider, model: model)
    }()

    public static func isSystemOCRModel(_ model: RunnableModel?) -> Bool {
        model?.id == systemOCRRunnableModel.id
    }

    // MARK: - 单例
    public static let shared = ChatService()

    // MARK: - 用于 UI 订阅的公开 Subjects
    
    public let chatSessionsSubject: CurrentValueSubject<[ChatSession], Never>
    public let sessionFoldersSubject: CurrentValueSubject<[SessionFolder], Never>
    public let sessionTagsSubject: CurrentValueSubject<[SessionTag], Never>
    public let currentSessionSubject: CurrentValueSubject<ChatSession?, Never>
    public let messagesForSessionSubject: CurrentValueSubject<[ChatMessage], Never>
    
    public let providersSubject: CurrentValueSubject<[Provider], Never>
    public let selectedModelSubject: CurrentValueSubject<RunnableModel?, Never>

    public let unknownToolOutcomesSubject = CurrentValueSubject<[UUID: [ChatUnknownToolOutcome]], Never>([:])
    public let requestStatusSubject = PassthroughSubject<RequestStatus, Never>()
    public let imageGenerationStatusSubject = PassthroughSubject<ImageGenerationStatus, Never>()
    public let runningSessionIDsSubject = CurrentValueSubject<Set<UUID>, Never>([])
    public let conversationRuntimeStatesSubject = CurrentValueSubject<[UUID: ConversationRuntimeSessionState], Never>([:])
    public let sessionRequestStatusSubject = PassthroughSubject<SessionRequestStatusEvent, Never>()
    
    public enum RequestStatus {
        case started
        case finished
        case error
        case cancelled
    }

    public enum SessionRequestStatus: Sendable {
        case started
        case finished
        case error
        case cancelled
    }

    public struct SessionRequestStatusEvent: Sendable {
        public let sessionID: UUID
        public let status: SessionRequestStatus
        /// 固定事件发生时的消息，通知不能依赖异步渲染缓存或稍后切换到的会话。
        public let messages: [ChatMessage]

        public init(sessionID: UUID, status: SessionRequestStatus, messages: [ChatMessage]) {
            self.sessionID = sessionID
            self.status = status
            self.messages = messages
        }
    }

    public enum ImageGenerationStatus {
        case started(sessionID: UUID, loadingMessageID: UUID, prompt: String, startedAt: Date, referenceCount: Int)
        case succeeded(sessionID: UUID, loadingMessageID: UUID, prompt: String, imageFileNames: [String], finishedAt: Date)
        case failed(sessionID: UUID?, loadingMessageID: UUID?, prompt: String, reason: String, finishedAt: Date)
        case cancelled(sessionID: UUID?, loadingMessageID: UUID?, prompt: String, finishedAt: Date)
    }

    // MARK: - 私有状态
    
    private var cancellables = Set<AnyCancellable>()
    /// 每个会话独立维护请求上下文，支持跨会话并发。
    private var requestContextBySessionID: [UUID: RequestExecutionContext] = [:]
    private let requestStateLock = NSRecursiveLock()
    private var unknownToolOutcomes = ChatUnknownToolOutcomes()
    private var requestTokensInFlight = Set<UUID>()
    private var requestCompletionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var backgroundToolRequests = ChatBackgroundToolRequests()
    // A claimed cleanup stays recorded until it finishes and its run is no longer referenced.
    private var toolRunCleanups = ChatToolRunCleanupClaims()
    /// 消息和请求身份共用锁，后续领取输入时必须与快照位于同一事务中。
    private var runtimeMessagesBySessionID: [UUID: [ChatMessage]] = [:]
    // Selection, request state and message publication share one recursive lock.
    // This avoids opposing selection/request lock acquisition during subject callbacks.
    var sessionSelectionLock: NSRecursiveLock { requestStateLock }
    var sessionSelectionToken = UUID()
    /// 显式临时对话只保留运行期消息，和“尚未发送首条消息”的占位会话语义分开。
    var ephemeralSessionIDs: Set<UUID> = []
    let ephemeralSessionLock = NSLock()
    var providers: [Provider]
    let roleplayStore: RoleplayStore
    struct ImageGenerationContext {
        let sessionID: UUID
        let loadingMessageID: UUID
        let prompt: String
    }

    struct RequestExecutionContext {
        var token: UUID
        var task: Task<Void, Error>?
        var loadingMessageID: UUID?
        var imageGenerationContext: ImageGenerationContext?
        var conversationRunID: UUID? = nil
        var rootConversationRunID: UUID? = nil
        var requestConfiguration: ConversationRunRequestConfiguration? = nil
        var taskRegistrationPending = false
        var hasFinishedResponse = false
        var isCancelled = false
    }

    public func messagesSnapshot(for sessionID: UUID) -> [ChatMessage] {
        runtimeMessagesSnapshot(for: sessionID) ?? []
    }

    func conversationSession(withID sessionID: UUID) -> ChatSession? {
        if let current = currentSessionSubject.value, current.id == sessionID {
            return current
        }
        return chatSessionsSubject.value.first(where: { $0.id == sessionID })
    }

    func messagesForSessionActivation(_ sessionID: UUID) -> [ChatMessage] {
        runtimeMessagesSnapshot(for: sessionID) ?? []
    }

    func runtimeMessagesSnapshot(for sessionID: UUID) -> [ChatMessage]? {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return runtimeMessagesBySessionID[sessionID]
    }

    func storeRuntimeMessagesSnapshot(_ messages: [ChatMessage], for sessionID: UUID) {
        requestStateLock.lock()
        runtimeMessagesBySessionID[sessionID] = messages
        requestStateLock.unlock()
    }

    func clearRuntimeMessagesSnapshot(for sessionID: UUID) {
        requestStateLock.lock()
        runtimeMessagesBySessionID.removeValue(forKey: sessionID)
        requestStateLock.unlock()
    }

    func mutateRuntimeMessages(
        for sessionID: UUID, requireCurrentRequestIfPresent: Bool = false, requireRequestIdentity: Bool = false, requireIdle: Bool = false,
        _ mutation: (inout [ChatMessage]) -> Bool
    ) -> [ChatMessage]? {
        requestStateLock.withLock {
            if requireIdle && requestContextBySessionID[sessionID] != nil { return nil }
            if (requireRequestIdentity || (requireCurrentRequestIfPresent && ChatRequestTaskIdentity.current != nil)) && !permitsRequestWrite(sessionID: sessionID) {
                return nil
            }
            guard var messages = runtimeMessagesBySessionID[sessionID], mutation(&messages) else { return nil }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
    }

    func ownsRequestReservation(sessionID: UUID, token: UUID) -> Bool {
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID] else { return false }
            return context.token == token && !context.isCancelled
        }
    }

    @discardableResult
    func appendConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID
    ) async throws -> ChatMessage {
        try await upsertConversationMessage(message, to: sessionID)
    }

    /// 一次用户输入可能包含正文和多个附件；快照只能看到完整的一组。
    func appendConversationMessagesAtomically(_ additions: [ChatMessage], to sessionID: UUID, requestToken: UUID? = nil) throws {
        guard !additions.isEmpty else { return }
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard var messages = runtimeMessagesBySessionID[sessionID] else { return nil }
            if let requestToken {
                guard let context = requestContextBySessionID[sessionID],
                      context.token == requestToken, !context.isCancelled else { return nil }
            }
            for message in additions {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message
                } else {
                    messages.append(message)
                }
            }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { throw CancellationError() }
        publishMessagesIfCurrentSession(messages, for: sessionID)
    }

    /// Only a still-unregistered request can retract its exact, unchanged group.
    /// Attachment files may be shared and are deliberately left untouched.
    func rollbackUnsentInput(_ additions: [ChatMessage], sessionID: UUID, token: UUID, sourceRetained: Bool) -> Bool {
        let updated = requestStateLock.withLock { () -> [ChatMessage]? in
            guard let context = requestContextBySessionID[sessionID], context.token == token,
                  context.task == nil, var messages = runtimeMessagesBySessionID[sessionID],
                  ChatUnsentGroup.remove(expected: additions, messages: &messages, sourceRetained: sourceRetained,
                                         requestCancelled: true, leaseMatches: true, requestStarted: false,
                                         id: { $0.id }) else { return nil }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let updated else { return false }
        publishMessagesIfCurrentSession(updated, for: sessionID)
        return true
    }

    func reportRetainedStoppedInput(sessionID: UUID, token: UUID) {
        let updated = requestStateLock.withLock { () -> [ChatMessage]? in
            guard requestContextBySessionID[sessionID]?.token == token,
                  var messages = runtimeMessagesBySessionID[sessionID] else { return nil }
            messages.append(ChatMessage(role: .error,
                content: NSLocalizedString("请求已停止；请查看对话后再继续。", comment: "Stopped request with locally accepted input")))
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        if let updated { publishMessagesIfCurrentSession(updated, for: sessionID) }
    }

    @discardableResult
    func upsertConversationMessage(
        _ message: ChatMessage,
        to sessionID: UUID,
        afterMessageID: UUID? = nil,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) async throws -> ChatMessage {
        let storedMessage = message
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard var messages = runtimeMessagesBySessionID[sessionID] else { return nil }
            if let index = messages.firstIndex(where: { $0.id == storedMessage.id }) {
                messages[index] = storedMessage
            } else if let afterMessageID,
                      let anchorIndex = messages.firstIndex(where: { $0.id == afterMessageID }) {
                messages.insert(storedMessage, at: messages.index(after: anchorIndex))
            } else {
                messages.append(storedMessage)
            }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { throw CancellationError() }
        publishMessagesIfCurrentSession(
            messages,
            for: sessionID,
            keepingSpeedSamplesFor: preferredMessageID
        )
        await promoteSessionToTopIfNeeded(sessionID: sessionID)
        return storedMessage
    }

    @discardableResult
    func deleteConversationMessage(
        id messageID: UUID,
        from sessionID: UUID
    ) async throws -> Bool {
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard var messages = runtimeMessagesBySessionID[sessionID],
                  messages.contains(where: { $0.id == messageID }) else { return nil }
            messages.removeAll { $0.id == messageID }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { return false }
        publishMessagesIfCurrentSession(messages, for: sessionID)
        return true
    }

    /// 延后的消息增强只能修改仍存在的消息，不能在删除后重新插入。
    @discardableResult
    func updateExistingConversationMessage(
        id messageID: UUID,
        in sessionID: UUID,
        requiresRequestIdentity: Bool = false,
        update: (inout ChatMessage) -> Bool
    ) async -> Bool {
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard (!requiresRequestIdentity || permitsRequestWrite(sessionID: sessionID)),
                  var messages = runtimeMessagesBySessionID[sessionID],
                  let index = messages.firstIndex(where: { $0.id == messageID }),
                  update(&messages[index]) else { return nil }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { return false }
        publishMessagesIfCurrentSession(messages, for: sessionID)
        await promoteSessionToTopIfNeeded(sessionID: sessionID)
        return true
    }

    func updateToolResult(
        _ result: String, disposition: InternalToolCallResultDisposition,
        toolCallID: String, messageID: UUID, sessionID: UUID
    ) async {
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard permitsRequestWrite(sessionID: sessionID), var messages = runtimeMessagesBySessionID[sessionID],
                  ChatToolResultMutation.apply(
                    to: &messages, messageID: messageID, toolCallID: toolCallID,
                    result: result, disposition: disposition
                  ) else { return nil }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { return }
        publishMessagesIfCurrentSession(messages, for: sessionID)
        await promoteSessionToTopIfNeeded(sessionID: sessionID)
    }

    /// Checks at the synchronous admission point. Work admitted before a later
    /// cancellation or deletion may already be in flight.
    func permitsToolCall(_ call: InternalToolCall, messageID: UUID, sessionID: UUID) -> Bool {
        guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID else { return false }
        return permitsToolCall(call, messageID: messageID, sessionID: sessionID, token: identity.token)
    }

    /// An explicitly captured token allows the same check inside a detached SDK
    /// operation, where TaskLocal values are not inherited.
    func permitsToolCall(_ call: InternalToolCall, messageID: UUID, sessionID: UUID, token: UUID) -> Bool {
        requestStateLock.withLock {
            let calls = runtimeMessagesBySessionID[sessionID]?
                .first(where: { $0.id == messageID })?.toolCalls
            let context = requestContextBySessionID[sessionID]
            let authorized = !Task.isCancelled && ((context?.token == token && context?.isCancelled == false && context?.hasFinishedResponse == false)
                || backgroundToolRequests.contains(sessionID: sessionID, token: token))
            return ChatToolCallAdmission.permits(authorized: authorized, calls: calls) {
                $0.id == call.id && $0.toolName == call.toolName && $0.arguments == call.arguments
                    && $0.providerSpecificFields == call.providerSpecificFields
            }
        }
    }

    func recordUnknownToolOutcome(_ outcome: ChatUnknownToolOutcome) {
        requestStateLock.withLock {
            unknownToolOutcomes.record(outcome, sessionExists: runtimeMessagesBySessionID[outcome.sessionID] != nil)
        }
        publishUnknownToolOutcomes()
    }

    public func unknownToolOutcomes(for sessionID: UUID) -> [ChatUnknownToolOutcome] {
        requestStateLock.withLock { unknownToolOutcomes.snapshot()[sessionID] ?? [] }
    }

    /// Acknowledging only removes the warning; it does not execute the tool.
    @discardableResult
    public func acknowledgeUnknownToolOutcome(id: UUID, sessionID: UUID) -> Bool {
        let removed = requestStateLock.withLock { unknownToolOutcomes.acknowledge(sessionID: sessionID, id: id) }
        if removed { publishUnknownToolOutcomes() }
        return removed
    }

    private func publishUnknownToolOutcomes() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let snapshot = self.requestStateLock.withLock { self.unknownToolOutcomes.snapshot() }
            self.unknownToolOutcomesSubject.send(snapshot)
        }
    }

    func insertConversationResponseAttemptMessagesAtomically(
        _ additions: [ChatMessage],
        afterAttemptOf referenceMessageID: UUID,
        in sessionID: UUID
    ) async throws -> [ChatMessage] {
        guard !additions.isEmpty else { return messagesSnapshot(for: sessionID) }
        let messages = requestStateLock.withLock { () -> [ChatMessage]? in
            guard permitsRequestWrite(sessionID: sessionID),
                  var messages = runtimeMessagesBySessionID[sessionID],
                  let referenceIndex = messages.firstIndex(where: { $0.id == referenceMessageID }) else { return nil }
            var anchorMessageID = referenceMessageID
            // 同一回复版本可以包含多轮工具调用。迟到的后台结果必须紧随原调用，
            // 否则追加到版本末尾后，会被请求预处理当成孤立工具消息丢弃。
            var nextIndex = messages.index(after: referenceIndex)
            while nextIndex < messages.endIndex, messages[nextIndex].role == .tool {
                anchorMessageID = messages[nextIndex].id
                nextIndex += 1
            }

            for message in additions {
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index] = message
                } else if let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID }) {
                    messages.insert(message, at: messages.index(after: anchorIndex))
                } else {
                    messages.append(message)
                }
                anchorMessageID = message.id
            }
            runtimeMessagesBySessionID[sessionID] = messages
            return messages
        }
        guard let messages else { throw CancellationError() }
        publishMessagesIfCurrentSession(messages, for: sessionID)
        await promoteSessionToTopIfNeeded(sessionID: sessionID)
        return messages
    }

    func loadingMessageID(for sessionID: UUID) -> UUID? {
        withRequestStateLock {
            requestContextBySessionID[sessionID]?.loadingMessageID
        }
    }

    /// 展示层只标记尚未结束的真实请求，不能从最后一条历史回复猜测等待状态。
    public func activeResponseMessageID(for sessionID: UUID) -> UUID? {
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID], !context.hasFinishedResponse else { return nil }
            return context.loadingMessageID
        }
    }

    func conversationRunIDs(for sessionID: UUID) -> (runID: UUID, rootRunID: UUID)? {
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID],
                  ChatRequestTaskIdentity.permits(sessionID: sessionID, token: context.token),
                  let runID = context.conversationRunID,
                  let rootRunID = context.rootConversationRunID else {
                return nil
            }
            return (runID, rootRunID)
        }
    }

    func activeRequestConfiguration(for sessionID: UUID, runID: UUID? = nil) -> ConversationRunRequestConfiguration? {
        withRequestStateLock {
            if let context = requestContextBySessionID[sessionID],
               runID == nil || context.conversationRunID == runID,
               ChatRequestTaskIdentity.permits(sessionID: sessionID, token: context.token),
               !context.isCancelled, !context.hasFinishedResponse {
                return context.requestConfiguration
            }
            guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID else { return nil }
            return backgroundToolRequests.configuration(sessionID: sessionID, token: identity.token, runID: runID)
        }
    }

    static func containsActiveToolRun(
        _ contexts: [UUID: RequestExecutionContext], sessionID: UUID, runID: UUID
    ) -> Bool {
        guard let context = contexts[sessionID] else { return false }
        return context.conversationRunID == runID && !context.hasFinishedResponse && !context.isCancelled
    }

    func containsActiveToolRun(sessionID: UUID, runID: UUID) -> Bool {
        guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID,
              !Task.isCancelled else { return false }
        return containsActiveToolRun(sessionID: sessionID, runID: runID, token: identity.token)
    }

    func containsActiveToolRun(sessionID: UUID, runID: UUID, token: UUID) -> Bool {
        withRequestStateLock {
            if let context = requestContextBySessionID[sessionID], context.token == token,
               Self.containsActiveToolRun(requestContextBySessionID, sessionID: sessionID, runID: runID) { return true }
            return backgroundToolRequests.contains(sessionID: sessionID, runID: runID, token: token)
        }
    }

    /// Called only while requestStateLock is held.
    private func permitsRequestWrite(sessionID: UUID) -> Bool {
        guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID,
              !Task.isCancelled else { return false }
        if let context = requestContextBySessionID[sessionID], context.token == identity.token,
           !context.isCancelled, !context.hasFinishedResponse { return true }
        return backgroundToolRequests.contains(sessionID: sessionID, token: identity.token)
    }

    /// The background task retains the original request's run and configuration,
    /// even after the visible response has completed.
    func startBackgroundToolRequest(
        sessionID: UUID, runID: UUID?,
        makeTask: (ChatRequestStartGate) -> Task<Void, Never>
    ) -> Bool {
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID],
                  ChatRequestTaskIdentity.permits(sessionID: sessionID, token: context.token),
                  context.conversationRunID == runID,
                  !context.isCancelled, !context.hasFinishedResponse else { return false }
            let id = backgroundToolRequests.reserve(
                sessionID: sessionID, token: context.token, runID: runID, configuration: context.requestConfiguration
            )
            let startGate = ChatRequestStartGate()
            let task = makeTask(startGate)
            backgroundToolRequests.register(task, id: id, startGate: startGate)
            Task {
                await task.value
                await finishBackgroundToolRequest(id: id)
            }
            return true
        }
    }

    /// Returns true only to the caller that must perform cleanup immediately.
    func claimToolRunCleanup(sessionID: UUID, runID: UUID, state: LocalAgentRunState) -> Bool {
        withRequestStateLock {
            switch toolRunCleanups.claim(runID: runID, state: state) {
            case .existing:
                return false
            case .updated:
                _ = backgroundToolRequests.deferCleanup(sessionID: sessionID, runID: runID, state: state)
                return false
            case .claimed:
                let deferred = backgroundToolRequests.deferCleanup(sessionID: sessionID, runID: runID, state: state)
                return !deferred
            }
        }
    }

    func claimCompletedToolRunCleanup(sessionID: UUID, runID: UUID) -> Bool {
        withRequestStateLock {
            guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID,
                  runtimeMessagesBySessionID[sessionID] != nil else { return false }
            let context = requestContextBySessionID[sessionID]
            let validContext = context?.token == identity.token && context?.conversationRunID == runID && context?.isCancelled == false
            guard validContext || backgroundToolRequests.contains(sessionID: sessionID, runID: runID, token: identity.token) else { return false }
            return claimToolRunCleanup(sessionID: sessionID, runID: runID, state: .completed)
        }
    }

    func commitToolRunCleanupState(runID: UUID, fallback: LocalAgentRunState) -> LocalAgentRunState {
        withRequestStateLock { toolRunCleanups.commit(runID: runID, fallback: fallback) }
    }

    func toolRunCleanupDidFinish(runID: UUID) {
        withRequestStateLock {
            toolRunCleanups.markComplete(runID: runID)
            forgetCompletedToolRunCleanupIfUnreferenced(runID)
        }
    }

    private func forgetCompletedToolRunCleanupIfUnreferenced(_ runID: UUID) {
        let referenced = backgroundToolRequests.hasPending(runID: runID)
            || requestContextBySessionID.values.contains { $0.conversationRunID == runID }
        toolRunCleanups.forgetIfComplete(runID: runID, isReferenced: referenced)
    }

    func finishBackgroundToolRequest(id: UUID) async {
        let result = withRequestStateLock { () -> (UUID, LocalAgentRunState)? in
            backgroundToolRequests.finish(id: id)
        }
        if let (runID, state) = result {
            Task { await finishToolRunResources(runID: runID, state: state) }
        }
    }

    private func cancelBackgroundToolRequests(sessionID: UUID, token: UUID? = nil) -> [UUID] {
        withRequestStateLock {
            backgroundToolRequests.cancel(sessionID: sessionID, token: token)
        }
    }

    func hasActiveRequestContext(for sessionID: UUID) -> Bool {
        withRequestStateLock {
            requestContextBySessionID[sessionID] != nil
        }
    }

    func activeRequestSessionIDs() -> Set<UUID> {
        withRequestStateLock {
            Set(requestContextBySessionID.keys)
        }
    }

    func busySessionIDs(in sessionIDs: Set<UUID>) -> Set<UUID> {
        withRequestStateLock {
            ChatRequestSlot.busySessionIDs(in: sessionIDs, contexts: requestContextBySessionID)
        }
    }

    func publishMessagesIfCurrentSession(
        _: [ChatMessage],
        for sessionID: UUID,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        ChatMessagePublication.publish(
            sessionID: sessionID,
            selectionLock: sessionSelectionLock,
            currentSessionID: { currentSessionSubject.value?.id },
            snapshot: { runtimeMessagesSnapshot(for: $0) },
            emit: { publishMessages($0, keepingSpeedSamplesFor: preferredMessageID) }
        )
    }

    func persistAndPublishMessages(
        _ messages: [ChatMessage],
        for sessionID: UUID,
        keepingSpeedSamplesFor preferredMessageID: UUID? = nil
    ) {
        storeRuntimeMessagesSnapshot(messages, for: sessionID)
        publishMessagesIfCurrentSession(messages, for: sessionID, keepingSpeedSamplesFor: preferredMessageID)
    }

    private func withRequestStateLock<T>(_ body: () -> T) -> T {
        requestStateLock.lock()
        defer { requestStateLock.unlock() }
        return body()
    }

    /// Reserves this session before any asynchronous preparation. Different
    /// sessions can reserve independently; no input is queued or retained here.
    public func beginRequest(sessionID: UUID) -> Result<ChatRequestLease, ChatRequestAdmissionError> {
        withRequestStateLock {
            let token = UUID()
            let outcome = ChatRequestSlot.acquire(
                sessionID: sessionID,
                sessionExists: runtimeMessagesBySessionID[sessionID] != nil,
                contexts: &requestContextBySessionID
            ) {
                RequestExecutionContext(token: token, task: nil, loadingMessageID: nil,
                                        imageGenerationContext: nil, taskRegistrationPending: true)
            }
            switch outcome {
            case .busy: return .failure(.busy)
            case .sessionMissing: return .failure(.sessionMissing)
            case .acquired:
                requestTokensInFlight.insert(token)
                setSessionRunning(sessionID, isRunning: true)
                return .success(ChatRequestLease(sessionID: sessionID, token: token, service: self))
            }
        }
    }

    func releaseUnstartedRequest(sessionID: UUID, token: UUID) {
        let released = withRequestStateLock { () -> Bool in
            guard let context = requestContextBySessionID[sessionID],
                  context.token == token, context.task == nil else { return false }
            if !context.isCancelled {
                requestContextBySessionID.removeValue(forKey: sessionID)
                setSessionRunning(sessionID, isRunning: false)
            }
            return true
        }
        if released { finishRequestToken(token) }
    }

    func updateReservedRequestContext(_ context: RequestExecutionContext, for sessionID: UUID) -> Bool {
        withRequestStateLock {
            guard let current = requestContextBySessionID[sessionID],
                  current.token == context.token, !current.isCancelled else { return false }
            requestContextBySessionID[sessionID] = context
            return true
        }
    }

    func updateRequestTask(
        _ task: Task<Void, Error>, for sessionID: UUID, token: UUID, startGate: ChatRequestStartGate
    ) {
        withRequestStateLock {
            if var context = requestContextBySessionID[sessionID], context.token == token {
                context.task = task
                context.taskRegistrationPending = false
                requestContextBySessionID[sessionID] = context
                if context.isCancelled { task.cancel() }
            } else {
                task.cancel()
            }
            // Serialize opening with cancellation, deletion and token replacement.
            startGate.open()
        }
    }

    func updateRequestLoadingMessageID(_ loadingMessageID: UUID, for sessionID: UUID) {
        withRequestStateLock {
            guard var context = requestContextBySessionID[sessionID],
                  ChatRequestTaskIdentity.permits(sessionID: sessionID, token: context.token) else { return }
            context.loadingMessageID = loadingMessageID
            requestContextBySessionID[sessionID] = context
        }
    }

    func clearRequestContextIfNeeded(for sessionID: UUID, token: UUID) {
        defer { finishRequestToken(token) }
        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID], context.token == token,
                  !context.isCancelled else { return }
            requestContextBySessionID[sessionID]?.hasFinishedResponse = true
            setSessionRunning(sessionID, isRunning: false)
            // The cancelling caller owns removal until its stop flow has returned.
            requestContextBySessionID.removeValue(forKey: sessionID)
            if let runID = context.conversationRunID { forgetCompletedToolRunCleanupIfUnreferenced(runID) }
        }
    }

    private func finishRequestToken(_ token: UUID) {
        let waiters = withRequestStateLock { () -> [CheckedContinuation<Void, Never>] in
            requestTokensInFlight.remove(token)
            return requestCompletionWaiters.removeValue(forKey: token) ?? []
        }
        waiters.forEach { $0.resume() }
    }

    private func waitForRequestToken(_ token: UUID) async {
        await withCheckedContinuation { continuation in
            let registered = withRequestStateLock { () -> Bool in
                guard requestTokensInFlight.contains(token) else { return false }
                requestCompletionWaiters[token, default: []].append(continuation)
                return true
            }
            if !registered { continuation.resume() }
        }
    }

    /// 会话删除是同步操作，先移除并取消请求上下文，避免已删除会话继续接收异步回写。
    func cancelRequestForSessionDeletion(_ sessionID: UUID) {
        let (context, immediateRunIDs) = withRequestStateLock {
            unknownToolOutcomes.removeSession(sessionID)
            let context = requestContextBySessionID.removeValue(forKey: sessionID)
            context?.task?.cancel()
            let runIDs = cancelBackgroundToolRequests(sessionID: sessionID)
            let allRuns = Set(runIDs + [context?.conversationRunID].compactMap { $0 })
            let immediate = allRuns.filter { claimToolRunCleanup(sessionID: sessionID, runID: $0, state: .cancelled) }
            runtimeMessagesBySessionID.removeValue(forKey: sessionID)
            if let runID = context?.conversationRunID { forgetCompletedToolRunCleanupIfUnreferenced(runID) }
            return (context, immediate)
        }
        publishUnknownToolOutcomes()
        if let context, context.task == nil { finishRequestToken(context.token) }
        Task {
            await LocalLinuxJobScheduler.shared.cancel(sessionID: sessionID)
            for runID in immediateRunIDs {
                await finishToolRunResources(runID: runID, state: .cancelled)
            }
        }
        setSessionRunning(sessionID, isRunning: false)
        // 删除路径不会再经过正常请求终态；显式释放通知上下文，避免后台保活悬挂。
        if context != nil,
           currentSessionSubject.value?.id == sessionID || chatSessionsSubject.value.contains(where: { $0.id == sessionID }) {
            sessionRequestStatusSubject.send(SessionRequestStatusEvent(
                sessionID: sessionID, status: .cancelled, messages: []
            ))
        }
    }

    private func setSessionRunning(_ sessionID: UUID, isRunning: Bool) {
        withRequestStateLock {
            var running = runningSessionIDsSubject.value
            let changed: Bool
            if isRunning {
                changed = running.insert(sessionID).inserted
            } else {
                changed = running.remove(sessionID) != nil
            }
            guard changed else { return }
            runningSessionIDsSubject.send(running)
        }
    }

    func emitSessionRequestStatus(_ status: SessionRequestStatus, sessionID: UUID, token: UUID? = nil) {
        if token == nil, let identity = ChatRequestTaskIdentity.current, identity.sessionID != sessionID { return }
        let expectedToken = token ?? ChatRequestTaskIdentity.current.flatMap { $0.sessionID == sessionID ? $0.token : nil }
        let eventContext = withRequestStateLock { () -> (UUID?, UUID?, UUID?, LocalAgentRunState?)? in
            let context = requestContextBySessionID[sessionID]
            if let expectedToken, context?.token != expectedToken { return nil }
            switch status {
            case .started: break
            case .finished, .error:
                if !Task.isCancelled {
                    requestContextBySessionID[sessionID]?.hasFinishedResponse = true
                    setSessionRunning(sessionID, isRunning: false)
                }
            case .cancelled:
                if !Task.isCancelled { setSessionRunning(sessionID, isRunning: false) }
            }
            var cleanupNow: LocalAgentRunState?
            if (status == .error || status == .cancelled), let token = context?.token {
                _ = cancelBackgroundToolRequests(sessionID: sessionID, token: token)
                if let runID = context?.conversationRunID {
                    let state: LocalAgentRunState = status == .error ? .failed : .cancelled
                    if claimToolRunCleanup(sessionID: sessionID, runID: runID, state: state) { cleanupNow = state }
                }
            }
            return (context?.token, context?.conversationRunID, context?.rootConversationRunID, cleanupNow)
        }
        guard let eventContext else { return }
        let requestToken = eventContext.0
        if let state = eventContext.3, let runID = eventContext.1 {
            Task { await finishToolRunResources(runID: runID, state: state) }
        }

        // 快速重试已接管时，旧完成事件不能结束新一轮的通知和实时活动。
        if expectedToken != nil || status == .finished || status == .error,
           let requestToken,
           !withRequestStateLock({ requestContextBySessionID[sessionID]?.token == requestToken }) {
            return
        }
        // 发布通知与实时活动前再次检查身份，按钮已通过运行集合提前恢复。
        let isVisibleSession = currentSessionSubject.value?.id == sessionID
            || chatSessionsSubject.value.contains(where: { $0.id == sessionID })
        if isVisibleSession {
            // 请求结束前运行时快照仍在内存中；此处只复制数组引用，不回读数据库或等待 UI 预处理。
            let messages = status == .started || status == .finished
                ? (currentSessionSubject.value?.id == sessionID
                   ? messagesForSessionSubject.value : (runtimeMessagesSnapshot(for: sessionID) ?? []))
                : []
            sessionRequestStatusSubject.send(SessionRequestStatusEvent(
                sessionID: sessionID, status: status, messages: messages
            ))
            switch status {
            case .started:
                requestStatusSubject.send(.started)
            case .finished:
                requestStatusSubject.send(.finished)
            case .error:
                requestStatusSubject.send(.error)
            case .cancelled:
                requestStatusSubject.send(.cancelled)
            }
        }
    }

    // MARK: - 初始化
    
    public init(roleplayStore: RoleplayStore = .shared) {
        logger.info("ChatService 正在初始化...")

        self.roleplayStore = roleplayStore
        ConfigLoader.setupInitialProviderConfigs()
        ConfigLoader.setupBackgroundsDirectory()
        self.providers = ConfigLoader.loadProviders()
        let startupTemporarySession = ChatSession(
            id: UUID(),
            name: NSLocalizedString("新的对话", comment: "Default new chat session name"),
            isTemporary: true
        )


        self.providersSubject = CurrentValueSubject(self.providers)
        self.selectedModelSubject = CurrentValueSubject(nil)
        self.chatSessionsSubject = CurrentValueSubject(
            [startupTemporarySession]
        )
        self.sessionFoldersSubject = CurrentValueSubject(
            []
        )
        self.sessionTagsSubject = CurrentValueSubject(
            []
        )
        self.currentSessionSubject = CurrentValueSubject(
            startupTemporarySession
        )
        self.messagesForSessionSubject = CurrentValueSubject(
            []
        )
        self.runtimeMessagesBySessionID[startupTemporarySession.id] = []
        self.reconcileStoredModelOrder()
        self.reconcileStoredProviderOrder()
        NotificationCenter.default.publisher(for: .officialDataDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadProviders()
            }
            .store(in: &cancellables)

        let savedModelID = AppConfigStore.textValue(
            for: .selectedRunnableModelID,
            legacyUserDefaultsKey: Self.selectedRunnableModelStorageKey
        )
        let allRunnable = activatedConversationModels
        var initialModel: RunnableModel? = allRunnable.first { $0.id == savedModelID }
        if initialModel == nil {
            initialModel = allRunnable.first
        }
        self.selectedModelSubject.send(initialModel)

        ConfigLoader.fetchDownloadOnceConfigsIfNeeded()

        logger.info("  - 初始选中模型为: \(initialModel?.model.displayName ?? "无")")
        logger.info("  - 初始化完成。")
    }

    /// 删除正在生成的占位消息前先终止对应请求，避免后续 Token
    /// 持续与消息列表删除竞争。
    public func cancelRequestIfGenerating(messageID: UUID, in sessionID: UUID) async {
        guard loadingMessageID(for: sessionID) == messageID else { return }
        await cancelRequest(for: sessionID)
    }

    /// 取消指定会话正在进行的请求，并进行必要的状态恢复。
    public func cancelRequest(for sessionID: UUID) async {
        let cancellation = withRequestStateLock { () -> (RequestExecutionContext, UUID?)? in
            guard var context = requestContextBySessionID[sessionID], !context.isCancelled,
                  context.task != nil || context.taskRegistrationPending else { return nil }
            context.isCancelled = true
            requestContextBySessionID[sessionID] = context
            context.task?.cancel()
            if context.hasFinishedResponse {
                let runID = context.conversationRunID
                let shouldClean = runID.map {
                    claimToolRunCleanup(sessionID: sessionID, runID: $0, state: .completed)
                } ?? false
                return (context, shouldClean ? runID : nil)
            }
            _ = cancelBackgroundToolRequests(sessionID: sessionID, token: context.token)
            return (context, nil)
        }
        guard let (cancelledContext, completedCleanupRunID) = cancellation else { return }
        if let completedCleanupRunID {
            Task { await finishToolRunResources(runID: completedCleanupRunID, state: .completed) }
        }
        if !cancelledContext.hasFinishedResponse {
            if let runID = cancelledContext.conversationRunID {
                await LocalLinuxJobScheduler.shared.cancel(runID: runID)
            } else {
                await LocalLinuxJobScheduler.shared.cancel(sessionID: sessionID)
            }
            emitSessionRequestStatus(.cancelled, sessionID: sessionID, token: cancelledContext.token)

            if let imageContext = cancelledContext.imageGenerationContext {
                imageGenerationStatusSubject.send(
                    .cancelled(
                        sessionID: imageContext.sessionID,
                        loadingMessageID: imageContext.loadingMessageID,
                        prompt: imageContext.prompt,
                        finishedAt: Date()
                    )
                )
            }
        }

        if let task = cancelledContext.task {
            do {
                try await task.value
            } catch is CancellationError {
                logger.info("用户已手动取消会话请求: \(sessionID.uuidString)")
            } catch {
                // URLError.cancelled 不会匹配 CancellationError，需要单独检测
                if isCancellationError(error) {
                    logger.info("用户已手动取消会话请求 (URLError): \(sessionID.uuidString)")
                } else {
                    logger.error("取消会话请求时出现意外错误: \(error.localizedDescription)")
                }
            }
        }
        // The sender releases the token after its own preparation/task cleanup.
        // A cancelled context remains installed until this stop owner finishes.
        await waitForRequestToken(cancelledContext.token)

        if !cancelledContext.hasFinishedResponse, let loadingID = cancelledContext.loadingMessageID {
            await finalizeInterruptedReasoningMessageIfNeeded(loadingMessageID: loadingID, in: sessionID)
            if shouldRemoveLoadingMessageOnCancel(loadingMessageID: loadingID, in: sessionID) {
                await removeMessage(withID: loadingID, in: sessionID)
            }
        }

        withRequestStateLock {
            guard let context = requestContextBySessionID[sessionID],
                  context.token == cancelledContext.token else {
                return
            }
            setSessionRunning(sessionID, isRunning: false)
            requestContextBySessionID.removeValue(forKey: sessionID)
            if let runID = context.conversationRunID { forgetCompletedToolRunCleanupIfUnreferenced(runID) }
        }
    }

    /// 兼容旧调用：取消当前会话请求。
    public func cancelOngoingRequest() async {
        if let currentSessionID = currentSessionSubject.value?.id {
            await cancelRequest(for: currentSessionID)
            return
        }
        let sessionIDs = withRequestStateLock { Array(requestContextBySessionID.keys) }
        for sessionID in sessionIDs {
            await cancelRequest(for: sessionID)
        }
    }

}
