import Combine
import Darwin
import ETOSCore
import MarkdownUI
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import ETOS_LLM_Studio_App

@Suite("Markdown 代码预览", .serialized)
@MainActor
struct CodePreviewRuntimeTests {
    enum Scenario: CaseIterable {
        case basic, advanced, surroundingMath, precedingDollar, fullDocument, updated
    }

    @Test("Markdown HTML 代码框可打开并运行网页", arguments: Scenario.allCases)
    func previewsHTMLCodeBlock(scenario: Scenario) async throws {
        // 仅测试包启用系统的无障碍自动化桥，与 AccessibilitySnapshot/KIF 的测试宿主做法一致。
        // SwiftUI 的环境值不会启动这个桥；退出用例时恢复原状态，正式 App 不使用这些符号。
        let libraryPath = (ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? "")
            + "/usr/lib/libAccessibility.dylib"
        let library = try #require(dlopen(libraryPath, RTLD_LAZY), "无法加载测试用无障碍自动化桥")
        defer { dlclose(library) }
        let readAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSAutomationEnabled")),
            to: (@convention(c) () -> Int32).self
        )
        let setAutomation = unsafeBitCast(
            try #require(dlsym(library, "_AXSSetAutomationEnabled")),
            to: (@convention(c) (Int32) -> Void).self
        )
        let previousAutomation = readAutomation()
        setAutomation(1)
        defer { setAutomation(previousAutomation) }
        let advanced = scenario != .basic
        let fragment = """
        <div id='code-preview-probe' style='margin-top:100px;color:#0759bf'>等待脚本</div>
        <button id='code-action' onclick="this.textContent = '交互成功'">点我</button>
        <script>
        const $ = id => document.getElementById(id);
        $('code-preview-probe').textContent = '脚本运行成功';
        const literal = String.raw`\\frac{1}{2}`;
        </script>
        """
        let source = scenario == .fullDocument
            ? "<!doctype html><html><head><meta charset='utf-8'></head><body>\(fragment)</body></html>"
            : fragment
        let content: String
        switch scenario {
        case .surroundingMath:
            content = "公式 $x^2$\n```html\n\(source)\n```\n后文 $y^2$"
        case .precedingDollar:
            content = "价格 $5\n```html\n\(source)\n```\n后文"
        default:
            content = "前文\n```html\n\(source)\n```\n后文"
        }
        let preview = CodePreviewContent(content: scenario == .updated ? "正在生成网页" : content)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: NavigationStack {
            CodePreviewRenderer(content: preview, advanced: advanced)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        if scenario == .updated {
            host.view.layoutIfNeeded()
            await Task.yield()
            preview.content = content
        }
        let prepared = await ETMarkdownPrecomputeWorker.shared.prepare(source: content)
        #expect(prepared.sourceText == content)
        #expect(prepared.containsMathContent == (scenario == .surroundingMath))
        #expect(prepared.mathRenderText.contains(source))
        if scenario == .surroundingMath {
            #expect(prepared.nativeMathMarkdownContent?.renderMarkdown().contains(source) == true)
        }
        var previewButton: NSObject?
        for _ in 0..<200 {
            host.view.layoutIfNeeded()
            previewButton = accessibilityObjects(host.view).first {
                $0.accessibilityLabel == NSLocalizedString("预览代码", comment: "")
            }
            if previewButton != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // 代码框出现后等一次布局绘制；公式图片独立加载，此帧不作为公式已完成的证据。
        try await Task.sleep(for: .seconds(1))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(png, named: "普通代码框-\(scenario).png")
        let button = try #require(previewButton, "HTML 代码框应有预览按钮")
        // 使用真实 SwiftUI 按钮的系统动作，不能直接创建预览 WebView 替代入口验证。
        #expect(button.accessibilityActivate(), "通过真实预览按钮打开页面")
        var loadedWebView: WKWebView?
        for _ in 0..<400 {
            for webView in webViews(window) {
                if (try? await webView.evaluateJavaScript("document.getElementById('code-preview-probe') !== null")) as? Bool == true {
                    loadedWebView = webView
                }
            }
            if let loadedWebView, !loadedWebView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let webView = try #require(loadedWebView, "预览页应加载 HTML")
        #expect(webView.bounds.width > 200)
        #expect(webView.bounds.height > 200)
        #expect(try await webView.evaluateJavaScript("document.getElementById('code-preview-probe').textContent") as? String == "脚本运行成功")
        #expect(try await webView.evaluateJavaScript("literal") as? String == #"\frac{1}{2}"#)
        #expect(try await webView.evaluateJavaScript("document.getElementById('code-action').click(); document.getElementById('code-action').textContent") as? String == "交互成功")
        for _ in 0..<200 {
            if host.presentedViewController?.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // DOM 更新完成与 WebKit 提交显示帧并非同一时刻。
        try await Task.sleep(for: .milliseconds(200))
        let previewPNG = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(previewPNG, named: "代码预览页-\(scenario).png")
        if scenario == .surroundingMath {
            await withCheckedContinuation { continuation in
                host.dismiss(animated: false) { continuation.resume() }
            }
            // 返回后补采一帧，便于复核代码外的异步公式图片与网页预览能否共存。
            try await Task.sleep(for: .seconds(2))
            host.view.layoutIfNeeded()
            let returnedPNG = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(returnedPNG, named: "混排公式-返回聊天.png")
        }
    }

    private func accessibilityObjects(_ object: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 20 else { return [] }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else if object.accessibilityElementCount() > 0 && object.accessibilityElementCount() < 1000 {
            children = (0..<object.accessibilityElementCount()).compactMap {
                object.accessibilityElement(at: $0) as? NSObject
            }
        } else if let view = object as? UIView {
            children = view.subviews
        }
        return [object] + children.flatMap { accessibilityObjects($0, depth: depth + 1) }
    }

    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) }
    }
}

@MainActor
private final class CodePreviewContent: ObservableObject {
    @Published var content: String

    init(content: String) { self.content = content }
}

private struct CodePreviewRenderer: View {
    @ObservedObject var content: CodePreviewContent
    let advanced: Bool

    var body: some View {
        ScrollView {
            ETAdvancedMarkdownRenderer(
                content: content.content,
                preparedContent: nil,
                enableMarkdown: true,
                isOutgoing: false,
                enableAdvancedRenderer: advanced,
                enableMathRendering: advanced,
                customTextColor: nil
            )
        }
    }
}
