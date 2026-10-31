#if os(iOS)
import SwiftUI
import Combine
import ETOSCore
import MarkdownUI
import UIKit

struct CFLDisplayMessage: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let target: String?
        let session: String?
        let message: String
        let offset: Int
    }
    let id: ID
    let text: String
    let outgoing: Bool
    let markdown: Bool
}

/// Adapts a server-owned display row to ETOS's existing bubble presentation.
/// The UUID belongs only to this view state; CFL identities remain unchanged.
private struct CFLNativeMessageBubble: View {
    let item: CFLDisplayMessage
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @StateObject private var renderState: ChatMessageRenderState
    @State private var showActions = false

    init(item: CFLDisplayMessage) {
        self.item = item
        _renderState = StateObject(wrappedValue: ChatMessageRenderState(
            message: ChatMessage(role: item.outgoing ? .user : .assistant, content: item.text)
        ))
    }

    var body: some View {
        ChatBubble(
            messageState: renderState,
            isReasoningExpanded: .constant(false),
            isToolCallsExpanded: .constant(false),
            enableMarkdown: item.markdown && config.enableMarkdown,
            enableBackground: background.enableBackground,
            enableLiquidGlass: config.enableLiquidGlass,
            enableNoBubbleUI: config.enableNoBubbleUI,
            isCurrentResponse: false,
            mergeWithPrevious: false,
            mergeWithNext: false,
            allowsReadAloud: true,
            onCopy: { UIPasteboard.general.string = item.text },
            onSwitchToPreviousVersion: {},
            onSwitchToNextVersion: {},
            onOpenMore: { _ in showActions = true }
        )
        .confirmationDialog(NSLocalizedString("消息操作", comment: "Message actions"), isPresented: $showActions) {
            if !item.outgoing {
                if TTSManager.shared.currentSpeakingMessageID == renderState.message.id && TTSManager.shared.isSpeaking {
                    Button(NSLocalizedString("停止朗读", comment: "Stop reading")) { TTSManager.shared.stop() }
                } else {
                    Button(NSLocalizedString("朗读消息", comment: "Read message")) {
                        TTSManager.shared.speak(renderState.message.content, messageID: renderState.message.id, flush: true)
                    }
                }
            }
            Button(NSLocalizedString("复制", comment: "Copy")) { UIPasteboard.general.string = item.text }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
        }
        .environment(\.markdownRemoteImagesEnabled, false)
        .onChange(of: item.text) { _, text in
            var next = renderState.message
            next.content = text
            renderState.update(with: next)
            renderState.updateVisualMessage(next)
        }
    }
}

@MainActor
final class CFLConversationModel: ObservableObject {
    @Published var state = CFLChatState() {
        didSet {
            let operations = Set(state.messages.compactMap(\.operationId))
            visiblePending = state.pending.filter { !operations.contains($0.operationId) || $0.sessionId != state.sessionId }
            hasUnknownPending = state.pending.contains { $0.status == .unknown }
            let input = ProjectionInput(target: connectedOrigin, session: state.sessionId, messages: state.messages,
                                        reply: state.connection == .online ? state.streamingReply : nil)
            guard input != latestProjection else { return }
            if input.session != latestProjection?.session {
                visibleMessages = []
                visibleReply = []
            } else if input.reply?.id != latestProjection?.reply?.id {
                visibleReply = []
            }
            latestProjection = input
            pendingProjection = input
            startProjectionIfNeeded()
        }
    }
    private struct ProjectionInput: Equatable, Sendable {
        let target: String?
        let session: String?
        let messages: [CFLMessage]
        let reply: CFLStreamingReply?
    }
    private struct ReplyCache: Sendable {
        let source: String
        let chunks: [CFLReplyPresentation.Chunk]
    }
    private struct ProjectionResult: Sendable {
        let messages: [CFLDisplayMessage]
        let reply: [CFLDisplayMessage]
        let cache: [String: ReplyCache]
    }
    private var replyCache: [String: ReplyCache] = [:]
    private var latestProjection: ProjectionInput?
    private var pendingProjection: ProjectionInput?
    private var projectionTask: Task<Void, Never>?

