import Foundation
import Combine
import Testing
@testable import ETOSCore

@Suite("自动重试策略")
struct ChatRequestRetryPolicyTests {
    @Test("关闭智能判断时所有请求错误可重试，但主动取消及拒绝连接仍然终止")
    func allErrorsRetryPolicy() {
        let errors: [Error] = [
            ChatService.NetworkError.badStatusCode(code: 400, responseBody: nil),
            ChatService.NetworkError.badStatusCode(code: 401, responseBody: nil),
            URLError(.badServerResponse), URLError(.cannotDecodeContentData),
            NSError(domain: "APIAdapterError", code: 1)
        ]
        for error in errors {
            #expect(ChatRequestRetryPolicy.isRetryable(error, smartDetectionEnabled: false))
        }
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled), NetworkConnectionSecurityError.denied]
        for error in cancellations {
            #expect(!ChatRequestRetryPolicy.isRetryable(error, smartDetectionEnabled: false))
        }
    }

    @Test("指数退避有上限，仅临时网络与服务错误可重试")
    func retryPolicy() {
        #expect((1...8).map(ChatRequestRetryPolicy.delay) == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(ChatRequestRetryPolicy.isRetryable(URLError(.networkConnectionLost)))
        #expect(ChatRequestRetryPolicy.isRetryable(URLError(.timedOut)))
        #expect(!ChatRequestRetryPolicy.isRetryable(URLError(.cancelled)))
        #expect(!ChatRequestRetryPolicy.isRetryable(URLError(.serverCertificateUntrusted)))
        #expect(!ChatRequestRetryPolicy.isRetryable(CancellationError()))
        for code in [408, 429, 500, 502, 503, 504, 529] {
            #expect(ChatRequestRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: code, responseBody: nil)))
        }
        for code in [400, 401, 403, 404, 422] {
            #expect(!ChatRequestRetryPolicy.isRetryable(ChatService.NetworkError.badStatusCode(code: code, responseBody: nil)))
        }
    }

    @Test("重试配置有默认值和边界，运行状态不写入历史，向导包含对应说明")
    func retrySettingsAndTransientState() throws {
        #expect(AppConfigKey.maximumRequestRetries.defaultValue == .integer(3))
        #expect(AppConfigKey.requestRetrySmartDetectionEnabled.defaultValue == .bool(true))
        #expect(AppConfigStore.normalizedIntegerValue(-1, for: .maximumRequestRetries) == 0)
        #expect(AppConfigStore.normalizedIntegerValue(100, for: .maximumRequestRetries) == 10)
        var message = ChatMessage(role: .assistant, content: "前缀")
        let previous = message
        message.requestRetryStatus = ChatRequestRetryStatus(attempt: 2, maximumAttempts: 3, remainingSeconds: 2)
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: previous, to: message))
        let waiting = message
        message.requestRetryStatus = ChatRequestRetryStatus(attempt: 2, maximumAttempts: 3, remainingSeconds: 1)
        #expect(!ETStreamingMessageUpdatePolicy.isTextOnlyChange(from: waiting, to: message))
        let encoded = try JSONEncoder().encode(message)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("requestRetryStatus"))
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded).requestRetryStatus == nil)
        #expect(GuideDocumentCatalog.documents.first { $0.id == "settings-core" }?.content.contains("maximum_request_retries") == true)
        #expect(GuideDocumentCatalog.documents.first { $0.id == "settings-core" }?.content.contains("request_retry_smart_detection") == true)
    }
}
