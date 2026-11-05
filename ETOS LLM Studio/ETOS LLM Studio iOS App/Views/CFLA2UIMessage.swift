#if os(iOS)
import Foundation
import CoreFoundation
import SwiftUI
import UIKit
import WebKit
import ETOSCore

enum CFLA2UIBridgePolicy {
    static func mediaPath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "cfl-media", parts.host == "load", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil, parts.percentEncodedPath.hasPrefix("/") else { return nil }
        return String(parts.percentEncodedPath.dropFirst()).removingPercentEncoding
    }
}

/// The page is the same restricted renderer shipped with the selected CFL web app.
struct CFLA2UIMessage: View {
    let item: CFLDisplayMessage
    let payload: CFLJSONValue
    let model: CFLConversationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @State private var height: CGFloat = 44
    @State private var failed = false
    @State private var ready = false

    var body: some View {
        HStack {
            if failed {
                Text(NSLocalizedString("界面暂时无法显示", comment: "Chat interface unavailable"))
                    .font(.footnote).foregroundStyle(.secondary).padding(12)
            } else {
                CFLA2UIWebView(item: item, payload: payload, model: model, dark: colorScheme == .dark,
                               locale: locale.language.languageCode?.identifier == "zh" ? "zh" : "en",
                               fontScale: fontScale, height: $height, failed: $failed, ready: $ready)
                    .frame(height: height)
            }
            Spacer(minLength: 40)
        }
        .task(id: item.id) {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled && !ready { failed = true }
        }
    }

    private var fontScale: Double {
        switch dynamicTypeSize {
        case .xSmall: 0.82
        case .small: 0.9
        case .medium: 0.95
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.23
        case .xxxLarge: 1.35
        default: 1.6
        }
    }
}

private struct CFLA2UIWebView: UIViewRepresentable {
    let item: CFLDisplayMessage
    let payload: CFLJSONValue
    let model: CFLConversationModel
    let dark: Bool
    let locale: String
    let fontScale: Double
    @Binding var height: CGFloat
    @Binding var failed: Bool
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, failed: $failed, ready: $ready) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.media, forURLScheme: "cfl-media")
        configuration.userContentController.add(context.coordinator, name: "a2uiReady")
        configuration.userContentController.add(context.coordinator, name: "a2uiHeight")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.media.update(model: model, item: item)
        guard let target = item.id.target, let normalized = CFLHTTPSOrigin.normalized(target),
              !normalized.isEmpty, let page = URL(string: normalized + "/a2ui.html") else {
            coordinator.fail(); return
        }
        coordinator.update(page: page, payload: payload, dark: dark, locale: locale,
                           fontScale: fontScale, viewportHeight: webView.window?.bounds.height ?? UIScreen.main.bounds.height)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "a2uiReady")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "a2uiHeight")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let media = CFLA2UIMediaHandler()
        weak var webView: WKWebView?
        @Binding var height: CGFloat
        @Binding var failed: Bool
        @Binding var readyState: Bool
        private var page: URL?
        private var payload: CFLJSONValue?
        private var options: [String: Any] = [:]
        private var ready = false
        private var stopped = false

        init(height: Binding<CGFloat>, failed: Binding<Bool>, ready: Binding<Bool>) {
            _height = height; _failed = failed; _readyState = ready
        }

        func update(page: URL, payload: CFLJSONValue, dark: Bool, locale: String, fontScale: Double, viewportHeight: CGFloat) {
            let pageChanged = self.page != page
            let changed = self.payload != payload || (options["dark"] as? Bool) != dark
                || (options["locale"] as? String) != locale || (options["fontScale"] as? Double) != fontScale
                || (options["viewportHeight"] as? Double) != Double(viewportHeight)
            self.payload = payload
            options = ["dark": dark, "locale": locale, "fontScale": fontScale, "viewportHeight": Double(viewportHeight)]
            if pageChanged {
                self.page = page; ready = false
                webView?.load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData))
            } else if changed { render() }
        }

        private func render() {
            guard ready, !stopped, let webView, let payload,
                  let data = try? JSONEncoder().encode(payload),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            webView.callAsyncJavaScript("window.a2uiHost.show(payload, options)", arguments: ["payload": value, "options": options], in: nil, in: .page) { [weak self] result in
                if case .failure = result { self?.fail() }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !stopped, let webView, message.webView === webView, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url == page, webView.url == page else { return }
            if message.name == "a2uiReady", (message.body as? String) == "ready" {
                ready = true; readyState = true; render()
            } else if message.name == "a2uiHeight", let number = message.body as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID() {
                let value = number.doubleValue
                guard value.isFinite, value > 0, value <= 10_000 else { fail(); return }
                let next = max(28, ceil(value))
                if abs(height - next) > 0.5 { height = next }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == page ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        func fail() { DispatchQueue.main.async { [weak self] in if let self, !self.stopped { self.failed = true } } }
        func stop() { stopped = true; ready = false; media.cancelAll() }
    }
}

/// Only approved CFL media paths use this bridge; WebKit never receives credentials.
private final class CFLA2UIMediaHandler: NSObject, WKURLSchemeHandler {
    private weak var model: CFLConversationModel?
    private var item: CFLDisplayMessage?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func update(model: CFLConversationModel, item: CFLDisplayMessage) {
        if self.item?.id != item.id || self.item?.clientID != item.clientID || self.item?.sessionRevision != item.sessionRevision { cancelAll() }
        self.model = model; self.item = item
    }
    func cancelAll() { for task in tasks.values { task.cancel() }; tasks.removeAll() }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        guard let item, let model, let url = task.request.url, let path = CFLA2UIBridgePolicy.mediaPath(url) else {
            task.didFailWithError(CFLFailure.invalidInput); return
        }
        let range = task.request.value(forHTTPHeaderField: "Range")
        tasks[key] = Task { @MainActor [weak self] in
            defer { self?.tasks.removeValue(forKey: key) }
            do {
                let result = try await model.rendererMedia(path, range: range, target: item.id.target, session: item.id.session,
                                                           revision: item.sessionRevision, clientID: item.clientID)
                guard !Task.isCancelled else { return }
                var headers = result.headers
                headers["Access-Control-Allow-Origin"] = "*"
                guard let response = HTTPURLResponse(url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else { throw CFLFailure.protocolError }
                task.didReceive(response); task.didReceive(result.data); task.didFinish()
            } catch { if !Task.isCancelled { task.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task as AnyObject))?.cancel()
    }
}
#endif
