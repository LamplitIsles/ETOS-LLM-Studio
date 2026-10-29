import Foundation
import os.log

/// 后台准备仅接收值，不接触 ChatService 的会话状态、发布器或 UI 回执。
struct ChatSendMessagePreparation: Sendable {
    let failures: [ChatAttachmentPreparation.Failure]
    let content: String
    let requestedAt: Date
    let messages: [ChatMessage]
    let primaryMessage: ChatMessage?
    let imageFileNames: [String]
    let messageIDsBySource: [ChatSendPresentationSource: UUID]

    static func prepare(
        content: String,
        audioAttachment: AudioAttachment?,
        imageAttachments: [ImageAttachment],
        fileAttachments: [FileAttachment],
        placeholders: (audio: String, image: String, file: String, video: String),
        authorKind: ConversationMessageAuthorKind,
        sourceSessionID: UUID?,
        sourceMessageID: UUID?,
        conversationEventID: UUID?
    ) -> Self {
        let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatSendMessagePreparation")
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageContent = MessageRegexRuleTransformer.apply(
            trimmedContent, rules: MessageRegexRuleStore.currentRules(), scope: .user, mode: .persist
        )
        let requestTimestamp = Date()
        var messages: [ChatMessage] = []
        var primaryMessage: ChatMessage?
        var messageIDsBySource: [ChatSendPresentationSource: UUID] = [:]
        let audioFileName: String? = audioAttachment.map { attachment in
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return String(format: NSLocalizedString("语音_%@.%@", comment: "Generated audio attachment file name"),
                          dateFormatter.string(from: Date()), attachment.format)
        }
        let saved = ChatAttachmentPreparation.prepare(
            audio: audioAttachment, audioFileName: audioFileName, images: imageAttachments, files: fileAttachments,
            saveAudio: { Persistence.saveAudio($0, fileName: $1) != nil },
            saveImage: { Persistence.saveImage($0, fileName: $1) != nil },
            saveFile: { Persistence.saveFileDeduplicatingByName($0, preferredFileName: $1) }
        )
        let savedAudioFileName = saved.audioFileName
        let savedImages = saved.images
        let savedFiles = saved.files.map { file in
            (fileName: file.fileName, isVideo: VideoAttachmentSupport.isVideo(file.attachment), source: ChatSendPresentationSource.file(file.attachment.id))
        }
        if !saved.failures.isEmpty { logger.error("保存一个或多个输入附件失败。") }

        // 保存与消息发布的分组顺序保持一致；同名复用仍按每个来源身份分别建消息。
        if let savedAudioFileName, let audioAttachment {
            let message = ChatMessage(
                role: .user, content: placeholders.audio, requestedAt: requestTimestamp,
                audioFileName: savedAudioFileName, authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[.audio(audioAttachment.id)] = message.id
        }
        for image in savedImages {
            let message = ChatMessage(
                role: .user, content: placeholders.image, requestedAt: requestTimestamp,
                imageFileNames: [image.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[image.source] = message.id
        }
        for file in savedFiles where file.isVideo {
            let message = ChatMessage(
                role: .user, content: placeholders.video, requestedAt: requestTimestamp,
                fileFileNames: [file.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[file.source] = message.id
        }
        for file in savedFiles where !file.isVideo {
            let message = ChatMessage(
                role: .user, content: placeholders.file, requestedAt: requestTimestamp,
                fileFileNames: [file.fileName], authorKind: authorKind,
                sourceSessionID: sourceSessionID, sourceMessageID: sourceMessageID,
                conversationEventID: conversationEventID
            )
            messages.append(message)
            messageIDsBySource[file.source] = message.id
        }
        if !messageContent.isEmpty {
            let message = ChatMessage(
                role: .user, content: messageContent, requestedAt: requestTimestamp,
                authorKind: authorKind, sourceSessionID: sourceSessionID,
                sourceMessageID: sourceMessageID, conversationEventID: conversationEventID
            )
            messages.append(message)
            primaryMessage = message
            messageIDsBySource[.text] = message.id
        }
        return Self(
            failures: saved.failures, content: messageContent, requestedAt: requestTimestamp,
            messages: messages, primaryMessage: primaryMessage,
            imageFileNames: savedImages.map(\.fileName), messageIDsBySource: messageIDsBySource
        )
    }
}
