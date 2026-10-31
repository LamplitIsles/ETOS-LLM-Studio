#if os(iOS)
import SwiftUI
import Combine
import ETOSCore
import MarkdownUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct CFLSelectedImage: Identifiable, Sendable {
    let id: UUID
    let attachment: ImageAttachment
    let prepared: CFLPreparedImage
}

struct CFLImageContext: Equatable {
    let clientID: UUID
    let target: String
    let session: String
    let revision: Int
}

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
    let images: [CFLImageRef]
    let sessionRevision: Int
    let clientID: UUID
    var isReminder = false
}

/// A reminder is one server message, independently of its transport role.
struct CFLReminderBubble: View {
    let text: String
    @State private var expanded = false

    static func displayedText(_ text: String, expanded: Bool) -> String {
        let content = expanded ? text : text.components(separatedBy: .newlines).joined(separator: " ")
        return "⏰ " + content
    }

    var body: some View {
        HStack {
            Button { expanded.toggle() } label: {
                Text(Self.displayedText(text, expanded: expanded))
                    .etFont(.system(size: 15))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : 1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(NSLocalizedString(expanded ? "收起提醒" : "展开提醒", comment: "Reminder expand or collapse")))
            .contextMenu {
                Button(NSLocalizedString("复制提醒", comment: "Copy reminder")) { UIPasteboard.general.string = text }
            }
            Spacer(minLength: 40)
        }
    }
}

/// Adapts a server-owned display row to ETOS's existing bubble presentation.
/// The UUID belongs only to this view state; CFL identities remain unchanged.
private struct CFLNativeMessageBubble: View {
    let item: CFLDisplayMessage
    let model: CFLConversationModel
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @StateObject private var renderState: ChatMessageRenderState
    @State private var showActions = false

    init(item: CFLDisplayMessage, model: CFLConversationModel) {
        self.item = item
        self.model = model
        _renderState = StateObject(wrappedValue: ChatMessageRenderState(
            message: ChatMessage(role: item.outgoing ? .user : .assistant, content: item.text)
        ))
    }