    private func startProjectionIfNeeded() {
        // Keep at most one parser running and coalesce updates that arrive while it works.
        guard projectionTask == nil, let input = pendingProjection else { return }
        pendingProjection = nil
        let cache = replyCache
        projectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.project(input, cache: cache)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.replyCache = result.cache
            if self.latestProjection == input {
                self.visibleMessages = result.messages
                self.visibleReply = result.reply
            }
            self.projectionTask = nil
            self.startProjectionIfNeeded()
        }
    }

    nonisolated private static func project(_ input: ProjectionInput, cache: [String: ReplyCache]) -> ProjectionResult {
        let messageIDs = Set(input.messages.map(\.id))
        var nextCache: [String: ReplyCache] = [:]
        func rows(id: String, text: String, streaming: Bool) -> [CFLDisplayMessage] {
            let source = CFLReplyPresentation.visibleSource(text, streaming: streaming)
            let chunks = cache[id].flatMap { $0.source == source ? $0.chunks : nil }
                ?? CFLReplyPresentation.chunks(source)
            nextCache[id] = ReplyCache(source: source, chunks: chunks)
            return chunks.map { CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: $0.id), text: $0.text, outgoing: false, markdown: true) }
        }
        let messages = input.messages.flatMap { message in
            if message.role == "agent" { return rows(id: message.id, text: message.text, streaming: false) }
            return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text,
                                      outgoing: message.role == "user", markdown: false)]
        }
        let reply: [CFLDisplayMessage]
        if let streaming = input.reply, !messageIDs.contains(streaming.id) {
            reply = rows(id: streaming.id, text: streaming.text, streaming: true)
        } else { reply = [] }
        return ProjectionResult(messages: messages, reply: reply, cache: nextCache)
    }
    @Published private(set) var visiblePending: [CFLPending] = []
    @Published private(set) var visibleMessages: [CFLDisplayMessage] = []
    @Published private(set) var visibleReply: [CFLDisplayMessage] = []
    @Published private(set) var hasUnknownPending = false
    @Published var busy = false
    @Published var notice: String?
    @Published var uncertain: CFLPending?
    private var client: CFLChatClient?
    private var observation: Task<Void, Never>?
    private var connectedOrigin: String?

    deinit {
        observation?.cancel()
        projectionTask?.cancel()
        if let client { Task { await client.disconnect() } }
    }

    var stateError: String? { state.error.map { message(for: $0) } }

    func connect(origin: String) async {
        guard let origin = CFLHTTPSOrigin.normalized(origin), !origin.isEmpty,
              var components = URLComponents(string: origin) else { return }
        if client != nil && connectedOrigin == origin { return }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        AppConfigStore.shared.cflHTTPSOrigin = origin
        observation?.cancel()
        if let client { await client.disconnect() }
        client = nil
        connectedOrigin = nil
        state = CFLChatState()
        notice = nil
        uncertain = nil
        components.scheme = "wss"
        components.path = "/api/chat/socket"
        guard let socketURL = components.url,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            notice = NSLocalizedString("无法保存聊天状态。", comment: "CFL storage error")
            return
        }
        var request = URLRequest(url: socketURL)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let socketRequest = request
        let store = CFLFilePendingStore(file: support.appendingPathComponent("CFL/pending.json"))
        let next = CFLChatClient(target: origin, store: store, transport: { CFLWebSocketTransport(request: socketRequest) })
        client = next
        connectedOrigin = origin
        observation = Task { [weak self] in
            for await state in await next.states() {
                guard !Task.isCancelled else { break }
                self?.state = state
            }
        }
        await next.connect()
    }

    func send(_ text: String) async -> Bool {
        guard let client, !busy, uncertain == nil else { return false }
        busy = true
        defer { busy = false }
        notice = nil
        do {
            _ = try await client.send(text)
            return true
        } catch let error as CFLPendingStorageUncertain {
            uncertain = error.pending
            notice = NSLocalizedString("无法确认文字是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
        } catch {
            notice = message(for: error)
        }
        return false
    }

    func retryConnection() async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        await client.connect()
    }

    func refresh() async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.reconcile()
            if let uncertain {
                let current = await client.currentState()
                if current.pending.contains(where: { $0.operationId == uncertain.operationId }) {
                    if AppConfigStore.shared.chatComposerDraft == uncertain.text {
                        AppConfigStore.shared.chatComposerDraft = ""
                    }
                    notice = NSLocalizedString("文字已保存在本机，请在下方处理。", comment: "CFL stored input")
                } else {
                    notice = NSLocalizedString("文字未发送，可以继续编辑。", comment: "CFL unsent input")
                }
                self.uncertain = nil
            } else {
                notice = nil
            }
        } catch { notice = message(for: error) }
    }

    func earlier() async {
        guard let client, !busy else { return }
        busy = true
        defer { busy = false }
        do { try await client.loadEarlier() } catch { notice = message(for: error) }
    }

    func stop(_ turn: String) async {
        guard let client else { return }
        do {
            let stopped = try await client.stop(turnId: turn)
            if !stopped {
                notice = NSLocalizedString("当前回复已结束。", comment: "CFL stop no longer active")
            }
        } catch { notice = message(for: error) }
    }

    func dismiss(_ pending: CFLPending) async {
        guard let client else { return }
        do { try await client.dismissPending(sessionId: pending.sessionId, operationId: pending.operationId) }
        catch { notice = message(for: error) }
    }

    private func message(for error: Error) -> String {
        switch error as? CFLFailure {
        case .offline: return NSLocalizedString("连接已断开，请等待重新连接。", comment: "CFL offline")
        case .accessDenied: return NSLocalizedString("连接被拒绝，请检查服务设置。", comment: "CFL denied")
        case .invalidInput: return NSLocalizedString("请检查文字内容和长度。", comment: "CFL invalid input")
        case .storage: return NSLocalizedString("无法保存聊天状态。", comment: "CFL storage error")
        case .protocolError: return NSLocalizedString("无法读取服务返回的数据。", comment: "CFL protocol error")
        case .sessionChanged: return NSLocalizedString("会话已改变，请检查文字状态。", comment: "CFL changed session")
        default: return NSLocalizedString("操作未完成，请稍后再试。", comment: "CFL request error")
        }
    }
}

