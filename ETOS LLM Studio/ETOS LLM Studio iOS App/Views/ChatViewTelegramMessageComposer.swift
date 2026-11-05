// ============================================================================
// ChatViewTelegramMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中 Telegram 风格的新输入栏组件。
// ============================================================================

import SwiftUI
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ETOSCore

struct CFLComposerState {
    let canSend: Bool
    let isSubmitting: Bool
    let isResponding: Bool
    var hasImages: Bool = false
}

/// Telegram 风格的消息输入框
struct TelegramMessageComposer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @ObservedObject var appConfig = AppConfigStore.shared
    @Binding var text: String
    var isSendActionPending: Bool { cflState.isSubmitting }
    var isSending: Bool { cflState.isResponding }
    var composerCanSend: Bool { cflState.canSend }
    var composerSupportsSpeech: Bool { appConfig.enableSpeechInput }
    private var composerRecordingFormat: AudioRecordingFormat {
        AudioRecordingFormat(rawValue: appConfig.audioRecordingFormat) ?? .aac
    }
    let sendAction: () -> Bool
    let stopAction: () -> Void
    let focus: Binding<Bool>
    var availableHeight: CGFloat = .infinity
    var cflState: CFLComposerState
    var images: [CFLSelectedImage] = []
    var files: [CFLSelectedFile] = []
    var canAttachFiles = false
    var beginFileSelection: () -> Bool = { false }
    var addFiles: ([URL]) -> Void = { _ in }
    var fileSelectionFailed: () -> Void = {}
    var removeFile: (String) -> Void = { _ in }
    var canAttachImages = false
    var remainingImageSlots = 0
    var isPreparingAttachments = false
    var beginImageSelection: () -> Bool = { false }
    var imagePickerDidDismiss: () -> Void = {}
    var addPhotos: ([PhotosPickerItem]) -> Void = { _ in }
    var addCameraImage: (UIImage) -> Void = { _ in }
    var removeImage: (UUID) -> Void = { _ in }
    var showsStickerPanel = false
    var toggleStickers: () -> Void = {}

    @StateObject var inlineSpeechRecorder = InlineSpeechRecorderController()
    @State private var inlineSpeechStartTask: Task<Void, Never>?
    @State private var inlineSpeechTranscriptionTask: Task<Void, Never>?
    @State var inlineSpeechPreparedTranscript: String?
    @State private var showInlineSpeechError = false
    @State private var inlineSpeechErrorMessage: String?
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var compactTextEdgeInset: CGFloat { 6 }
    var body: some View {
        ChatComposerHeightLimit(maximumHeight: availableHeight) {
            VStack(spacing: 8) {
                if !images.isEmpty || !files.isEmpty {
                    imagePreviews.padding(.horizontal, 16)
                     .fixedSize(horizontal: false, vertical: true)
                     .layoutPriority(1)
                }
                composerOverlayContent
                    .zIndex(1)
            }
            .padding(.bottom, 6)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): addFiles(urls)
            case .failure: fileSelectionFailed()
            }
            imagePickerDidDismiss()
        }
        .onChange(of: showFilePicker) { _, presented in
            if !presented { imagePickerDidDismiss() }
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos,
                      maxSelectionCount: max(1, remainingImageSlots), selectionBehavior: .ordered, matching: .images)
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            addPhotos(photos)
            selectedPhotos = []
        }
        .onChange(of: showImagePicker) { _, presented in
            if !presented { imagePickerDidDismiss() }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ZStack {
                Color.black.ignoresSafeArea()
                CameraImagePicker(isPresented: $showCamera) { image in
                    if let image { addCameraImage(image) }
                }.ignoresSafeArea()
            }
        }
        .onChange(of: showCamera) { _, presented in
            if !presented { imagePickerDidDismiss() }
        }
        .alert(NSLocalizedString("语音输入错误", comment: ""), isPresented: $showInlineSpeechError) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
        } message: {
            Text(inlineSpeechErrorMessage ?? NSLocalizedString("发生未知错误，请稍后重试。", comment: ""))
        }
        .onDisappear {
            inlineSpeechStartTask?.cancel()
            inlineSpeechStartTask = nil
            inlineSpeechTranscriptionTask?.cancel()
            inlineSpeechTranscriptionTask = nil
            inlineSpeechPreparedTranscript = nil
            inlineSpeechRecorder.cancel()
        }
    }

    private var composerOverlayContent: some View {
        adaptiveComposerContent
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .animation(adaptiveComposerAnimation, value: inlineSpeechRecorder.phase)
    }

    private var imagePreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.prepared.name).lineLimit(1).truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.prepared.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: 150, alignment: .leading)
                        Button { removeFile(file.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: ""), file.prepared.name))
                    }.padding(10).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(images) { image in
                    ZStack(alignment: .topTrailing) {
                        ChatPendingImagePreview(attachment: image.attachment)
                        Button { removeImage(image.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.58), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: NSLocalizedString("移除附件 %@", comment: ""), image.attachment.fileName))
                        .padding(4)
                    }
                }
            }.padding(.horizontal, 2)
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(composerRoundedBackground(cornerRadius: 18))
    }

    @ViewBuilder
    func attachmentMenuButton(size: CGFloat) -> some View {
        let showsSendButton = !appConfig.iOSSoftwareKeyboardReturnSendsMessage &&
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canPerformSend = composerCanSend && !isSendActionPending && !inlineSpeechRecorder.phase.isActive
        if isSending && !showsSendButton {
            ChatCircleActionButton(systemName: "stop.fill",
                accessibilityLabel: NSLocalizedString("停止生成", comment: "Stop generation"),
                isEnabled: true, circleSize: size, symbolSize: min(17, max(14, size * 0.45)),
                iconColor: .white, fill: Color.red.opacity(0.85), action: stopAction)
        } else if showsSendButton {
            ChatCircleActionButton(systemName: "arrow.up",
                accessibilityLabel: NSLocalizedString("发送", comment: "Send message"),
                isEnabled: canPerformSend, circleSize: size, symbolSize: min(17, max(14, size * 0.45)),
                iconColor: canPerformSend ? .white : Color.primary.opacity(0.55),
                fill: canPerformSend ? TelegramColors.sendButtonColor : Color.primary.opacity(0.12)) {
                guard canPerformSend else { return }
                _ = sendAction()
            }
        } else {
            Menu {
                Button {
                    if beginImageSelection() { showImagePicker = true }
                } label: {
                    Label(NSLocalizedString("选择照片", comment: "Choose photos"), systemImage: "photo.on.rectangle")
                }.disabled(!canAttachImages)
                Button {
                    if beginImageSelection() { showCamera = true }
                } label: {
                    Label(NSLocalizedString("拍照", comment: "Take photo"), systemImage: "camera")
                }.disabled(!canAttachImages || !UIImagePickerController.isSourceTypeAvailable(.camera))
                Button {
                    if beginFileSelection() { showFilePicker = true }
                } label: {
                    Label(NSLocalizedString("上传文件", comment: "Upload file"), systemImage: "doc")
                }.disabled(!canAttachFiles)
                if cflState.hasImages {
                    Button {
                        guard composerCanSend else { return }
                        _ = sendAction()
                    } label: {
                        Label(NSLocalizedString("发送", comment: "Send message"), systemImage: "arrow.up")
                    }.disabled(!composerCanSend)
                }
            } label: {
                ChatCircleActionLabel(systemName: "plus", circleSize: size)
            }
            .buttonStyle(ComposerPressButtonStyle())
            .disabled((!canAttachImages && !canAttachFiles && !cflState.hasImages) || isPreparingAttachments || inlineSpeechRecorder.phase.isActive)
            .accessibilityLabel(NSLocalizedString("添加附件", comment: ""))
        }
    }

    func stickerButton(size: CGFloat) -> some View {
        ChatCircleActionButton(systemName: showsStickerPanel ? "keyboard" : "face.smiling",
            accessibilityLabel: showsStickerPanel
            ? NSLocalizedString("切换到键盘", comment: "Show keyboard")
            : NSLocalizedString("表情", comment: "Stickers"),
            isEnabled: !inlineSpeechRecorder.phase.isActive, circleSize: size, action: toggleStickers)
    }

    func startInlineSpeechRecording() {
        inlineSpeechStartTask?.cancel()
        inlineSpeechTranscriptionTask?.cancel()
        inlineSpeechTranscriptionTask = nil
        inlineSpeechPreparedTranscript = nil
        inlineSpeechRecorder.prepareForRecording()
        focus.wrappedValue = false
        inlineSpeechStartTask = Task { @MainActor in
            do {
                try validateInlineSpeechInput()
                await Task.yield()
                try Task.checkCancellation()
                try await inlineSpeechRecorder.start(format: composerRecordingFormat)
            } catch {
                guard !Task.isCancelled else { return }
                inlineSpeechErrorMessage = error.localizedDescription
                showInlineSpeechError = true
                inlineSpeechRecorder.cancel()
            }
        }
    }

    func stopInlineSpeechRecording() {
        inlineSpeechRecorder.stopForPreview()
        transcribeInlineSpeechRecording()
    }

    func confirmInlineSpeechRecording() {
        if let preparedTranscript = inlineSpeechPreparedTranscript, !preparedTranscript.isEmpty {
            appendTranscribedTextToComposer(preparedTranscript)
            inlineSpeechPreparedTranscript = nil
            inlineSpeechRecorder.cancel()
        } else {
            transcribeInlineSpeechRecording()
        }
    }

    func cancelInlineSpeechRecording() {
        inlineSpeechStartTask?.cancel()
        inlineSpeechStartTask = nil
        inlineSpeechTranscriptionTask?.cancel()
        inlineSpeechTranscriptionTask = nil
        inlineSpeechPreparedTranscript = nil
        inlineSpeechRecorder.cancel()
    }

    private func transcribeInlineSpeechRecording() {
        inlineSpeechTranscriptionTask?.cancel()
        inlineSpeechPreparedTranscript = nil
        inlineSpeechRecorder.beginTranscribing()
        inlineSpeechTranscriptionTask = Task { @MainActor in
            do {
                let attachment = try inlineSpeechRecorder.makeAttachment(format: composerRecordingFormat)
                let transcript = try await SystemSpeechRecognizerService.transcribe(
                    audioData: attachment.data,
                    fileExtension: attachment.format
                )
                try Task.checkCancellation()
                let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTranscript.isEmpty else {
                    throw NSError(
                        domain: "InlineSpeechRecorder",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("未识别到有效语音内容。", comment: "")]
                    )
                }
                inlineSpeechPreparedTranscript = trimmedTranscript
                inlineSpeechRecorder.showTranscriptPreview()
            } catch {
                guard !Task.isCancelled else { return }
                inlineSpeechErrorMessage = error.localizedDescription
                showInlineSpeechError = true
                inlineSpeechPreparedTranscript = nil
                inlineSpeechRecorder.cancel()
            }
        }
    }

    private func validateInlineSpeechInput() throws {
        guard composerSupportsSpeech else {
            throw NSError(
                domain: "InlineSpeechRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("语言输入已被关闭。", comment: "")]
            )
        }
    }

    private func appendTranscribedTextToComposer(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let separator = text.isEmpty || (text.last?.isWhitespace ?? false) ? "" : " "
        text += separator + trimmed
    }

    func composerRoundedBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ChatAssistantSurface(shape: shape)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1), radius: 6, x: 0, y: 2)
    }
}
