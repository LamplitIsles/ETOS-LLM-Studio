#if os(iOS)
import Foundation
import CoreFoundation
import SwiftUI
import UIKit
import WebKit
import ETOSCore

enum CFLA2UIBridgePolicy {
    static func displayHeight(_ value: Double, viewport: Double) -> (height: CGFloat, scroll: Bool)? {
        guard value.isFinite, value > 0, value <= 10_000, viewport.isFinite, viewport > 0 else { return nil }
        let limit = min(viewport, 1_200)
        return (CGFloat(min(max(28, ceil(value)), limit)), value > limit)
    }

    static func mediaPath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "cfl-media", parts.host == "load", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil, parts.percentEncodedPath.hasPrefix("/") else { return nil }
        return String(parts.percentEncodedPath.dropFirst()).removingPercentEncoding
    }

    static func mediaPayloadChanged(_ previous: CFLJSONValue?, _ next: CFLJSONValue) -> Bool {
        previous != next
    }
}

/// A displayed resource keeps one file version across WebKit's range tasks.
struct CFLA2UIMediaVersions {
    private var values: [String: String] = [:]
    mutating func admit(_ version: String, for path: String) -> Bool {
        if let existing = values[path] { return existing == version }
        values[path] = version
        return true
    }
    mutating func reset() { values.removeAll() }
}

struct CFLA2UIMediaLifecycle {
    private var invalidations = 0
    private(set) var stopped = false
    var acceptsStarts: Bool { !stopped && invalidations == 0 }
    mutating func beginInvalidation() { invalidations += 1 }
    mutating func endInvalidation() { invalidations -= 1 }
    mutating func stop() { stopped = true }
}

/// Content and session changes get a separate WebView and media handler.
struct CFLA2UIPresentationID: Hashable {
    let message: CFLDisplayMessage.ID
    let sessionRevision: Int
    let clientID: UUID
    let payload: CFLJSONValue

    init(item: CFLDisplayMessage, payload: CFLJSONValue) {
        message = item.id; sessionRevision = item.sessionRevision; clientID = item.clientID; self.payload = payload
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(message); hasher.combine(sessionRevision); hasher.combine(clientID)
    }
}

/// The page is the same restricted renderer shipped with the selected CFL web app.
struct CFLA2UIMessage: View {
    let item: CFLDisplayMessage
    let payload: CFLJSONValue
    let model: CFLConversationModel
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @ObservedObject private var appearance = ChatAppearanceProfileManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @EnvironmentObject private var viewport: CFLA2UIViewport
    @State private var height: CGFloat = 44
    @State private var failed = false
    @State private var ready = false

    private var viewportHeight: CGFloat { viewport.height }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if failed {
                    Text(NSLocalizedString("界面暂时无法显示", comment: "Chat interface unavailable"))
                        .font(.footnote).foregroundStyle(.secondary).padding(12)
                } else if viewportHeight > 0 {
                    CFLA2UIWebView(item: item, payload: payload, model: model, dark: colorScheme == .dark,
                                   locale: locale.language.languageCode?.identifier == "zh" ? "zh" : "en",
                                   fontScale: fontScale, viewportHeight: viewportHeight, height: $height, failed: $failed, ready: $ready)
                        .frame(height: height)
                } else {
                    Color.clear.frame(height: height)
                }
            }
            .background {
                if !config.enableNoBubbleUI {
                    ChatBubbleBackground(
                        shape: RoundedRectangle(cornerRadius: CGFloat(config.chatBubbleCornerRadius), style: .continuous),
                        fill: AnyShapeStyle(ChatAssistantBubbleAppearance.fill(profile: appearance.activeProfile, enableBackground: background.enableBackground)),
                        enableLiquidGlass: config.enableLiquidGlass
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(config.chatBubbleCornerRadius), style: .continuous))
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, config.enableNoBubbleUI ? 9 : 3)
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
    let viewportHeight: CGFloat
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
        coordinator.media.update(model: model, item: item, payload: payload)
        guard let target = item.id.target, let normalized = CFLHTTPSOrigin.normalized(target),
              !normalized.isEmpty, let page = URL(string: normalized + "/a2ui.html") else {
            coordinator.fail(); return
        }
        coordinator.update(page: page, payload: payload, dark: dark, locale: locale,
                           fontScale: fontScale, viewportHeight: viewportHeight)
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
        private var viewportHeight: Double = 0
        private var reportedHeight: Double?
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
            self.viewportHeight = Double(viewportHeight)
            if let reportedHeight { applyHeight(reportedHeight) }
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
            webView.callAsyncJavaScript("window.a2uiHost.show(payload, options); return true;", arguments: ["payload": value, "options": options], in: nil, in: .page) { [weak self] result in
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
                reportedHeight = number.doubleValue
                applyHeight(number.doubleValue)
            }
        }

        private func applyHeight(_ value: Double) {
            guard let size = CFLA2UIBridgePolicy.displayHeight(value, viewport: viewportHeight) else { fail(); return }
            webView?.scrollView.isScrollEnabled = size.scroll
            if abs(height - size.height) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.height = size.height
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == page ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        func fail() { DispatchQueue.main.async { [weak self] in if let self, !self.stopped { self.failed = true } } }
        func stop() { stopped = true; ready = false; media.stop() }
    }
}

