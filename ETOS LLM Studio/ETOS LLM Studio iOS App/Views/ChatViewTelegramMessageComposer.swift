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
    let sendFlightController: ChatSendFlightController
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
    let focus: FocusState<Bool>.Binding
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

    @State var isExpandedComposer = false
    @State var adaptiveHasSendableText = false
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

    private let inputBasePointSize: CGFloat = 16
    private var measuredInputPointSize: CGFloat {
        CGFloat(FontLibrary.scaledPointSize(Double(inputBasePointSize), scale: appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts))
    }
    private var inputUIFont: UIFont {
        .systemFont(ofSize: measuredInputPointSize)
    }
    private var composerReservedHeight: CGFloat {
        adaptiveControlSize + 16
    }
    private var estimatedCompactInputWidth: CGFloat {
        max(0, UIScreen.main.bounds.width - 16 * 2 - adaptiveControlSize * 2 - 10 * 2)
    }
    private let textContainerInset: CGFloat = 8
    private let textHorizontalPadding: CGFloat = 10
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
                    VStack(alignment: .leading, spacing: 3) {
                        imagePreviews
                        Text(NSLocalizedString("未发送的图片仅暂存在内存中，退出应用后会丢失。", comment: "Image draft lifetime"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16)
                     .fixedSize(horizontal: false, vertical: true)
                     .layoutPriority(1)
                }
                if usesCardComposer {
                    cardComposerLayout
                        .zIndex(1)
                } else {
                    composerOverlayContent
                        .frame(height: composerReservedHeight, alignment: .bottom)
                        .zIndex(1)
                }
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
        .onChange(of: text) { _, newValue in
            handleAutoExpand(for: newValue)
        }
        .onChange(of: appConfig.chatComposerStyle) { _, _ in
            withAnimation(adaptiveComposerAnimation) {
                isExpandedComposer = false
            }
            handleAutoExpand(for: text)
        }
        .onChange(of: focus.wrappedValue) { _, isFocused in
            if isFocused {
                handleAutoExpand(for: text)
            } else if isExpandedComposer {
                withAnimation(adaptiveComposerAnimation) {
                    isExpandedComposer = false
                }
            }
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
        // 保留向上展开的输入框及其发送动画锚点。
        adaptiveComposerContent
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .bottom)
            // 测真实展开内容，不能把外层 60pt 占位当成输入框顶部。
            .background(ChatSendFlightLayoutAnchor(controller: sendFlightController, region: .composerContent))
            .animation(adaptiveComposerAnimation, value: isExpandedComposer)
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

    func attachmentMenuButton(size: CGFloat, participatesInGlassContainer: Bool = false, embeddedInCard: Bool = false) -> some View {
        Menu {
            Button {
                if beginImageSelection() { showImagePicker = true }
            } label: {
                Label(NSLocalizedString("选择照片", comment: "Choose photos"), systemImage: "photo.on.rectangle")
            }
            Button {
                if beginImageSelection() { showCamera = true }
            } label: {
                Label(NSLocalizedString("拍照", comment: "Take photo"), systemImage: "camera")
            }.disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        } label: {
            Image(systemName: embeddedInCard ? "plus" : "paperclip")
                .etFont(.system(size: max(14, size * 0.45), weight: .semibold))
                .foregroundColor(TelegramColors.attachButtonColor)
                .frame(width: size, height: size)
                .background {
                    if embeddedInCard { Circle().fill(Color.primary.opacity(0.08)) }
                    else { glassCircleBackground }
                }
        }
        .buttonStyle(ComposerPressButtonStyle(usesSystemGlassFeedback: participatesInGlassContainer && isLiquidGlassEnabled))
        .disabled(!canAttachImages || isPreparingImages || inlineSpeechRecorder.phase.isActive)
        .accessibilityLabel(NSLocalizedString("添加附件", comment: ""))
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

    private func handleAutoExpand(for newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 复用自动展开时的文本规整结果，避免视图渲染时重复扫描草稿。
        adaptiveHasSendableText = !trimmed.isEmpty
        guard !usesCardComposer else {
            isExpandedComposer = false
            return
        }
        if trimmed.isEmpty {
            if isExpandedComposer {
                withAnimation(adaptiveComposerAnimation) {
                    isExpandedComposer = false
                }
            }
            return
        }

        let baseAvailableWidth = estimatedCompactInputWidth
            - textHorizontalPadding * 2
            - textContainerInset * 2
        let availableWidth = baseAvailableWidth - Self.compactInlineControlsReservedWidth(
            controlSize: adaptiveControlSize,
            textEdgeInset: compactTextEdgeInset,
            showsRequestControls: false,
            showsSpeechButton: composerSupportsSpeech
        )
        let hasExplicitNewline = newValue.contains("\n")
        var shouldExpand = hasExplicitNewline

        if availableWidth > 0 {
            let lineCount = measuredTextLineCount(for: newValue, width: availableWidth)
            shouldExpand = hasExplicitNewline || lineCount > 1
        }

        if shouldExpand {
            let wasFocused = focus.wrappedValue
            guard !isExpandedComposer else { return }
            withAnimation(adaptiveComposerAnimation) {
                isExpandedComposer = true
            }
            if wasFocused {
                focus.wrappedValue = true
            }
        } else if isExpandedComposer {
            withAnimation(adaptiveComposerAnimation) {
                isExpandedComposer = false
            }
        }
    }

    private func measuredTextLineCount(for value: String, width: CGFloat) -> Int {
        let textStorage = NSTextStorage(string: value, attributes: [.font: inputUIFont])
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true

        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        // 数实际行片段，避免单行字体 leading 被高度换算误判成两行。
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, _, _, _, _ in
            lineCount += 1
        }
        return max(lineCount, 1)
    }

    /// 返回紧凑态内置按钮相对普通文本边距额外占用的宽度。
    static func compactInlineControlsReservedWidth(
        controlSize: CGFloat,
        textEdgeInset: CGFloat,
        showsRequestControls: Bool,
        showsSpeechButton: Bool
    ) -> CGFloat {
        let controlCount = (showsRequestControls ? 1 : 0) + (showsSpeechButton ? 1 : 0)
        return CGFloat(controlCount) * max(0, controlSize - textEdgeInset)
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
        Group {
            if isLiquidGlassEnabled {
                if #available(iOS 26.0, *) {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear.interactive(), in: Circle())
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                } else {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(glassOverlayColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(glassStrokeColor, lineWidth: 0.5)
                        )
                        .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                }
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .fill(glassOverlayColor)
                    )
                    .overlay(
                        Circle()
                            .stroke(glassStrokeColor, lineWidth: 0.5)
                    )
                    .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
            }
        }
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
