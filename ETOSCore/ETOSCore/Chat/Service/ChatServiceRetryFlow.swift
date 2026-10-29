// ============================================================================
// ChatServiceRetryFlow.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的消息重试、续写重试、附件恢复与重试请求任务启动。
// ============================================================================

import Foundation
import Combine
import os.log

public enum ChatRetryAvailability: Sendable {
    case unavailable
}

extension ChatService {
    /// 旧本地回答重试暂不可用；未来聊天能力由后端协议决定。
    @discardableResult
    public func retryMessage(
        _ message: ChatMessage,
        aiTemperature: Double,
        aiTopP: Double,
        maxChatHistory: Int,
        enableStreaming: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true,
        prefill: Bool = false,
        targetSessionID: UUID? = nil,
        requestLease: ChatRequestLease? = nil
    ) async -> ChatRetryAvailability {
        .unavailable
    }

    @discardableResult
    public func retryLastMessage(
        aiTemperature: Double,
        aiTopP: Double,
        maxChatHistory: Int,
        enableStreaming: Bool,
        includeSystemTime: Bool,
        systemTimeInjectionPosition: SystemTimeInjectionPosition = .front,
        enablePeriodicTimeLandmark: Bool = false,
        periodicTimeLandmarkIntervalMinutes: Int = 30,
        enableResponseSpeedMetrics: Bool = true
    ) async -> ChatRetryAvailability {
        .unavailable
    }

}
