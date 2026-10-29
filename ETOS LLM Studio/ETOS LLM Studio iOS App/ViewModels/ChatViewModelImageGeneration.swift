// ============================================================================
// ChatViewModelImageGeneration.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatViewModel 中生图模型入口、状态反馈和生成结果管理。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

extension ChatViewModel {
    var imageGenerationModelOptions: [RunnableModel] {
        activatedModels.filter { supportsImageGeneration(for: $0) }
    }

    var supportsImageGenerationForSelectedModel: Bool {
        supportsImageGeneration(for: selectedModel)
    }

    func supportsImageGeneration(for runnableModel: RunnableModel?) -> Bool {
        guard let runnableModel else { return false }
        return runnableModel.model.usesDedicatedImageGenerationEndpoint
    }

    func imageGenerationModel(with identifier: String) -> RunnableModel? {
        guard !identifier.isEmpty else { return nil }
        return imageGenerationModelOptions.first(where: { $0.id == identifier })
    }

    func generateImage(
        prompt: String,
        referenceImages: [ImageAttachment] = [],
        model: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        guard let targetSessionID = currentSession?.id else {
            messageEditErrorMessage = NSLocalizedString("会话已不存在，内容未发送。", comment: "Missing send session")
            return
        }
        let lease: ChatRequestLease
        switch chatService.beginRequest(sessionID: targetSessionID) {
        case .success(let acquired): lease = acquired
        case .failure(.busy):
            messageEditErrorMessage = NSLocalizedString("当前会话正在处理，请稍后再发送。", comment: "Session busy")
            return
        case .failure(.sessionMissing):
            messageEditErrorMessage = NSLocalizedString("会话已不存在，内容未发送。", comment: "Missing send session")
            return
        }
        Task { [weak self] in
            guard let self else { lease.release(); return }
            await chatService.generateImageAndProcessMessage(
                prompt: prompt,
                imageAttachments: referenceImages,
                runnableModel: model,
                runtimeOverrideParameters: runtimeOverrideParameters,
                targetSessionID: targetSessionID,
                requestLease: lease
            )
        }
    }

    func clearImageGenerationFeedback() {
        imageGenerationFeedback = .idle
    }

    func retryLastImageGeneration(
        model: RunnableModel? = nil,
        referenceImages: [ImageAttachment] = [],
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        messageEditErrorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
    }

    func removeImageAttachment(fileName: String, fromMessageID messageID: UUID) {
        guard let sessionID = currentSession?.id,
              let expected = findMessage(by: messageID) else { return }
        if !chatService.removeImageAttachment(fileName: fileName, from: expected, sessionID: sessionID) {
            reportMessageEditFailure()
        }
    }

    func removeGeneratedImage(fileName: String, fromMessageID messageID: UUID) {
        removeImageAttachment(fileName: fileName, fromMessageID: messageID)
    }

    @discardableResult
    func convertMarkdownImagesToDisplayAttachments(in message: ChatMessage) async -> Int {
        guard let sessionID = currentSession?.id else { return 0 }
        let extraction = await chatService.extractInlineImagesFromMarkdown(message.content)
        guard !extraction.imageFileNames.isEmpty else { return 0 }

        guard let expected = chatService.messagesSnapshot(for: sessionID).first(where: { $0.id == message.id }),
              expected.content == message.content else {
            let orphanedFileNames = extraction.imageFileNames
            await Task.detached(priority: .utility) {
                for fileName in orphanedFileNames {
                    Persistence.deleteImage(fileName: fileName)
                }
            }.value
            return 0
        }

        var updatedMessage = expected
        updatedMessage.content = extraction.cleanedContent
        updatedMessage.imageFileNames = (updatedMessage.imageFileNames ?? []) + extraction.imageFileNames
        updatedMessage.modelExcludedImageFileNames =
            (updatedMessage.modelExcludedImageFileNames ?? []) + extraction.imageFileNames
        guard updateMessage(updatedMessage, expected: expected, sessionID: sessionID) else {
            let orphanedFileNames = extraction.imageFileNames
            await Task.detached(priority: .utility) {
                for fileName in orphanedFileNames {
                    Persistence.deleteImage(fileName: fileName)
                }
            }.value
            return 0
        }
        return extraction.imageFileNames.count
    }

    func applyImageGenerationStatus(_ status: ChatService.ImageGenerationStatus) {
        switch status {
        case .started(let sessionID, _, let prompt, let startedAt, let referenceCount):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .running,
                prompt: prompt,
                startedAt: startedAt,
                finishedAt: nil,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: referenceCount
            )
        case .succeeded(let sessionID, _, let prompt, let imageFileNames, let finishedAt):
            guard sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .success,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: imageFileNames.count,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .failed(let sessionID, _, let prompt, let reason, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .failure,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: reason,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        case .cancelled(let sessionID, _, let prompt, let finishedAt):
            guard sessionID == nil || sessionID == currentSession?.id else { return }
            imageGenerationFeedback = ImageGenerationFeedback(
                phase: .cancelled,
                prompt: prompt,
                startedAt: imageGenerationFeedback.startedAt,
                finishedAt: finishedAt,
                imageCount: 0,
                errorMessage: nil,
                referenceCount: imageGenerationFeedback.referenceCount
            )
        @unknown default:
            imageGenerationFeedback = .idle
        }
    }
}