struct CFLConversationView: View {
    @ObservedObject var model: CFLConversationModel
    let openSettings: () -> Void
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var draft = AppConfigStore.shared.composerDraftState
    @State private var pendingRemoval: CFLPending?
    @State private var sendFlightController = ChatSendFlightController()
    @State private var keepsBottomPinned = true
    @State private var showScrollToBottom = false
    @State private var scrollToBottomRevision = 0
    @State private var historyAnchor: CFLDisplayMessage.ID?
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { config.chatComposerDraft = $0 })
    }
    var body: some View {
        ZStack {
            ChatBackgroundLayer(isChatVisible: true).ignoresSafeArea()
            VStack(spacing: 0) {
                if model.state.connection != .online || model.hasUnknownPending
                    || model.uncertain != nil || model.notice != nil || model.stateError != nil {
                    connectionStatus
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ChatScrollMetricsObserver(
                                keepsBottomPinned: $keepsBottomPinned,
                                isStreaming: model.state.activeTurnId != nil,
                                streamingDisplayMode: ChatStreamingDisplayMode.normalized(config.chatStreamingDisplayMode),
                                reduceMotion: reduceMotion,
                                metricsRefreshGeneration: 0,
                                metricThresholds: ChatScrollMetricThresholds(arrival: 1, bottomPinned: 24, bottomButton: 48, historyLoading: 240),
                                isViewportTransitioning: false,
                                hasProgrammaticScrollCommand: false,
                                anchorAdjustment: nil,
                                onAnchorAdjustmentApplied: { _ in },
                                viewportPageRequest: nil,
                                onViewportPageRequestCompleted: { _ in },
                                onUserPanBegan: {
                                    keepsBottomPinned = false
                                    historyAnchor = nil
                                },
                                isViewportActive: scenePhase == .active
                            ) { distanceToBottom, _, isUserInteracting in
                                keepsBottomPinned = ChatTimelineInteraction.resolvedBottomPinIntent(
                                    currentIntent: keepsBottomPinned,
                                    distanceToBottom: distanceToBottom,
                                    arrivalTolerance: 1,
                                    isUserInteracting: isUserInteracting,
                                    isLayoutSettling: false
                                )
                                showScrollToBottom = distanceToBottom > 48 && !keepsBottomPinned
                            }.frame(width: 0, height: 0)
                            ChatTimelineStack {
                                if model.state.before != nil {
                                    Button(NSLocalizedString("加载更早的消息", comment: "CFL history")) {
                                        historyAnchor = model.visibleMessages.first?.id
                                        keepsBottomPinned = false
                                        Task { await model.earlier() }
                                    }
                                        .disabled(model.busy)
                                        .frame(maxWidth: .infinity)
                                }
                                if model.state.messages.isEmpty && model.state.connection == .online {
                                    Text(NSLocalizedString("还没有消息。", comment: "CFL empty chat"))
                                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                                }
                                ForEach(model.visibleMessages) { message in
                                    CFLNativeMessageBubble(item: message)
                                }
                                ForEach(model.visibleReply) { reply in
                                    CFLNativeMessageBubble(item: reply)
                                }
                                if model.state.connection == .online, let turn = model.state.activeTurnId,
                                   model.state.replyCompletedTurnId != turn {
                                    Text("•••").foregroundStyle(.secondary)
                                        .accessibilityLabel(NSLocalizedString("正在回复", comment: "CFL active"))
                                }
                                ForEach(model.visiblePending) { pending in pendingRow(pending) }
                                ForEach(model.state.otherTargetPending) { pending in otherTargetRow(pending) }
                            }
                        }.padding(.horizontal, 8)
                    }
                    .chatDefaultSizeChangeScrollAnchor(ChatTimelineInteraction.chatSizeChangeScrollAnchor(
                        keepsBottomPinned: keepsBottomPinned,
                        isStreaming: model.state.activeTurnId != nil
                    ))
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .onChange(of: model.state.sessionId) { _, session in
                        historyAnchor = nil
                        if session != nil {
                            keepsBottomPinned = true
                            proxy.scrollTo(ChatScrollTargetID.bottom, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.visibleMessages.first?.id) { oldFirst, newFirst in
                        guard let anchor = historyAnchor, oldFirst == anchor, newFirst != oldFirst else { return }
                        historyAnchor = nil
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                    .onChange(of: scrollToBottomRevision) { _, _ in
                        proxy.scrollTo(ChatScrollTargetID.bottom, anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showScrollToBottom {
                            ChatScrollNavigationButton(
                                systemName: "arrow.down.to.line",
                                accessibilityLabel: NSLocalizedString("滚动到底部", comment: "Scroll to bottom"),
                                isEnabled: true,
                                usesLiquidGlass: config.enableLiquidGlass
                            ) {
                                keepsBottomPinned = true
                                proxy.scrollTo(ChatScrollTargetID.bottom, anchor: .bottom)
                            }.padding(.trailing, 16).padding(.bottom, 8)
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { navigationBar }
        .safeAreaInset(edge: .bottom) { composer }
        .confirmationDialog(NSLocalizedString("移除此记录？", comment: "CFL remove confirmation"), isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { item in
            Button(NSLocalizedString("移除此记录", comment: "CFL dismiss pending"), role: .destructive) {
                Task { await model.dismiss(item) }
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) { pendingRemoval = nil }
        }
        .task {
            await config.waitForPersistentStoreLoaded()
            await model.connect(origin: config.cflHTTPSOrigin)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await config.flushPendingWrites() } }
        }
    }

    private var navigationBar: some View {
        let titleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let subtitleFont = UIFont.systemFont(ofSize: 12)
        let height = titleFont.lineHeight + subtitleFont.lineHeight + 1 + 12
        let tintOpacity = LiquidGlassTintSetting.normalized(config.liquidGlassTintOpacity)
        let tint = colorScheme == .dark ? Color.black.opacity(tintOpacity) : Color.white.opacity(tintOpacity)
        return ChatNavigationBar {
            Button(action: openSettings) {
                ChatNavigationIconSurface(
                    content: Image(systemName: "gearshape").etFont(.system(size: 17, weight: .semibold))
                        .foregroundColor(TelegramColors.navBarText).frame(width: height, height: height),
                    usesLiquidGlass: config.enableLiquidGlass, tint: tint,
                    strokeColor: Color.white.opacity(0.2), lineWidth: 0.5
                )
            }.buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel(NSLocalizedString("设置", comment: "Settings"))
        } center: {
            ChatNavigationPillSurface(
                content: VStack(spacing: 1) {
                    MarqueeText(content: model.state.name.isEmpty ? NSLocalizedString("聊天", comment: "CFL chat title") : model.state.name,
                                uiFont: titleFont).foregroundColor(TelegramColors.navBarText)
                    MarqueeText(content: statusText, uiFont: subtitleFont).foregroundColor(TelegramColors.navBarSubtitle)
                }.padding(.horizontal, 22).padding(.vertical, 6).frame(height: height),
                usesLiquidGlass: config.enableLiquidGlass, tint: tint, selected: false
            )
        } trailing: {
            Color.clear.frame(width: height, height: height).accessibilityHidden(true)
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !config.cflHTTPSOrigin.isEmpty && model.state.connection != .online && model.state.connection != .connecting {
                    Button(NSLocalizedString("重新连接", comment: "CFL retry connection")) { Task { await model.retryConnection() } }
                        .font(.caption).disabled(model.busy)
                }
                if model.state.connection == .online && (model.hasUnknownPending || model.uncertain != nil) {
                    Button(NSLocalizedString("检查状态", comment: "CFL reconcile")) { Task { await model.refresh() } }.font(.caption)
                }
            }
            if let notice = model.notice ?? model.stateError { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal).padding(.vertical, 8)
    }

    private var statusText: String {
        if config.cflHTTPSOrigin.isEmpty { return NSLocalizedString("请先设置连接地址。", comment: "CFL setup") }
        switch model.state.connection {
        case .online: return model.state.activeTurnId == nil ? NSLocalizedString("已连接", comment: "CFL online") : NSLocalizedString("正在回复", comment: "CFL active")
        case .connecting: return NSLocalizedString("正在连接…", comment: "CFL connecting")
        case .offline: return NSLocalizedString("连接已断开。", comment: "CFL offline status")
        case .accessDenied: return NSLocalizedString("连接被拒绝，请检查服务设置。", comment: "CFL denied")
        case .protocolError: return NSLocalizedString("无法读取服务返回的数据。", comment: "CFL protocol error")
        }
    }

    private var composer: some View {
        TelegramMessageComposer(
            sendFlightController: sendFlightController,
            text: text,
            sendAction: {
                let captured = draft.text
                Task {
                    if await model.send(captured) {
                        if draft.text == captured { config.chatComposerDraft = "" }
                        keepsBottomPinned = true
                        scrollToBottomRevision += 1
                    }
                }
                return true
            },
            stopAction: {
                guard let turn = model.state.activeTurnId else { return }
                Task { await model.stop(turn) }
            },
            focus: $composerFocused,
            cflState: CFLComposerState(
                canSend: !model.busy && model.uncertain == nil && draft.hasSendableText && model.state.connection == .online,
                isSubmitting: model.busy,
                isResponding: model.state.activeTurnId != nil
            )
        )
    }

    private func pendingRow(_ item: CFLPending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            Text(pendingText(item)).font(.caption).foregroundStyle(.secondary)
            if item.sessionId != model.state.sessionId {
                Text(NSLocalizedString("属于其他会话", comment: "CFL other session")).font(.caption).foregroundStyle(.secondary)
            }
            if item.status == .failed || (item.status == .unknown && !item.dispatched) {
                Button(NSLocalizedString("复制到输入框", comment: "CFL recover input")) {
                    if draft.text.isEmpty { config.chatComposerDraft = item.text }
                    else { noticeDraftOccupied() }
                }.font(.caption)
            }
            if item.status != .unknown || !item.dispatched {
                Button(NSLocalizedString("移除此记录", comment: "CFL dismiss pending")) { pendingRemoval = item }.font(.caption)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func noticeDraftOccupied() {
        model.notice = NSLocalizedString("输入框已有文字，请先处理。", comment: "CFL draft occupied")
    }

    private func otherTargetRow(_ item: CFLPending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            Text(pendingText(item)).font(.caption).foregroundStyle(.secondary)
            Text(item.target).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(String(format: NSLocalizedString("会话：%@", comment: "CFL pending session"), item.sessionId))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(NSLocalizedString("切换到此服务", comment: "CFL return to pending origin")) {
                guard let origin = CFLHTTPSOrigin.normalized(item.target), !origin.isEmpty else { return }
                Task { await model.connect(origin: origin) }
            }.font(.caption).disabled(model.busy || model.uncertain != nil)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pendingText(_ item: CFLPending) -> String {
        switch item.status {
        case .unknown:
            return item.dispatched ? NSLocalizedString("发送结果尚未确认，请勿重复发送。", comment: "CFL unknown") : NSLocalizedString("文字尚未发送。", comment: "CFL undispatched")
        case .submitted: return NSLocalizedString("已接收，等待显示消息。", comment: "CFL submitted")
        case .failed: return NSLocalizedString("发送失败，可以复制文字后重新编辑。", comment: "CFL failed")
        }
    }

}
#endif
