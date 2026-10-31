// ============================================================================
// ChatViewAdaptiveMessageComposer.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 iOS 自适应输入栏的状态映射、连续形变和请求控制面板。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore

enum AdaptiveComposerPresentation: Equatable {
    case idle
    case editing
    case expandedText
    case speech
}

struct ComposerPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let usesSystemGlassFeedback: Bool

    init(usesSystemGlassFeedback: Bool = false) {
        self.usesSystemGlassFeedback = usesSystemGlassFeedback
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if usesSystemGlassFeedback {
            // 交互式 Liquid Glass 已提供完整按压反馈，避免叠加反向缩放削弱系统高光。
            configuration.label
        } else {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .opacity(configuration.isPressed ? 0.78 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

extension TelegramMessageComposer {
    var adaptiveControlSize: CGFloat { 44 }

    var adaptiveComposerAnimation: Animation? {
        // 输入框高度和相邻控件位置共用此事务；减少动态效果时不能只换成更短的位移动画。
        accessibilityReduceMotion
            ? nil
            : .spring(response: 0.34, dampingFraction: 0.94)
    }

    var adaptivePresentation: AdaptiveComposerPresentation {
        if inlineSpeechRecorder.phase.isActive {
            return .speech
        }
        if isExpandedComposer {
            return .expandedText
        }
        if focus.wrappedValue {
            return .editing
        }
        return .idle
    }

    @ViewBuilder
    var adaptiveComposerContent: some View {
        Group {
            if #available(iOS 26.0, *), appConfig.enableLiquidGlass {
                GlassEffectContainer(spacing: 8) {
                    adaptiveGlassComposerRow
                }
            } else {
                adaptiveComposerRow
            }
        }
        .onAppear {
            adaptiveRefreshSendableText()
        }
    }

    private var adaptiveComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if adaptivePresentation != .expandedText && adaptivePresentation != .speech {
                attachmentMenuButton(size: adaptiveControlSize)
                    .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.82, anchor: .trailing).combined(with: .opacity))
            }
            adaptiveCenterContainer(participatesInGlassContainer: false)

            if adaptiveShowsInlineActionButton {
                adaptiveActionButton(
                    size: adaptiveControlSize,
                    participatesInGlassContainer: false
                )
                    .transition(
                        accessibilityReduceMotion ? .opacity : .scale(scale: 0.82, anchor: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if adaptiveShowsFloatingActionButton {
                adaptiveActionButton(
                    size: adaptiveControlSize,
                    participatesInGlassContainer: false
                )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.82).combined(with: .opacity))
            }
        }
    }

    @available(iOS 26.0, *)
    private var adaptiveGlassComposerRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if adaptivePresentation != .expandedText && adaptivePresentation != .speech {
                attachmentMenuButton(size: adaptiveControlSize, participatesInGlassContainer: true)
                    .glassEffectID("adaptive-attachment", in: adaptiveGlassNamespace)
                    .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.82, anchor: .trailing).combined(with: .opacity))
            }
            adaptiveCenterContainer(participatesInGlassContainer: true)
                .glassEffectID("adaptive-center", in: adaptiveGlassNamespace)

            if adaptiveShowsInlineActionButton {
                adaptiveActionButton(
                    size: adaptiveControlSize,
                    participatesInGlassContainer: true
                )
                    .glassEffectID("adaptive-action", in: adaptiveGlassNamespace)
                    .transition(
                        accessibilityReduceMotion ? .opacity : .scale(scale: 0.82, anchor: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if adaptiveShowsFloatingActionButton {
                adaptiveActionButton(
                    size: adaptiveControlSize,
                    participatesInGlassContainer: true
                )
                    .glassEffectID("adaptive-action", in: adaptiveGlassNamespace)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.82).combined(with: .opacity))
            }
        }
    }

    private var adaptiveShowsInlineActionButton: Bool {
        adaptivePresentation != .expandedText
    }

    // 多行态改由 overlay 承载发送按钮，避免它参与横向测量并挤窄输入框。
    private var adaptiveShowsFloatingActionButton: Bool {
        adaptivePresentation == .expandedText
    }

    @ViewBuilder
    private func adaptiveCenterContainer(
        participatesInGlassContainer: Bool
    ) -> some View {
        let cornerRadius = adaptiveControlSize / 2
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *),
           appConfig.enableLiquidGlass,
           participatesInGlassContainer {
            adaptiveCenterForeground(shape: shape)
                .background(shape.fill(glassOverlayColor))
                .glassEffect(.clear, in: shape)
                .overlay(shape.stroke(glassStrokeColor, lineWidth: 0.5))
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
                .animation(adaptiveComposerAnimation, value: adaptivePresentation)
        } else {
            adaptiveCenterForeground(shape: shape)
                .background(glassRoundedBackground(cornerRadius: cornerRadius))
                .animation(adaptiveComposerAnimation, value: adaptivePresentation)
        }
    }

    private func adaptiveCenterForeground(
        shape: RoundedRectangle
    ) -> some View {
        VStack(spacing: 0) {
            if adaptivePresentation == .speech {
                adaptiveSpeechContent
                    .transition(accessibilityReduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                adaptiveInputStrip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .clipShape(shape)
        .contentShape(shape)
    }

    private var adaptiveInputStrip: some View {
        let targetHeight = adaptivePresentation == .expandedText
            ? adaptiveExpandedInputHeight
            : adaptiveControlSize

        return ZStack(alignment: .topLeading) {
            adaptiveTextEditor

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if adaptiveShowsSpeechButton {
                    adaptiveSpeechButton
                        .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(height: adaptiveControlSize, alignment: .top)
        }
        .frame(minHeight: adaptiveControlSize, idealHeight: targetHeight, maxHeight: targetHeight)
        .animation(adaptiveComposerAnimation, value: composerSupportsSpeech)
    }

    private var adaptiveTextEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .etFont(.system(size: 16))
                .focused(focus)
                .onKeyPress(
                    .return,
                    phases: .down,
                    action: adaptiveHandleHardwareKeyboardReturn
                )
                .scrollContentBackground(.hidden)
                .scrollDisabled(adaptivePresentation != .expandedText)
                .background(ChatSendSourceAnchor(id: .text))
                // 折叠态补足垂直留白，让单行文字在 44pt 胶囊内保持视觉居中。
                .padding(.vertical, adaptivePresentation == .expandedText ? 8 : 4)
                .padding(.leading, adaptiveTextLeadingInset)
                .padding(.trailing, adaptiveTextTrailingInset)

            if text.isEmpty {
                Text(NSLocalizedString("Message", comment: "聊天输入框占位文本"))
                    .etFont(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, adaptivePresentation == .expandedText ? 16 : 12)
                    .padding(.leading, adaptiveTextLeadingInset + 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var adaptiveShowsSpeechButton: Bool {
        composerSupportsSpeech && adaptivePresentation != .expandedText
    }

    // 只为实际显示的内置按钮预留边距，多行态把横向空间完整还给正文。
    private var adaptiveTextLeadingInset: CGFloat {
        compactTextEdgeInset
    }

    private var adaptiveTextTrailingInset: CGFloat {
        adaptiveShowsSpeechButton ? adaptiveControlSize : compactTextEdgeInset
    }

    private var adaptiveExpandedInputHeight: CGFloat {
        let fontScale = CGFloat(
            FontLibrary.effectiveFontScale(
                appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            )
        )
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160 * fontScale, min(rawHeight, 360 * fontScale))
    }

    private var adaptiveSpeechButton: some View {
        Button(action: adaptiveStartSpeechInput) {
            Image(systemName: "mic.fill")
                .etFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(TelegramColors.attachButtonColor)
                .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressButtonStyle())
        .disabled(isPreparingImages)
        .accessibilityLabel(NSLocalizedString("开始语音输入", comment: ""))
    }

    @ViewBuilder
    var adaptiveSpeechContent: some View {
        switch inlineSpeechRecorder.phase {
        case .idle:
            EmptyView()
        case .preparing, .recording:
            HStack(spacing: 10) {
                InlineVoiceWaveformView(
                    samples: inlineSpeechRecorder.waveformSamples,
                    tint: .red,
                    minimumBarOpacity: 0.82,
                    isProcessing: false
                )
                .frame(height: 28)

                Text(adaptiveSpeechDuration)
                    .etFont(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.red)

                Button(action: stopInlineSpeechRecording) {
                    Image(systemName: "stop.fill")
                        .etFont(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.red.opacity(0.8)))
                        .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressButtonStyle())
                .accessibilityLabel(NSLocalizedString("停止录音", comment: ""))
                .disabled(inlineSpeechRecorder.phase == .preparing)
                .opacity(inlineSpeechRecorder.phase == .preparing ? 0.58 : 1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 5)
            .frame(height: adaptiveControlSize)
        case .preview, .transcribing:
            HStack(spacing: 6) {
                Button(action: cancelInlineSpeechRecording) {
                    Image(systemName: "xmark")
                        .etFont(.system(size: 14, weight: .semibold))
                        .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressButtonStyle())
                .accessibilityLabel(NSLocalizedString("取消录音", comment: ""))
                .disabled(inlineSpeechRecorder.phase == .transcribing)

                if let transcript = inlineSpeechPreparedTranscript, !transcript.isEmpty {
                    Text(transcript)
                        .etFont(.footnote)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        inlineSpeechRecorder.togglePreviewPlayback()
                    } label: {
                        Image(systemName: inlineSpeechRecorder.isPlayingPreview ? "pause.fill" : "play.fill")
                            .etFont(.system(size: 12, weight: .bold))
                            .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ComposerPressButtonStyle())
                    .accessibilityLabel(NSLocalizedString("播放录音", comment: ""))
                    .disabled(inlineSpeechRecorder.phase == .transcribing)

                    InlineVoiceWaveformView(
                        samples: inlineSpeechRecorder.waveformSamples,
                        tint: .secondary,
                        minimumBarOpacity: 0.52,
                        isProcessing: inlineSpeechRecorder.phase == .transcribing
                    )
                    .frame(height: 28)
                }

                if inlineSpeechRecorder.phase == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 34)
                        .accessibilityLabel(NSLocalizedString("语音转写中", comment: ""))
                } else {
                    Button(action: confirmInlineSpeechRecording) {
                        Image(systemName: "checkmark")
                            .etFont(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.accentColor))
                            .frame(width: adaptiveControlSize, height: adaptiveControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ComposerPressButtonStyle())
                    .accessibilityLabel(NSLocalizedString("完成", comment: ""))
                }
            }
            .padding(.horizontal, 5)
            .frame(height: adaptiveControlSize)
        }
    }

    func adaptiveActionButton(
        size: CGFloat,
        participatesInGlassContainer: Bool,
        embeddedInCard: Bool = false
    ) -> some View {
        Button(action: adaptiveHandleAction) {
            adaptiveActionLabel(
                size: size,
                participatesInGlassContainer: participatesInGlassContainer,
                embeddedInCard: embeddedInCard
            )
        }
        .buttonStyle(
            ComposerPressButtonStyle(
                usesSystemGlassFeedback: participatesInGlassContainer
                    && appConfig.enableLiquidGlass
            )
        )
        .disabled(adaptiveActionIsDisabled)
        .accessibilityLabel(adaptiveActionAccessibilityLabel)
    }

    @ViewBuilder
    private func adaptiveActionLabel(
        size: CGFloat,
        participatesInGlassContainer: Bool,
        embeddedInCard: Bool
    ) -> some View {
        let label = Image(systemName: adaptiveActionIconName)
            .etFont(.system(size: min(17, max(14, size * 0.45)), weight: .semibold))
            .foregroundStyle(adaptiveActionForegroundColor)
            .frame(width: size, height: size)
        let emphasizesAction = (isSending && !adaptiveHasContent)
            || adaptiveHasContent

        if embeddedInCard {
            label
                .background {
                    if emphasizesAction {
                        adaptiveActionBackground
                    } else {
                        Circle().fill(Color.primary.opacity(0.08))
                    }
                }
        } else if #available(iOS 26.0, *),
           appConfig.enableLiquidGlass,
           participatesInGlassContainer {
            label
                .background(Circle().fill(adaptiveGlassActionFill))
                .glassEffect(.clear.interactive(), in: Circle())
                .overlay(Circle().stroke(glassStrokeColor, lineWidth: 0.5))
                .shadow(color: glassShadowColor, radius: 6, x: 0, y: 2)
        } else {
            label
                .background(adaptiveActionBackground)
        }
    }

    private var adaptiveGlassActionFill: Color {
        if isSending && !adaptiveHasContent {
            return Color.red.opacity(0.85 * 0.82)
        }
        if adaptiveHasContent {
            let fill = composerCanSend
                ? TelegramColors.sendButtonColor
                : Color.primary.opacity(0.12)
            return fill.opacity(0.82)
        }
        return glassOverlayColor
    }

    private var adaptiveHasContent: Bool {
        adaptiveHasSendableText || cflState.hasImages
    }

    private var adaptiveActionIconName: String {
        if isSending && !adaptiveHasContent {
            return "stop.fill"
        }
        return "arrow.up"
    }

    private var adaptiveActionForegroundColor: Color {
        if isSending && !adaptiveHasContent {
            return .white
        }
        if adaptiveHasContent {
            return composerCanSend
                ? .white
                : Color.primary.opacity(0.55)
        }
        return TelegramColors.attachButtonColor
    }

    @ViewBuilder
    private var adaptiveActionBackground: some View {
        if isSending && !adaptiveHasContent {
            actionCircleBackground(fill: Color.red.opacity(0.85))
        } else if adaptiveHasContent {
            actionCircleBackground(
                fill: composerCanSend
                    ? TelegramColors.sendButtonColor
                    : Color.primary.opacity(0.12)
            )
        } else {
            glassCircleBackground
        }
    }

    private var adaptiveActionIsDisabled: Bool {
        if isSendActionPending {
            return true
        }
        if adaptiveHasContent {
            return !composerCanSend
        }
        if inlineSpeechRecorder.phase.isActive, !isSending {
            return true
        }
        return false
    }

    private var adaptiveActionAccessibilityLabel: String {
        if isSending && !adaptiveHasContent {
            return NSLocalizedString("停止生成", comment: "")
        }
        return NSLocalizedString("发送", comment: "")
    }

    private var adaptiveSpeechDuration: String {
        let totalSeconds = max(0, Int(inlineSpeechRecorder.recordingDuration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private func adaptiveBeginEditing() {
        withAnimation(adaptiveComposerAnimation) {
            focus.wrappedValue = true
        }
    }

    func adaptiveStartSpeechInput() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(adaptiveComposerAnimation) {
            isExpandedComposer = false
            focus.wrappedValue = false
        }
        startInlineSpeechRecording()
    }

    private func adaptiveHandleAction() {
        if isSending && !adaptiveHasContent {
            stopAction()
        } else if adaptiveHasContent {
            adaptiveSubmitContent()
        } else {
            adaptiveBeginEditing()
        }
    }

    func adaptiveHandleHardwareKeyboardReturn(_ keyPress: KeyPress) -> KeyPress.Result {
        let action = ChatComposerHardwareKeyboardReturnAction.resolve(
            returnSendsMessage: appConfig.iOSHardwareKeyboardReturnSendsMessage,
            modifiers: keyPress.modifiers
        )
        guard action == .send else {
            return .ignored
        }

        // 消费发送组合键，即使当前内容不可发送，也不能把它意外降级成换行。
        guard !isSendActionPending, adaptiveHasContent else {
            return .handled
        }
        adaptiveSubmitContent()
        return .handled
    }

    private func adaptiveSubmitContent() {
        guard composerCanSend else { return }
        if sendAction() {
            isExpandedComposer = false
        }
    }

    private func adaptiveRefreshSendableText() {
        adaptiveHasSendableText = !text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }
}
