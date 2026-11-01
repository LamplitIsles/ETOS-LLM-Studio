// ============================================================================
// ETAdvancedMarkdownRenderer.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 聊天气泡内 Markdown、数学公式与 Mermaid 内容的渲染入口。
// ============================================================================

import Foundation
import SwiftUI
import MarkdownUI
import ETOSCore

private struct MarkdownRemoteImagesKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var markdownRemoteImagesEnabled: Bool {
        get { self[MarkdownRemoteImagesKey.self] }
        set { self[MarkdownRemoteImagesKey.self] = newValue }
    }

    var cflMarkdownImages: CFLMarkdownImageContext? {
        get { self[CFLMarkdownImagesKey.self] }
        set { self[CFLMarkdownImagesKey.self] = newValue }
    }
}

private struct CFLMarkdownImagesKey: EnvironmentKey {
    static let defaultValue: CFLMarkdownImageContext? = nil
}

struct ETAdvancedMarkdownRenderer: View {
    let content: String
    let preparedContent: ETPreparedMarkdownRenderPayload?
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let customTextColor: Color?
    var customTextStyleColors: ChatAppearanceTextStyleColors? = nil
    var isStreaming: Bool = false
    var streamingState: ETStreamingMarkdownRenderState? = nil
    var streamingChannel: ETStreamingMarkdownChannel = .content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownRemoteImagesEnabled) private var remoteImagesEnabled
    @Environment(\.cflMarkdownImages) private var cflMarkdownImages
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var preparedRuleRequest: ChatAppearanceTextRuleRenderRequest?
    @State private var ruleAttributedText: AttributedString?
    @State private var asynchronouslyPreparedContent: ETPreparedMarkdownRenderPayload?

    private var effectivePreparedContent: ETPreparedMarkdownRenderPayload? {
        if let preparedContent, preparedContent.sourceText == content {
            return preparedContent
        }
        if let asynchronouslyPreparedContent, asynchronouslyPreparedContent.sourceText == content {
            return asynchronouslyPreparedContent
        }
        // Keep the previous CFL subtree until its replacement is ready. The
        // bubble changes identity when its effective image targets change.
        if cflMarkdownImages != nil { return asynchronouslyPreparedContent ?? preparedContent }
        return nil
    }

    private var shouldUseStreamingRenderer: Bool {
        if isStreaming { return true }
        guard enableMarkdown,
              effectivePreparedContent == nil,
              let streamingState,
              streamingState.snapshot(for: streamingChannel) != nil else {
            return false
        }
        return streamingState.isAwaitingStaticHandoff(channel: streamingChannel)
    }

    var body: some View {
        let textColor: Color = customTextColor ?? (isOutgoing ? .white : .primary)
        let fontScale = FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts)
        let lineSpacingEm = FontLibrary.normalizedLineSpacingEm(
            appConfig.fontLineSpacingEmIOS,
            fallback: FontLibrary.defaultIOSLineSpacingEm
        )
        let lineSpacing = CGFloat(
            FontLibrary.lineSpacingPoints(
                basePointSize: 17,
                lineSpacingEm: lineSpacingEm,
                fontScale: appConfig.fontCustomScale,
                isCustomFontEnabled: appConfig.fontUseCustomFonts,
                fallbackLineSpacingEm: FontLibrary.defaultIOSLineSpacingEm
            )
        )
        let streamingDisplayMode = ChatStreamingDisplayMode.normalized(
            appConfig.chatStreamingDisplayMode
        )
        Group {
            if preparedRuleRequest == ruleRenderRequest,
               let ruleAttributedText {
                Text(ruleAttributedText)
                    .etFont(.body, sampleText: content)
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(textColor)
            } else if shouldUseStreamingRenderer, let streamingState {
                ETIOSStreamingMarkdownLiveView(
                    state: streamingState,
                    channel: streamingChannel,
                    fallbackText: content,
                    enableMarkdown: enableMarkdown,
                    isOutgoing: isOutgoing,
                    enableAdvancedRenderer: enableAdvancedRenderer,
                    enableMathRendering: enableMathRendering,
                    textColor: textColor,
                    customTextStyleColors: customTextStyleColors,
                    fontScale: fontScale,
                    lineSpacingEm: lineSpacingEm,
                    lineSpacing: lineSpacing,
                    streamingDisplayMode: streamingDisplayMode
                )
            } else if enableMarkdown {
                if let prepared = effectivePreparedContent {
                    if shouldUseWebRenderer(prepared) {
                        ETMathWebMarkdownView(
                            content: prepared.mathRenderText,
                            imageSources: prepared.webImageSources.sources,
                            enableMarkdown: enableMarkdown,
                            isOutgoing: isOutgoing,
                            customTextHex: customTextColor.flatMap { ChatAppearanceColorCodec.hexRGBA(from: $0) },
                            customEmphasisTextHex: enabledHex(customTextStyleColors?.emphasis),
                            customStrongTextHex: enabledHex(customTextStyleColors?.strong),
                            customCodeTextHex: enabledHex(customTextStyleColors?.code),
                            prefersDarkPalette: colorScheme == .dark,
                            fontScale: fontScale,
                            lineSpacingEm: lineSpacingEm
                        )
                    } else {
                        let markdownContent = resolvedMarkdownContent(for: prepared)
                        markdownTextView(
                            markdownContent: markdownContent,
                            renderedSources: renderedSources(for: prepared),
                            sampleText: prepared.sourceText,
                            textColor: textColor,
                            fontScale: fontScale,
                            lineSpacing: lineSpacing
                        )
                    }
                } else {
                    plainTextView(content, textColor: textColor, lineSpacing: lineSpacing)
                }
            } else {
                plainTextView(content, textColor: textColor, lineSpacing: lineSpacing)
            }
        }
        .task(id: ruleRenderRequest) {
            guard let request = ruleRenderRequest else {
                preparedRuleRequest = nil
                ruleAttributedText = nil
                return
            }
            let prepared = await ChatAppearanceTextRuleRenderer.shared.prepare(request: request)
            guard !Task.isCancelled else { return }
            preparedRuleRequest = request
            ruleAttributedText = prepared
        }
        .task(id: fallbackMarkdownRequest) {
            guard fallbackMarkdownRequest != nil else {
                asynchronouslyPreparedContent = nil
                return
            }
            let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: content)
            guard !Task.isCancelled else { return }
            asynchronouslyPreparedContent = prepared
        }
    }

    private var fallbackMarkdownRequest: String? {
        guard enableMarkdown,
              !isStreaming,
              preparedContent?.sourceText != content else { return nil }
        return content
    }

    private var ruleRenderRequest: ChatAppearanceTextRuleRenderRequest? {
        guard !isStreaming else { return nil }
        let fontRules = FontLibrary.resolvedTextFontRules()
        let resolvedStyleColors = customTextStyleColors
            ?? ChatAppearanceTextStyleColors(defaultHex: "000000FF")
        guard !resolvedStyleColors.customRules.isEmpty || !fontRules.isEmpty else { return nil }
        return ChatAppearanceTextRuleRenderRequest(
            source: content,
            usesMarkdown: enableMarkdown,
            styleColors: resolvedStyleColors,
            fontRules: fontRules,
            fontPointSize: 17,
            fontScale: FontLibrary.customFontScale,
            fontFallbackScope: FontLibrary.fallbackScope
        )
    }

    private func shouldUseWebRenderer(_ prepared: ETPreparedMarkdownRenderPayload) -> Bool {
        guard enableAdvancedRenderer else { return false }
        let hasMermaid = enableMarkdown && prepared.containsMermaidContent
        return hasMermaid
    }

    private func resolvedMarkdownContent(for prepared: ETPreparedMarkdownRenderPayload) -> MarkdownContent {
        guard enableAdvancedRenderer,
              enableMathRendering,
              prepared.containsMathContent,
              !prepared.containsMermaidContent,
              let nativeMathMarkdownContent = prepared.nativeMathMarkdownContent else {
            return prepared.markdownContent
        }
        return nativeMathMarkdownContent
    }

    private func renderedSources(for prepared: ETPreparedMarkdownRenderPayload) -> CFLMarkdownImageSources {
        if enableAdvancedRenderer, enableMathRendering, prepared.containsMathContent,
           !prepared.containsMermaidContent, let sources = prepared.mathImageSources {
            return sources.sources
        }
        return prepared.imageSources.sources
    }

    @ViewBuilder
    private func markdownTextView(
        markdownContent: MarkdownContent,
        renderedSources: CFLMarkdownImageSources,
        sampleText: String,
        textColor: Color,
        fontScale: Double,
        lineSpacing: CGFloat
    ) -> some View {
        let mathTextColor = ETIOSMathColorComponents(textColor)
        let emphasisTextColor = resolvedStyleColor(customTextStyleColors?.emphasis, fallback: textColor)
        let strongTextColor = resolvedStyleColor(customTextStyleColors?.strong, fallback: textColor)
        let codeTextColor = resolvedStyleColor(customTextStyleColors?.code, fallback: textColor)
        let cflImages = cflMarkdownImages?.rendered(sources: renderedSources)
        Markdown(markdownContent)
            .markdownImageProvider(
                ETIOSMarkdownImageProvider(textColor: mathTextColor, fontScale: fontScale, remoteImagesEnabled: remoteImagesEnabled, cflImages: cflImages)
            )
            .markdownInlineImageProvider(
                ETIOSMarkdownInlineImageProvider(textColor: mathTextColor, fontScale: fontScale, remoteImagesEnabled: remoteImagesEnabled, cflImages: cflImages)
            )
            .etChatMarkdownBaseStyle(
                textColor: textColor,
                emphasisTextColor: emphasisTextColor,
                strongTextColor: strongTextColor,
                codeTextColor: codeTextColor,
                usesCustomCodeTextColor: customTextStyleColors?.usesAutomaticCodeSyntaxHighlighting == false,
                isOutgoing: isOutgoing,
                prefersDarkPalette: colorScheme == .dark,
                sampleText: sampleText,
                fontScale: fontScale,
                lineSpacing: lineSpacing,
                codeHighlightLimit: isStreaming ? 4_096 : 12_000
            )
    }

    @ViewBuilder
    private func plainTextView(_ text: String, textColor: Color, lineSpacing: CGFloat) -> some View {
        Text(text)
            .etFont(.body, sampleText: text)
            .lineSpacing(lineSpacing)
            .foregroundStyle(textColor)
    }

    private func resolvedStyleColor(_ slot: ChatAppearanceColorSlot?, fallback: Color) -> Color {
        guard let slot, slot.isEnabled else { return fallback }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: fallback)
    }

    private func enabledHex(_ slot: ChatAppearanceColorSlot?) -> String? {
        guard let slot, slot.isEnabled else { return nil }
        return slot.hex
    }

}
