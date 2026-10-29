import ETOSCore
import Foundation

struct MacChatRequestConfiguration {
    let temperature: Double
    let topP: Double
    let historyLimit: Int
    let streaming: Bool
    let systemTime: Bool
    let timePosition: SystemTimeInjectionPosition
    let timeLandmark: Bool
    let timeLandmarkMinutes: Int
    let speedMetrics: Bool

    @MainActor
    init(_ configuration: AppConfigStore, session: ChatSession) {
        temperature = configuration.aiTemperature
        topP = configuration.aiTopP
        historyLimit = configuration.maxChatHistory
        streaming = configuration.enableStreaming
        systemTime = configuration.includeSystemTimeInPrompt
        timePosition = SystemTimeInjectionPosition(rawValue: configuration.systemTimeInjectionPosition) ?? .front
        timeLandmark = configuration.enablePeriodicTimeLandmark
        timeLandmarkMinutes = configuration.periodicTimeLandmarkIntervalMinutes
        speedMetrics = configuration.enableResponseSpeedMetrics
    }

    func send(_ content: String, attachments: [MacComposerAttachment] = [], audioAttachment: AudioAttachment? = nil,
              through service: ChatService, sessionID: UUID, onMessagesPrepared: ChatSendPresentationHandler? = nil,
              requestLease: ChatRequestLease, onInputAccepted: ChatInputAcceptanceHandler? = nil) async {
        await service.sendAndProcessMessage(
            content: content, aiTemperature: temperature, aiTopP: topP,
            maxChatHistory: historyLimit,
            enableStreaming: streaming,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, audioAttachment: audioAttachment, imageAttachments: attachments.compactMap(\.image),
            fileAttachments: attachments.compactMap(\.file), targetSessionID: sessionID, onMessagesPrepared: onMessagesPrepared,
            requestLease: requestLease, onInputAccepted: onInputAccepted
        )
    }

    func retry(_ message: ChatMessage, through service: ChatService, sessionID: UUID, prefill: Bool) async {
        await service.retryMessage(
            message, aiTemperature: temperature, aiTopP: topP,
            maxChatHistory: historyLimit, enableStreaming: streaming,
            includeSystemTime: systemTime, systemTimeInjectionPosition: timePosition,
            enablePeriodicTimeLandmark: timeLandmark, periodicTimeLandmarkIntervalMinutes: timeLandmarkMinutes,
            enableResponseSpeedMetrics: speedMetrics, prefill: prefill, targetSessionID: sessionID
        )
    }
}
