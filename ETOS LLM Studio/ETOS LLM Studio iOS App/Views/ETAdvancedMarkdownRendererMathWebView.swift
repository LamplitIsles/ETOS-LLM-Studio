// ============================================================================
// ETAdvancedMarkdownRendererMathWebView.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责数学与 Mermaid 内容的 WKWebView 承载、尺寸回传和 payload 更新。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// Routes Markdown images in Mermaid's web view through the same scoped loader
/// as the native renderer. WebKit never receives CFL credentials.
private final class CFLMarkdownWebImageHandler: NSObject, WKURLSchemeHandler {
    private struct Identity: Equatable {
        let sourceRevision: Int
        let clientID: UUID
        let target: String?
        let session: String?
        let revision: Int
    }
    private var identity: Identity?
    private var context: CFLMarkdownImageContext?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func update(_ context: CFLMarkdownImageContext?) {
        let next = context.map { Identity(sourceRevision: $0.sourceRevision, clientID: $0.clientID,
                                          target: $0.target, session: $0.session, revision: $0.revision) }
        if next != identity { cancelAll() }
        identity = next
        self.context = context
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let context, let requestURL = urlSchemeTask.request.url,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              components.host == "load", components.percentEncodedPath.hasPrefix("/"),
              let source = String(components.percentEncodedPath.dropFirst()).removingPercentEncoding,
              let url = URL(string: source, relativeTo: nil) else {
            urlSchemeTask.didFailWithError(CFLFailure.invalidInput)
            return
        }
        tasks[key] = Task { @MainActor [weak self] in
            defer { self?.tasks.removeValue(forKey: key) }
            do {
                let data = try await context.data(for: url)
                guard !Task.isCancelled else { return }
                guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(image) as String?,
                      let mime = UTType(type)?.preferredMIMEType else {
                    context.discard(for: url)
                    throw CFLFailure.protocolError
                }
                let response = URLResponse(url: requestURL, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
}

struct ETMathWebMarkdownView: View {
    let content: String
    let imageSources: CFLMarkdownImageSources
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let customTextHex: String?
    let customEmphasisTextHex: String?
    let customStrongTextHex: String?
    let customCodeTextHex: String?
    let prefersDarkPalette: Bool
    let fontScale: Double
    let lineSpacingEm: Double

    @Environment(\.copyCompletionNoticeAction) private var showCopyCompletionNotice
    @Environment(\.cflMarkdownImages) private var cflMarkdownImages
    @State private var renderedHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            ETMathWebViewRepresentable(
                content: content,
                imageSources: imageSources,
                enableMarkdown: enableMarkdown,
                isOutgoing: isOutgoing,
                customTextHex: customTextHex,
                customEmphasisTextHex: customEmphasisTextHex,
                customStrongTextHex: customStrongTextHex,
                customCodeTextHex: customCodeTextHex,
                prefersDarkPalette: prefersDarkPalette,
                fontScale: fontScale,
                lineSpacingEm: lineSpacingEm,
                cflImageContext: cflMarkdownImages,
                availableWidth: max(1, geometry.size.width),
                onCopyCompleted: showCopyCompletionNotice,
                renderedHeight: $renderedHeight
            )
        }
        .frame(height: max(28, renderedHeight))
    }
}

struct ETMathWebPayload: Equatable {
    let content: String
    let availableWidth: CGFloat
    let bodyFontFamily: String
    let emphasisFontFamily: String
    let strongFontFamily: String
    let codeFontFamily: String

    var javaScriptInvocation: String {
        let widthString = String(format: "%.0f", availableWidth)
        let contentJSON = Self.jsonStringLiteral(content)
        let bodyFontFamilyJSON = Self.jsonStringLiteral(bodyFontFamily)
        let emphasisFontFamilyJSON = Self.jsonStringLiteral(emphasisFontFamily)
        let strongFontFamilyJSON = Self.jsonStringLiteral(strongFontFamily)
        let codeFontFamilyJSON = Self.jsonStringLiteral(codeFontFamily)
        return """
window.__etApplyPayload && window.__etApplyPayload({
  content: \(contentJSON),
  availableWidth: \(widthString),
  bodyFontFamily: \(bodyFontFamilyJSON),
  emphasisFontFamily: \(emphasisFontFamilyJSON),
  strongFontFamily: \(strongFontFamilyJSON),
  codeFontFamily: \(codeFontFamilyJSON)
});
window.__etNotifyHeight && window.__etNotifyHeight();
"""
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}

private struct ETMathWebViewRepresentable: UIViewRepresentable {
    let content: String
    let imageSources: CFLMarkdownImageSources
    let enableMarkdown: Bool
    let isOutgoing: Bool
    let customTextHex: String?
    let customEmphasisTextHex: String?
    let customStrongTextHex: String?
    let customCodeTextHex: String?
    let prefersDarkPalette: Bool
    let fontScale: Double
    let lineSpacingEm: Double
    let cflImageContext: CFLMarkdownImageContext?
    let availableWidth: CGFloat
    let onCopyCompleted: () -> Void
    @Binding var renderedHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            renderedHeight: $renderedHeight,
            onCopyCompleted: onCopyCompleted
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if cflImageContext != nil {
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(context.coordinator.imageHandler, forURLScheme: "cfl-image")
        }
        let controller = WKUserContentController()

        controller.add(context.coordinator, name: Coordinator.heightMessageName)
        controller.add(context.coordinator, name: Coordinator.copyMessageName)
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCopyCompleted = onCopyCompleted
        context.coordinator.imageHandler.update(cflImageContext?.rendered(sources: imageSources))
        let stableWidth = max(1, floor(availableWidth))
        let payload = ETMathWebPayload(
            content: content,
            availableWidth: stableWidth,
            bodyFontFamily: Self.resolvedCSSFontFamily(
                role: .body,
                sampleText: content,
                fallback: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            ),
            emphasisFontFamily: Self.resolvedCSSFontFamily(
                role: .emphasis,
                sampleText: content,
                fallback: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            ),
            strongFontFamily: Self.resolvedCSSFontFamily(
                role: .strong,
                sampleText: content,
                fallback: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
            ),
            codeFontFamily: Self.resolvedCSSFontFamily(
                role: .code,
                sampleText: content,
                fallback: "ui-monospace, SFMono-Regular, Menlo, Monaco, monospace"
            )
        )
        let shellConfiguration = ETMathWebShellConfiguration(
            enableMarkdown: enableMarkdown,
            isOutgoing: isOutgoing,
            customTextHex: customTextHex,
            customEmphasisTextHex: customEmphasisTextHex,
            customStrongTextHex: customStrongTextHex,
            customCodeTextHex: customCodeTextHex,
            prefersDarkPalette: prefersDarkPalette,
            fontScale: fontScale,
            lineSpacingEm: lineSpacingEm,
            cflImagePolicy: cflImageContext != nil
        )
        context.coordinator.render(
            payload,
            shellConfiguration: shellConfiguration,
            on: webView
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        coordinator.imageHandler.cancelAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.copyMessageName)
    }

    private static func resolvedCSSFontFamily(
        role: FontSemanticRole,
        sampleText: String,
        fallback: String
    ) -> String {
        if FontLibrary.fallbackScope == .character {
            let familyChain = FontLibrary.fallbackPostScriptNames(for: role)
                .filter { !$0.isEmpty }
                .map(ETMathWebShellConfiguration.cssFamilyLiteral)
            if !familyChain.isEmpty {
                return "\(familyChain.joined(separator: ", ")), \(fallback)"
            }
            return fallback
        }
        if let postScriptName = FontLibrary.resolvePostScriptName(for: role, sampleText: sampleText),
           !postScriptName.isEmpty {
            return "\(ETMathWebShellConfiguration.cssFamilyLiteral(postScriptName)), \(fallback)"
        }
        return fallback
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let heightMessageName = "etMathHeight"
        static let copyMessageName = "etMathCopy"
        let imageHandler = CFLMarkdownWebImageHandler()

        @Binding var renderedHeight: CGFloat
        var onCopyCompleted: () -> Void
        var lastPayload: ETMathWebPayload?
        var lastShellConfiguration: ETMathWebShellConfiguration?
        var pendingPayload: ETMathWebPayload?
        var isShellLoaded = false
        var isShellLoading = false

        init(
            renderedHeight: Binding<CGFloat>,
            onCopyCompleted: @escaping () -> Void
        ) {
            self._renderedHeight = renderedHeight
            self.onCopyCompleted = onCopyCompleted
        }

        func render(
            _ payload: ETMathWebPayload,
            shellConfiguration: ETMathWebShellConfiguration,
            on webView: WKWebView
        ) {
            let shellConfigurationChanged = lastShellConfiguration != shellConfiguration
            let shouldStartShellLoad: Bool
            if shellConfigurationChanged {
                shouldStartShellLoad = true
            } else if isShellLoaded {
                shouldStartShellLoad = false
            } else {
                shouldStartShellLoad = !isShellLoading
            }

            guard lastPayload != payload || shellConfigurationChanged || shouldStartShellLoad else {
                return
            }

            lastPayload = payload
            pendingPayload = payload

            if shouldStartShellLoad {
                lastShellConfiguration = shellConfiguration
                isShellLoaded = false
                isShellLoading = true
                webView.loadHTMLString(shellConfiguration.htmlDocument, baseURL: nil)
                return
            }

            applyPendingPayloadIfPossible(on: webView)
        }

        private func applyPendingPayloadIfPossible(on webView: WKWebView) {
            guard isShellLoaded, let payload = pendingPayload else { return }
            pendingPayload = nil
            webView.evaluateJavaScript(payload.javaScriptInvocation) { _, error in
                if error != nil {
                    self.pendingPayload = payload
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == Self.copyMessageName {
                Task { @MainActor [weak self] in
                    AppHapticFeedback.operationSucceeded()
                    self?.onCopyCompleted()
                }
                return
            }

            guard message.name == Self.heightMessageName else { return }
            guard let value = message.body as? Double else { return }

            let newHeight = max(28, ceil(value))
            if abs(renderedHeight - newHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.renderedHeight = newHeight
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellLoading = false
            isShellLoaded = true
            applyPendingPayloadIfPossible(on: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoading = false
            isShellLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isShellLoading = false
            isShellLoaded = false
        }
    }
}