    var body: some View {
        VStack(alignment: item.outgoing ? .trailing : .leading, spacing: 4) {
            if !item.text.isEmpty {
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
            if !item.images.isEmpty {
                CFLMessageImages(images: item.images, outgoing: item.outgoing, model: model,
                                 target: item.id.target, session: item.id.session, revision: item.sessionRevision, clientID: item.clientID)
            }
        }
    }
}

@MainActor
final class CFLConversationModel: ObservableObject {
    @Published var state = CFLChatState() {
        didSet {
            if oldValue.sessionId != state.sessionId || oldValue.sessionRevision != state.sessionRevision {
                cancelImageSelection()
            }
            let operations = Set(state.messages.compactMap(\.operationId))
            visiblePending = state.pending.filter { !operations.contains($0.operationId) || $0.sessionId != state.sessionId }
            hasUnknownPending = state.pending.contains { $0.status == .unknown }
            let input = ProjectionInput(target: connectedOrigin, session: state.sessionId, revision: state.sessionRevision, clientID: clientID, messages: state.messages,
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
        let revision: Int
        let clientID: UUID
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
        func rows(id: String, text: String, streaming: Bool, images: [CFLImageRef] = []) -> [CFLDisplayMessage] {
            let source = CFLReplyPresentation.visibleSource(text, streaming: streaming)
            let chunks = cache[id].flatMap { $0.source == source ? $0.chunks : nil }
                ?? CFLReplyPresentation.chunks(source)
            nextCache[id] = ReplyCache(source: source, chunks: chunks)
            if chunks.isEmpty && !images.isEmpty {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: 0), text: "", outgoing: false, markdown: true, images: images, sessionRevision: input.revision, clientID: input.clientID)]
            }
            return chunks.enumerated().map { index, chunk in
                CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: chunk.id), text: chunk.text, outgoing: false, markdown: true, images: index == chunks.count - 1 ? images : [], sessionRevision: input.revision, clientID: input.clientID)
            }
        }
        let messages = input.messages.flatMap { message in
            if message.isReminder {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text,
                                          outgoing: false, markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, isReminder: true)]
            }
            if message.role == "agent" { return rows(id: message.id, text: message.text, streaming: false, images: message.images ?? []) }
            return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text,
                                      outgoing: message.role == "user", markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID)]
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
    @Published private(set) var selectedImages: [CFLSelectedImage] = []
    @Published private(set) var isPreparingImages = false
    @Published private(set) var imagePageRevision = 0
    @Published private(set) var imagePageActive = true
    private(set) var draftRevision = 0
    private var draftObservation: AnyCancellable?
    private var client: CFLChatClient?
    private var clientID = UUID()
    private var observation: Task<Void, Never>?
    private var connectedOrigin: String?
    private var imageDraftOwner: (target: String, session: String)?
    private var selectionContext: CFLImageContext?
    private var awaitingImagePicker = false
    private var selectionTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var uncertainImageIDs: [UUID] = []
    private var uncertainDraftRevision: Int?

    init(draftChanges: AnyPublisher<String, Never>? = nil) {
        let changes = draftChanges ?? AppConfigStore.shared.composerDraftState.$text.dropFirst().eraseToAnyPublisher()
        draftObservation = changes.sink { [weak self] _ in self?.draftRevision &+= 1 }
    }

    deinit {
        observation?.cancel()
        projectionTask?.cancel()
        selectionTask?.cancel()
        if let client { Task { await client.disconnect() } }
    }

    var stateError: String? { state.error.map { message(for: $0) } }

    var imageContext: CFLImageContext? {
        guard let target = connectedOrigin, let session = state.sessionId else { return nil }
        return CFLImageContext(clientID: clientID, target: target, session: session, revision: state.sessionRevision)
    }

    var imagesBelongToCurrentSession: Bool {
        guard !selectedImages.isEmpty else { return true }
        guard let owner = imageDraftOwner, let current = imageContext else { return false }
        return owner.target == current.target && owner.session == current.session
    }

    var canAttachImages: Bool {
        state.connection == .online && state.imageLimits != nil && imageContext != nil
            && remainingImageSlots > 0 && imagesBelongToCurrentSession && !busy && uncertain == nil && !isPreparingImages
    }

    var remainingImageSlots: Int {
        max(0, (state.imageLimits?.maxImagesPerMessage ?? 0) - selectedImages.count)
    }

    func beginImageSelection() -> Bool {
        guard canAttachImages, let context = imageContext else { return false }
        selectionID = UUID()
        selectionContext = context
        imagePickerWillPresent()
        return true
    }

    func imagePickerWillPresent() { awaitingImagePicker = true }
    func imagePickerDidDismiss() { awaitingImagePicker = false }

    func cancelImageSelection() {
        selectionID = UUID()
        selectionContext = nil
        awaitingImagePicker = false
        selectionTask?.cancel()
        selectionTask = nil
        isPreparingImages = false
    }

    func pageDidDisappear() {
        // Presenting the full-screen camera can itself hide the chat view.
        // Keep its selection token until the picker returns; cancel ongoing preparation.
        if awaitingImagePicker { return }
        navigationDidLeavePage()
    }

    func navigationDidLeavePage() {
        imagePageActive = false
        imagePageRevision &+= 1
        cancelImageSelection()
    }

    func pageDidAppear() { imagePageActive = true }

    func removeImage(_ id: UUID) {
        selectedImages.removeAll { $0.id == id }
        if selectedImages.isEmpty { imageDraftOwner = nil }
    }

    func addPhotos(_ photos: [PhotosPickerItem]) {
        guard let context = selectionContext, context == imageContext, !photos.isEmpty else { return }
        let token = selectionID
        let previous = selectedImages.map(\.id)
        isPreparingImages = true
        selectionTask = Task { [weak self] in
            do {
                var images: [CFLSelectedImage] = []
                for photo in photos {
                    guard let data = try await photo.loadTransferable(type: Data.self) else { throw CFLFailure.invalidInput }
                    let type = photo.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredMIMEType
                    let image = try await Task.detached(priority: .userInitiated) { try Self.prepareImage(data, mediaType: type) }.value
                    try Task.checkCancellation()
                    images.append(image)
                }
                try await self?.appendImages(images, context: context, token: token, previous: previous)
            } catch { self?.imageSelectionFailed(error, context: context, token: token) }
            self?.finishImageSelection(token: token)
        }
    }

    func addCameraImage(_ image: UIImage) {
        guard let context = selectionContext, context == imageContext else { return }
        let token = selectionID
        let previous = selectedImages.map(\.id)
        isPreparingImages = true
        selectionTask = Task { [weak self] in
            do {
                guard let attachment = await Task.detached(priority: .userInitiated, operation: { ImageAttachment.from(image: image) }).value else { throw CFLFailure.invalidInput }
                let prepared = try await Task.detached(priority: .userInitiated) { try Self.prepareImage(attachment.data, mediaType: "image/jpeg") }.value
                try Task.checkCancellation()
                try await self?.appendImages([prepared], context: context, token: token, previous: previous)
            } catch { self?.imageSelectionFailed(error, context: context, token: token) }
            self?.finishImageSelection(token: token)
        }
    }

    nonisolated private static func prepareImage(_ data: Data, mediaType: String?) throws -> CFLSelectedImage {
        let supported = ["image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif"]
        let type: String
        let original: Data
        if let mediaType, supported[mediaType] != nil {
            type = mediaType
            original = data
        } else {
            guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else { throw CFLFailure.invalidInput }
            type = "image/jpeg"
            original = jpeg
        }
        let id = UUID()
        let name = "\(id.uuidString).\(supported[type]!)"
        let prepared = try CFLPreparedImage.prepare(name: name, mediaType: type, original: original)
        return CFLSelectedImage(id: id, attachment: ImageAttachment(id: id, data: original, mimeType: type, fileName: name, thumbnailData: prepared.preview), prepared: prepared)
    }

    private func appendImages(_ images: [CFLSelectedImage], context: CFLImageContext, token: UUID, previous: [UUID]) async throws {
        guard token == selectionID, context == imageContext, previous == selectedImages.map(\.id), let client else { throw CFLFailure.sessionChanged }
        try await client.validateImages((selectedImages + images).map(\.prepared))
        guard !Task.isCancelled, token == selectionID, context == imageContext, previous == selectedImages.map(\.id) else { throw CFLFailure.sessionChanged }
        imageDraftOwner = (context.target, context.session)
        selectedImages.append(contentsOf: images)
        notice = nil
    }

    private func imageSelectionFailed(_ error: Error, context: CFLImageContext, token: UUID) {
        guard !(error is CancellationError), token == selectionID, context == imageContext else { return }
        notice = NSLocalizedString("无法添加图片，请检查图片格式和大小。", comment: "Image selection error")
    }

    private func finishImageSelection(token: UUID) {
        guard token == selectionID else { return }
        isPreparingImages = false
        selectionContext = nil
        selectionTask = nil
    }

    func media(_ image: CFLImageRef, target: String?, session: String?, revision: Int, clientID: UUID, original: Bool = false) async throws -> Data {
        guard imagePageActive, let context = imageContext, isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID), let client else { throw CFLFailure.sessionChanged }
        let pageRevision = imagePageRevision
        let data = try await client.media(image, original: original, expectedSessionId: context.session, expectedSessionRevision: context.revision)
        guard imagePageActive, imagePageRevision == pageRevision, imageContext == context else { throw CFLFailure.sessionChanged }
        return data
    }

    func isCurrentMediaContext(target: String?, session: String?, revision: Int, clientID: UUID) -> Bool {
        guard let context = imageContext else { return false }
        return context.clientID == clientID && context.target == target && context.session == session && context.revision == revision
    }

    func restoreImages(from pending: CFLPending) async -> Bool {
        guard imagePageActive, let client, let context = imageContext, pending.target == context.target,
              pending.sessionId == context.session, !busy, !isPreparingImages,
              selectedImages.isEmpty, (pending.status == .failed || (pending.status == .unknown && !pending.dispatched)),
              let refs = pending.images, !refs.isEmpty else { return false }
        let originalDraft = AppConfigStore.shared.chatComposerDraft
        let originalRevision = draftRevision
        let pageRevision = imagePageRevision
        guard originalDraft.isEmpty else { return false }
        busy = true
        defer { busy = false }
        do {
            var restored: [CFLSelectedImage] = []
            for ref in refs {
                guard imagePageActive, imagePageRevision == pageRevision else { return false }
                let data = try await client.media(ref, original: true, expectedSessionId: context.session, expectedSessionRevision: context.revision)
                let image = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareImage(data, mediaType: ref.mediaType)
                }.value
                restored.append(image)
            }
            try await client.validateImages(restored.map(\.prepared))
            guard imagePageActive, imagePageRevision == pageRevision, imageContext == context,
                  selectedImages.isEmpty, draftRevision == originalRevision,
                  AppConfigStore.shared.chatComposerDraft == originalDraft else { return false }
            selectedImages = restored
            imageDraftOwner = (context.target, context.session)
            AppConfigStore.shared.chatComposerDraft = pending.text
            notice = nil
            return true
        } catch {
            if imagePageActive, imagePageRevision == pageRevision, imageContext == context {
                notice = NSLocalizedString("无法恢复图片，请检查连接或重新选择。", comment: "Image recovery failed")
            }
            return false
        }
    }

    func connect(origin: String) async {
        guard let origin = CFLHTTPSOrigin.normalized(origin), !origin.isEmpty,
              var components = URLComponents(string: origin) else { return }
        if client != nil && connectedOrigin == origin { return }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        cancelImageSelection()
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
        clientID = UUID()
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

    func send(_ text: String, draftRevision capturedRevision: Int) async -> Bool {
        guard let client, !busy, uncertain == nil, !isPreparingImages,
              imagesBelongToCurrentSession, let context = imageContext else { return false }
        let captured = selectedImages
        busy = true
        defer { busy = false }
        notice = nil
        do {
            _ = try await client.send(text, images: captured.map(\.prepared),
                                      expectedSessionId: context.session, expectedSessionRevision: context.revision)
            removeCapturedImages(captured.map(\.id))
            return imageContext == context
        } catch let error as CFLPendingStorageUncertain {
            uncertain = error.pending
            uncertainImageIDs = captured.map(\.id)
            uncertainDraftRevision = capturedRevision
            notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
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
                    if imageContext?.target == uncertain.target, imageContext?.session == uncertain.sessionId,
                       draftRevision == uncertainDraftRevision,
                       AppConfigStore.shared.chatComposerDraft == uncertain.text {
                        AppConfigStore.shared.chatComposerDraft = ""
                    }
                    notice = NSLocalizedString("内容已保存在本机，请在下方处理。", comment: "CFL stored input")
                    removeCapturedImages(uncertainImageIDs)
                } else {
                    notice = NSLocalizedString("内容未发送，可以继续编辑。", comment: "CFL unsent input")
                }
                self.uncertain = nil
                uncertainImageIDs = []
                uncertainDraftRevision = nil
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

    private func removeCapturedImages(_ ids: [UUID]) {
        let captured = Set(ids)
        selectedImages.removeAll { captured.contains($0.id) }
        if selectedImages.isEmpty { imageDraftOwner = nil }
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

enum CFLHeaderStatus: Equatable {
    case online, replying, connecting, offline

    init(hasOrigin: Bool, connection: CFLConnection, hasActiveTurn: Bool) {
        guard hasOrigin else { self = .offline; return }
        switch connection {
        case .online: self = hasActiveTurn ? .replying : .online
        case .connecting: self = .connecting
        case .offline, .accessDenied, .protocolError: self = .offline
        }
    }

    var label: String {
        switch self {
        case .online: return NSLocalizedString("CFL顶栏在线", comment: "Chat header online")
        case .replying: return NSLocalizedString("CFL顶栏回复中", comment: "Chat header replying")
        case .connecting: return NSLocalizedString("CFL顶栏连接中", comment: "Chat header connecting")
        case .offline: return NSLocalizedString("CFL顶栏离线", comment: "Chat header offline")
        }
    }

    var color: Color {
        switch self {
        case .online: return .green
        case .replying, .connecting: return .orange
        case .offline: return .red
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
    @ScaledMetric(relativeTo: .headline) private var headerTitleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var headerSubtitleSize: CGFloat = 12

    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { config.chatComposerDraft = $0 })
    }
    var body: some View {
        ZStack {
            ChatBackgroundLayer(isChatVisible: true).ignoresSafeArea()
            VStack(spacing: 0) {
                if model.state.connection != .online || model.hasUnknownPending || !model.imagesBelongToCurrentSession
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
                                    if message.isReminder {
                                        CFLReminderBubble(text: message.text)
                                        if !message.images.isEmpty {
                                            CFLMessageImages(images: message.images, outgoing: false, model: model,
                                                             target: message.id.target, session: message.id.session,
                                                             revision: message.sessionRevision, clientID: message.clientID)
                                        }
                                    } else {
                                        CFLNativeMessageBubble(item: message, model: model)
                                    }
                                }
                                ForEach(model.visibleReply) { reply in
                                    CFLNativeMessageBubble(item: reply, model: model)
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
        .onAppear { model.pageDidAppear() }
        .onDisappear { model.pageDidDisappear() }
    }

    private var navigationBar: some View {
        let titleFont = UIFont.systemFont(ofSize: headerTitleSize, weight: .semibold)
        let subtitleFont = UIFont.systemFont(ofSize: headerSubtitleSize)
        let height = titleFont.lineHeight + subtitleFont.lineHeight + 1 + 12
        let iconSize: CGFloat = 48
        let tintOpacity = LiquidGlassTintSetting.normalized(config.liquidGlassTintOpacity)
        let tint = colorScheme == .dark ? Color.black.opacity(tintOpacity) : Color.white.opacity(tintOpacity)
        let headerStatus = CFLHeaderStatus(hasOrigin: !config.cflHTTPSOrigin.isEmpty,
                                           connection: model.state.connection,
                                           hasActiveTurn: model.state.activeTurnId != nil)
        return ChatNavigationBar {
            ChatNavigationIconSurface(
                content: Image(systemName: "list.bullet").etFont(.system(size: 17, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText.opacity(0.5)).frame(width: iconSize, height: iconSize),
                usesLiquidGlass: config.enableLiquidGlass, tint: tint,
                strokeColor: Color.white.opacity(0.2), lineWidth: 0.5
            ).allowsHitTesting(false).accessibilityHidden(true)
        } center: {
            ChatNavigationPillSurface(
                content: VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(content: model.state.name.isEmpty ? NSLocalizedString("聊天", comment: "CFL chat title") : model.state.name,
                                uiFont: titleFont).foregroundColor(TelegramColors.navBarText)
                    HStack(spacing: 5) {
                        Circle().fill(headerStatus.color).frame(width: 6, height: 6).accessibilityHidden(true)
                        MarqueeText(content: headerStatus.label, uiFont: subtitleFont)
                            .foregroundColor(TelegramColors.navBarSubtitle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 22).padding(.vertical, 6).frame(height: height),
                usesLiquidGlass: config.enableLiquidGlass, tint: tint, selected: false
            )
        } trailing: {
            Button(action: openSettings) {
                ChatNavigationIconSurface(
                    content: Image(systemName: "gearshape").etFont(.system(size: 17, weight: .semibold))
                        .foregroundColor(TelegramColors.navBarText).frame(width: iconSize, height: iconSize),
                    usesLiquidGlass: config.enableLiquidGlass, tint: tint,
                    strokeColor: Color.white.opacity(0.2), lineWidth: 0.5
                )
            }.buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel(NSLocalizedString("设置", comment: "Settings"))
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
            if !model.imagesBelongToCurrentSession {
                Text(NSLocalizedString("图片属于之前的会话，请切回或移除图片。", comment: "Image draft session"))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                let capturedRevision = model.draftRevision
                Task {
                    if await model.send(captured, draftRevision: capturedRevision) {
                        if model.draftRevision == capturedRevision && draft.text == captured { config.chatComposerDraft = "" }
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
                canSend: !model.busy && !model.isPreparingImages && model.uncertain == nil
                    && (draft.hasSendableText || !model.selectedImages.isEmpty)
                    && model.imagesBelongToCurrentSession && model.state.connection == .online,
                isSubmitting: model.busy || model.isPreparingImages,
                isResponding: model.state.activeTurnId != nil,
                hasImages: !model.selectedImages.isEmpty
            ),
            images: model.selectedImages,
            canAttachImages: model.canAttachImages,
            remainingImageSlots: model.remainingImageSlots,
            isPreparingImages: model.isPreparingImages,
            beginImageSelection: { model.beginImageSelection() },
            imagePickerDidDismiss: { model.imagePickerDidDismiss() },
            addPhotos: { model.addPhotos($0) },
            addCameraImage: { model.addCameraImage($0) },
            removeImage: { model.removeImage($0) }
        )
    }

    private func pendingRow(_ item: CFLPending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).textSelection(.enabled)
            if let images = item.images, !images.isEmpty {
                Text(String(format: NSLocalizedString("包含 %d 张图片", comment: "Pending images"), images.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(pendingText(item)).font(.caption).foregroundStyle(.secondary)
            if item.sessionId != model.state.sessionId {
                Text(NSLocalizedString("属于其他会话", comment: "CFL other session")).font(.caption).foregroundStyle(.secondary)
            }
            if item.status == .failed || (item.status == .unknown && !item.dispatched) {
                if item.images?.isEmpty == false {
                    Button(NSLocalizedString("恢复到输入框", comment: "Recover image draft")) {
                        if draft.text.isEmpty && model.selectedImages.isEmpty {
                            Task { _ = await model.restoreImages(from: item) }
                        } else { noticeDraftOccupied() }
                    }.font(.caption).disabled(model.busy || item.sessionId != model.state.sessionId)
                } else {
                    Button(NSLocalizedString("复制到输入框", comment: "CFL recover input")) {
                        if draft.text.isEmpty && model.selectedImages.isEmpty { config.chatComposerDraft = item.text }
                        else { noticeDraftOccupied() }
                    }.font(.caption)
                }
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
            if let images = item.images, !images.isEmpty {
                Text(String(format: NSLocalizedString("包含 %d 张图片", comment: "Pending images"), images.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        case .failed:
            if item.images?.isEmpty == false { return NSLocalizedString("发送失败，可以恢复内容后重新编辑。", comment: "CFL image send failed") }
            return NSLocalizedString("发送失败，可以复制文字后重新编辑。", comment: "CFL failed")
        }
    }

}
#endif
