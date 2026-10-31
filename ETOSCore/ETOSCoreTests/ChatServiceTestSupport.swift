// ============================================================================
// ChatServiceTestSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 集成测试共用的模拟适配器与轻量响应结构。
// ============================================================================

import Foundation
@testable import ETOSCore

final class MockAPIAdapter: APIAdapter {
    let requiresExplicitStreamingTermination = false

    var receivedMessages: [ChatMessage]?
    var receivedTitleMessages: [ChatMessage]?
    var receivedReasoningSummaryMessages: [ChatMessage]?
    var receivedTools: [InternalToolDefinition]?
    var receivedAudioAttachments: [UUID: AudioAttachment]?
    var receivedImageAttachments: [UUID: [ImageAttachment]]?
    var receivedFileAttachments: [UUID: [FileAttachment]]?
    var responseToReturn: ChatMessage?
    var receivedChatModel: RunnableModel?
    var receivedTitleModel: RunnableModel?
    var receivedReasoningSummaryModel: RunnableModel?
    var receivedChatStreamFlags: [Bool] = []
    var receivedTranscriptionModel: RunnableModel?
    var transcriptionRequestURL: URL?
    var transcriptionResponseToReturn = ""

    func buildChatRequest(for model: RunnableModel, commonPayload: [String : Any], messages: [ChatMessage], tools: [InternalToolDefinition]?, audioAttachments: [UUID: AudioAttachment], imageAttachments: [UUID: [ImageAttachment]], fileAttachments: [UUID: [FileAttachment]]) -> URLRequest? {
        let firstContent = messages.first?.content
        if firstContent == BuiltInPromptStore.render(.reasoningSummarySystem) {
            receivedReasoningSummaryMessages = messages
            receivedReasoningSummaryModel = model
            return URLRequest(url: URL(string: "https://fake.url/reasoning-summary")!)
        } else if messages.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            receivedTitleMessages = messages
            receivedTitleModel = model
            return URLRequest(url: URL(string: "https://fake.url/title-gen")!)
        } else {
            receivedMessages = messages
            receivedTools = tools
            receivedAudioAttachments = audioAttachments
            receivedImageAttachments = imageAttachments
            receivedFileAttachments = fileAttachments
            receivedChatModel = model
            if let stream = commonPayload["stream"] as? Bool {
                receivedChatStreamFlags.append(stream)
            }
            return URLRequest(url: URL(string: "https://fake.url/chat")!)
        }
    }

    func parseResponse(data: Data) throws -> ChatMessage {
        if let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
           let content = response.choices.first?.message.content {
            return ChatMessage(role: .assistant, content: content)
        }

        if let received = receivedMessages, received.first?.content.contains("为本次对话生成一个简短、精炼的标题") == true {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            let content = response.choices.first?.message.content ?? ""
            return ChatMessage(role: .assistant, content: content)
        }

        return responseToReturn ?? ChatMessage(role: .assistant, content: "Default mock response")
    }

    func buildTranscriptionRequest(
        for model: RunnableModel,
        audioData: Data,
        fileName: String,
        mimeType: String,
        language: String?
    ) -> URLRequest? {
        receivedTranscriptionModel = model
        return transcriptionRequestURL.map { URLRequest(url: $0) }
    }

    func parseTranscriptionResponse(data: Data) throws -> String {
        transcriptionResponseToReturn
    }

    func buildModelListRequest(for provider: Provider) -> URLRequest? { nil }
    func parseStreamingResponse(line: String) -> ChatMessagePart? { nil }
}
