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
    var canAttachImages = false
    var remainingImageSlots = 0
    var isPreparingImages = false
    var beginImageSelection: () -> Bool = { false }
    var imagePickerDidDismiss: () -> Void = {}
    var addPhotos: ([PhotosPickerItem]) -> Void = { _ in }
    var addCameraImage: (UIImage) -> Void = { _ in }
    var removeImage: (UUID) -> Void = { _ in }

    @StateObject var inlineSpeechRecorder = InlineSpeechRecorderController()
    @Namespace var adaptiveGlassNamespace
    @State private var inlineSpeechStartTask: Task<Void, Never>?
    @State private var inlineSpeechTranscriptionTask: Task<Void, Never>?
    @State var inlineSpeechPreparedTranscript: String?
    @State private var showInlineSpeechError = false
    @State private var inlineSpeechErrorMessage: String?
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var selectedPhotos: [PhotosPickerItem] = []

    var compactTextEdgeInset: CGFloat { 6 }
    private var isLiquidGlassEnabled: Bool {
        if #available(iOS 26.0, *) {
            return appConfig.enableLiquidGlass
        }
        return false
    }
    var body: some View {
        ChatComposerHeightLimit(maximumHeight: availableHeight) {
            VStack(spacing: 8) {
                if !images.isEmpty {
                    imagePreviews.padding(.horizontal, 16)
                     .fixedSize(horizontal: false, vertical: true)
                     .layoutPriority(1)
                }
                composerOverlayContent
                    .zIndex(1)
            }
            .padding(.bottom, 6)
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
        .background(glassRoundedBackground(cornerRadius: 18))
    }

    @ViewBuilder
    func attachmentMenuButton(size: CGFloat, participatesInGlassContainer: Bool = false) -> some View {
        if isSending {
            Button(action: stopAction) {
                Image(systemName: "stop.fill")
                    .etFont(.system(size: min(17, max(14, size * 0.45)), weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.red.opacity(0.85)).shadow(color: glassShadowColor, radius: 6, x: 0, y: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(ComposerPressButtonStyle())
            .accessibilityLabel(NSLocalizedString("停止生成", comment: "Stop generation"))
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
                if cflState.hasImages {
                    Button {
                        guard composerCanSend else { return }
                        _ = sendAction()
                    } label: {
                        Label(NSLocalizedString("发送", comment: "Send message"), systemImage: "arrow.up")
                    }.disabled(!composerCanSend)
                }
            } label: {
                composerActionIcon("paperclip", size: size)
            }
            .buttonStyle(ComposerPressButtonStyle(usesSystemGlassFeedback: participatesInGlassContainer && isLiquidGlassEnabled))
            .disabled((!canAttachImages && !cflState.hasImages) || isPreparingImages || inlineSpeechRecorder.phase.isActive)
            .accessibilityLabel(NSLocalizedString("添加附件", comment: ""))
        }
    }

    private func composerActionIcon(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
            .foregroundColor(TelegramColors.attachButtonColor)
            .frame(width: size, height: size)
            .background { glassCircleBackground }
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

    @ViewBuilder
    func actionCircleBackground(fill: Color) -> some View {
        if isLiquidGlassEnabled {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(.clear.interactive(), in: Circle())
                    .overlay(
                        Circle()
                            .fill(fill.opacity(0.82))
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            } else {
                Circle()
                    .fill(fill)
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        } else {
            Circle()
                .fill(fill)
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        }
    }

    var glassCircleBackground: some View {
        ChatComposerCircleBackground(usesLiquidGlass: isLiquidGlassEnabled, tint: glassOverlayColor,
                                     stroke: glassStrokeColor, shadow: glassShadowColor)
    }

    func glassRoundedBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    shape
                        .fill(Color.clear)
                        .glassEffect(.clear, in: shape)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            shape
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        shape
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
    }

    var glassOverlayColor: Color {
        let opacity = LiquidGlassTintSetting.normalized(appConfig.liquidGlassTintOpacity)
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }

    var glassStrokeColor: Color {
        Color.white.opacity(colorScheme == .dark ? 0.18 : 0.28)
    }

    var glassShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.3 : 0.1)
    }
}
