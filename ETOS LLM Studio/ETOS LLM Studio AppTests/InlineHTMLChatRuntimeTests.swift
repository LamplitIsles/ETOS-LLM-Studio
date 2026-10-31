import Combine
import ETOSCore
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import ETOS_LLM_Studio_App

@Suite("真实聊天 HTML 内联显示", .serialized)
@MainActor
struct InlineHTMLChatRuntimeTests {
    enum DisplayMode: CaseIterable {
        case plain, fenced, fullDocument, advancedMarkdown, noBubble, scaledFont
    }


    @Test("工具网页在真实 SwiftUI 卡片内有可见尺寸")
    func rendersToolWidgetInline() async throws {
        let payload = try #require(ToolWidgetPayloadParser.parse(from: #"{"widget_code":"<div id='etos-inline-probe'>工具网页</div>","title":"运行回归","inline_aspect_ratio":"16:9"}"#))
        let host = try HostedInlineHTML(ToolWidgetRendererCard(payload: payload).padding())
        defer { host.dispose() }
        let webView = try await host.waitForWebView(containing: "etos-inline-probe")
        #expect(webView.bounds.width > 200)
        #expect(webView.bounds.height > 100)
    }
}

@MainActor
private final class HostedInlineHTML<Content: View> {
    let window: UIWindow
    let host: UIHostingController<Content>

    init(_ content: Content) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
    }

    func waitForWebView(containing elementID: String, minimumHeight: CGFloat = 100) async throws -> WKWebView {
        var found: WKWebView?
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(50))
            host.view.layoutIfNeeded()
            for webView in webViews(in: host.view) {
                if let exists = try? await webView.evaluateJavaScript("document.getElementById('\(elementID)') !== null"), exists as? Bool == true {
                    found = webView
                    if !webView.isLoading, webView.bounds.width > 200, webView.bounds.height >= minimumHeight { return webView }
                }
            }
        }
        let webView = try #require(found, "真实视图树中没有加载目标 HTML 的 WebView：\(elementID)")
        #expect(!webView.isLoading, "目标网页应完成加载：\(elementID)")
        #expect(webView.bounds.width > 200, "目标网页应有可见宽度：\(elementID)")
        #expect(webView.bounds.height >= minimumHeight, "目标网页应展开到内容高度：\(elementID)")
        return webView
    }

    func dispose() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }
}
