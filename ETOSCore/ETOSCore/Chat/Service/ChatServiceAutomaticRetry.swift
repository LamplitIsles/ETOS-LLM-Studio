import Foundation

public struct ChatRequestRetryStatus: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case automatic
        case apiKey
    }

    public let kind: Kind
    public let attempt: Int
    public let maximumAttempts: Int
    /// 仅退避等待期间有值，请求发出后不再显示倒计时。
    public let remainingSeconds: Int?

    init(attempt: Int, maximumAttempts: Int, remainingSeconds: Int? = nil, kind: Kind = .automatic) {
        self.kind = kind
        self.attempt = attempt
        self.maximumAttempts = maximumAttempts
        self.remainingSeconds = remainingSeconds
    }

    public var thinkingText: String {
        if kind == .apiKey {
            return String(format: NSLocalizedString("正在思考·切换 Key(%d/%d)", comment: ""), attempt, maximumAttempts)
        }
        if let remainingSeconds {
            return String(
                format: NSLocalizedString("正在思考·重试(%d/%d)·%ds", comment: ""),
                attempt, maximumAttempts, remainingSeconds
            )
        }
        return String(format: NSLocalizedString("正在思考·重试(%d/%d)", comment: ""), attempt, maximumAttempts)
    }
}

public enum ChatRequestRetryPolicy {
    public static let defaultMaximumRetries = 3
    public static let allowedMaximumRetries = 0...10

    static func maximumRetries(from text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(text), allowedMaximumRetries.contains(count) else { return nil }
        return count
    }

    static func delay(forRetry retry: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, min(retry - 1, 5)))))
    }

    static func isRetryable(_ error: Error, smartDetectionEnabled: Bool = true) -> Bool {
        // 用户主动停止或拒绝连接仍然结束请求，不受错误筛选开关影响。
        guard !(error is CancellationError), !NetworkConnectionSecurityError.isRejection(error) else { return false }
        guard smartDetectionEnabled else { return true }
        if case ChatService.NetworkError.badStatusCode(let code, _) = error {
            return [408, 429, 500, 502, 503, 504, 529].contains(code)
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .networkConnectionLost, .notConnectedToInternet].contains { $0.rawValue == nsError.code }
    }
}

extension ChatService {
    /// The legacy provider path performs one request. A transport failure does
    /// not prove that a provider did not execute it, so it is never replayed.
    func performSingleChatProviderRequest(
        request: URLRequest,
        loadingMessageID: UUID,
        requestLogContext: RequestLogContext,
        operation: (URLRequest, UUID, RequestLogContext, @escaping (Error) async -> Bool) async -> Void
    ) async {
        RequestTransactionLogRegistry.bindRequest(
            request, requestID: requestLogContext.requestID,
            requestedAt: requestLogContext.requestedAt, providerName: requestLogContext.providerName,
            modelID: requestLogContext.modelID, isStreaming: requestLogContext.isStreaming
        )
        await ChatSingleProviderRequest.run(request: request, loadingID: loadingMessageID,
                                            context: requestLogContext, operation: operation)
    }

    func setRequestRetryStatus(_ status: ChatRequestRetryStatus?, messageID: UUID, sessionID: UUID) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].requestRetryStatus != status else { return }
        messages[index].requestRetryStatus = status
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }

    private func resetPartialResponseForRetry(messageID: UUID, sessionID: UUID, prefix: String) {
        var messages = messagesSnapshot(for: sessionID)
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].content = prefix
        if prefix.isEmpty { messages[index].reasoningContent = nil }
        messages[index].toolCalls = nil
        messages[index].toolCallsPlacement = nil
        messages[index].reasoningProviderSpecificFields = nil
        messages[index].providerResponseMetadata = nil
        messages[index].responseMetrics = nil
        messages[index].tokenUsage = nil
        messages[index].costEstimate = nil
        _ = publishStreamingMessages(messages, loadingMessageID: messageID, sessionID: sessionID)
    }
}
