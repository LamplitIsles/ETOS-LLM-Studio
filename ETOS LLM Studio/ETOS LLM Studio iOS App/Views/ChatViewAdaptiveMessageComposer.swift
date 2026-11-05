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
    case speech
}

struct ComposerPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
        if focus.wrappedValue {
            return .editing
        }
        return .idle
    }

    var adaptiveComposerContent: some View {
        HStack(alignment: .bottom, spacing: 10) {
            adaptiveCenterContainer
            stickerButton(size: adaptiveControlSize)
            attachmentMenuButton(size: adaptiveControlSize)
        }
    }

    private var adaptiveCenterContainer: some View {
        let cornerRadius = adaptiveControlSize / 2
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return adaptiveCenterForeground(shape: shape)
            .background(composerRoundedBackground(cornerRadius: cornerRadius))
            .animation(adaptiveComposerAnimation, value: adaptivePresentation)
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
        ZStack(alignment: .bottomLeading) {
            adaptiveTextEditor

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if adaptiveShowsSpeechButton {
                    adaptiveSpeechButton
                        .transition(accessibilityReduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(height: adaptiveControlSize, alignment: .bottom)
        }
        .frame(minHeight: adaptiveControlSize)
        .animation(adaptiveComposerAnimation, value: composerSupportsSpeech)
    }

    private var adaptiveTextEditor: some View {
        let pointSize = CGFloat(FontLibrary.scaledPointSize(
            16, scale: appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts
        ))
        let customName = appConfig.fontUseCustomFonts ? FontLibrary.resolvedPostScriptName(for: .body) : nil
        let font = customName.flatMap { UIFont(name: $0, size: pointSize) } ?? .systemFont(ofSize: pointSize)
        return CFLComposerTextView(text: $text, focus: focus, font: font,
                                   maximumHeight: adaptiveMaximumInputHeight,
                                   hardwareReturnSends: appConfig.iOSHardwareKeyboardReturnSendsMessage,
                                   softwareReturnSends: appConfig.iOSSoftwareKeyboardReturnSendsMessage,
                                   onSubmit: adaptiveSubmitContent)
            .padding(.leading, adaptiveTextLeadingInset + 5)
            .padding(.trailing, adaptiveTextTrailingInset)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = true })
    }

    private var adaptiveShowsSpeechButton: Bool {
        composerSupportsSpeech
    }

    // 文本始终避开语音按钮，避免多行时宽度切换造成高度反复跳变。
    private var adaptiveTextLeadingInset: CGFloat {
        compactTextEdgeInset
    }

    private var adaptiveTextTrailingInset: CGFloat {
        adaptiveShowsSpeechButton ? adaptiveControlSize : compactTextEdgeInset
    }

    private var adaptiveMaximumInputHeight: CGFloat {
        let fontScale = CGFloat(
            FontLibrary.effectiveFontScale(
                appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts
            )
        )
        let rawHeight = UIScreen.main.bounds.height * 0.3
        return max(160 * fontScale, min(rawHeight, 360 * fontScale)) * 2 / 3
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
        .disabled(isPreparingAttachments)
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

    private var adaptiveSpeechDuration: String {
        let totalSeconds = max(0, Int(inlineSpeechRecorder.recordingDuration.rounded(.down)))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    func adaptiveStartSpeechInput() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(adaptiveComposerAnimation) {
            focus.wrappedValue = false
        }
        startInlineSpeechRecording()
    }

    private func adaptiveSubmitContent() {
        guard composerCanSend else { return }
        _ = sendAction()
    }
}