/// Only approved CFL media paths use this bridge; WebKit never receives credentials.
@MainActor private final class CFLA2UIMediaHandler: NSObject, WKURLSchemeHandler {
    private final class Entry {
        let token = UUID()
        let schemeTask: any WKURLSchemeTask
        var operation: Task<Void, Never>?
        init(_ schemeTask: any WKURLSchemeTask) { self.schemeTask = schemeTask }
    }
    private weak var model: CFLConversationModel?
    private var item: CFLDisplayMessage?
    private var payload: CFLJSONValue?
    private var tasks: [ObjectIdentifier: Entry] = [:]
    private var versions = CFLA2UIMediaVersions()
    private var lifecycle = CFLA2UIMediaLifecycle()

    func update(model: CFLConversationModel, item: CFLDisplayMessage, payload: CFLJSONValue) {
        guard !lifecycle.stopped else { return }
        let changed = self.item?.id != item.id || self.item?.clientID != item.clientID || self.item?.sessionRevision != item.sessionRevision
            || CFLA2UIBridgePolicy.mediaPayloadChanged(self.payload, payload)
        self.model = model; self.item = item; self.payload = payload
        if changed {
            lifecycle.beginInvalidation()
            defer { lifecycle.endInvalidation() }
            cancelAll()
        }
    }
    func stop() {
        lifecycle.stop()
        cancelAll()
        model = nil; item = nil; payload = nil
    }
    private func cancelAll() {
        for (key, entry) in Array(tasks) {
            guard tasks[key]?.token == entry.token else { continue }
            tasks.removeValue(forKey: key)
            entry.operation?.cancel()
            entry.schemeTask.didFailWithError(CancellationError())
        }
        versions.reset()
    }

    private func activeTask(_ key: ObjectIdentifier, token: UUID) throws -> any WKURLSchemeTask {
        guard !Task.isCancelled, let entry = tasks[key], entry.token == token else { throw CancellationError() }
        return entry.schemeTask
    }

    private func takeTask(_ key: ObjectIdentifier, token: UUID) throws -> any WKURLSchemeTask {
        let task = try activeTask(key, token: token)
        tasks.removeValue(forKey: key)
        return task
    }

    private func receive(_ result: CFLRendererMediaResponse, url: URL, key: ObjectIdentifier, token: UUID) throws {
        let task = try activeTask(key, token: token)
        var headers = result.headers
        headers["Access-Control-Allow-Origin"] = "*"
        guard let response = HTTPURLResponse(url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else { throw CFLFailure.protocolError }
        task.didReceive(response)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task as AnyObject)
        guard lifecycle.acceptsStarts else { task.didFailWithError(CancellationError()); return }
        guard task.request.httpMethod == nil || task.request.httpMethod == "GET",
              let item, let model, let url = task.request.url, let path = CFLA2UIBridgePolicy.mediaPath(url) else {
            task.didFailWithError(CFLFailure.invalidInput); return
        }
        let range = task.request.value(forHTTPHeaderField: "Range")
        let entry = Entry(task)
        let token = entry.token
        tasks[key] = entry
        entry.operation = Task { @MainActor [weak self] in
            defer { if self?.tasks[key]?.token == token { self?.tasks.removeValue(forKey: key) } }
            do {
                if path.hasPrefix("/api/chat/workspace-media?") {
                    try await model.rendererWorkspaceMediaStream(path, range: range, target: item.id.target, session: item.id.session,
                        revision: item.sessionRevision, clientID: item.clientID, admitVersion: { [weak self] version in
                            guard let self else { throw CancellationError() }
                            _ = try self.activeTask(key, token: token)
                            guard self.versions.admit(version, for: path) else { throw CFLFailure.protocolError }
                        }, onResponse: { [weak self] result in
                            guard let self else { throw CancellationError() }
                            try self.receive(result, url: url, key: key, token: token)
                        }, onChunk: { [weak self] data in
                            guard let self else { throw CancellationError() }
                            try self.activeTask(key, token: token).didReceive(data)
                        })
                } else {
                    let result = try await model.rendererMedia(path, range: range, target: item.id.target, session: item.id.session,
                                                               revision: item.sessionRevision, clientID: item.clientID)
                    guard let self else { return }
                    try self.receive(result, url: url, key: key, token: token)
                    try self.activeTask(key, token: token).didReceive(result.data)
                }
                guard let self else { return }
                try self.takeTask(key, token: token).didFinish()
            } catch {
                if let task = try? self?.takeTask(key, token: token) { task.didFailWithError(error) }
            }
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(task as AnyObject))?.operation?.cancel()
    }
}
#endif
