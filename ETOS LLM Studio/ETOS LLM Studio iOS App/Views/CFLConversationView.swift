#if os(iOS)
import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
import ETOSCore
import ExyteChat
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
    var markdownSources: CFLMarkdownImageSources? = nil
    var markdownSourcesRevision = 0
    var isReminder = false
    var voice: CFLVoiceRef? = nil
    var imageState: CFLImageState? = nil
    var previews: [CFLLocalImagePreview] = []
    var pending: CFLPending? = nil
}

/// Exyte groups by date even when date headers are hidden.  The CFL array is
/// already authoritative, so every display row uses one invisible date group.
enum CFLTimelineRow: Sendable {
    case message(CFLDisplayMessage)
    case pending(CFLPending)
    case otherTarget(CFLPending)
    case bottomSpace(height: CGFloat)

    private static let outgoingUser = ExyteChat.User(id: "user", name: "", avatarURL: nil, isCurrentUser: true)
    private static let incomingUser = ExyteChat.User(id: "agent", name: "", avatarURL: nil, isCurrentUser: false)
    private static let spacingUser = ExyteChat.User(id: "etos:space", name: "", avatarURL: nil, isCurrentUser: false)
    private static let groupingDate = Date(timeIntervalSince1970: 1_600_000_000)

    private static func key(_ parts: [String]) -> String {
        // The JSON encoding preserves boundaries even when IDs contain separators.
        (try? JSONEncoder().encode(parts).base64EncodedString()) ?? ""
    }

    private static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value).base64EncodedString()) ?? ""
    }

    private static func revision(_ parts: [String]) -> UUID {
        let bytes = Array(SHA256.hash(data: (try? JSONEncoder().encode(parts)) ?? Data()).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var message: ExyteChat.Message {
        let id: String
        let text: String
        let outgoing: Bool
        let signature: [String]
        switch self {
        case .message(let item):
            id = Self.key(["message", item.id.target ?? "", item.id.session ?? "", item.id.message, String(item.id.offset)])
            text = item.text
            outgoing = item.outgoing
            let imageInfo = item.images.map { "image:" + Self.encoded($0) }
            let previews = item.previews.map {
                "preview:" + Self.key([$0.sessionId, $0.originOperationId, $0.draftId,
                                       $0.attachmentId ?? "", String($0.order), String($0.data.count)])
            }
            signature = [text, String(item.markdown), String(item.sessionRevision), item.clientID.uuidString,
                         String(item.markdownSourcesRevision), String(item.isReminder), item.voice?.id ?? "",
                         item.imageState?.rawValue ?? "", item.pending.map(Self.encoded) ?? ""] + imageInfo + previews
        case .pending(let item), .otherTarget(let item):
            let kind: String
            if case .pending = self { kind = "pending" } else { kind = "other-target" }
            id = Self.key([kind, item.target, item.sessionId, item.operationId])
            text = item.text
            outgoing = true
            signature = [Self.encoded(item)]
        case .bottomSpace(let height):
            id = "etos:bottom-space"
            text = ""
            outgoing = true
            signature = [String(describing: height)]
        }
        let user: ExyteChat.User
        if case .bottomSpace = self { user = Self.spacingUser }
        else { user = outgoing ? Self.outgoingUser : Self.incomingUser }
        var result = ExyteChat.Message(id: id, user: user,
                                       createdAt: Self.groupingDate, text: text, customData: ["etosRow": self])
        // Exyte's Message.Equatable intentionally ignores customData. Preserve
        // row identity, but refresh the cell when its visible media state changes.
        result.triggerRedraw = Self.revision(signature)
        return result
    }

    func message(topPadding: CGFloat, bottomPadding: CGFloat) -> ExyteChat.Message {
        var result = message
        result.customData["etosTopPadding"] = topPadding
        result.customData["etosBottomPadding"] = bottomPadding
        result.triggerRedraw = Self.revision([result.triggerRedraw?.uuidString ?? "", String(describing: topPadding), String(describing: bottomPadding)])
        return result
    }
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

/// A dispatched unknown outcome is reconciled in the background, never retried as a failure.
enum CFLPendingPresentation {
    static func needsAction(_ pending: CFLPending, busy: Bool) -> Bool {
        pending.status == .failed || (pending.status == .unknown && !pending.dispatched && !busy)
    }
}

struct CFLFailedSendIndicator: View {
    let pending: CFLPending
    @ObservedObject var model: CFLConversationModel

    var body: some View {
        if pending.status == .failed && pending.dispatched {
            Button { Task { await model.retry(pending) } } label: {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                    .frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(NSLocalizedString("重试", comment: "Retry")))
            .disabled(model.busy || model.uncertain != nil || model.state.connection != .online)
        } else {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                .frame(width: 32, height: 44)
                .accessibilityLabel(Text(NSLocalizedString("发送失败", comment: "Send failed")))
        }
    }
}

struct CFLFailedSendActions: View {
    let pending: CFLPending
    @ObservedObject var model: CFLConversationModel

    var body: some View {
        if pending.status == .failed && pending.dispatched {
            Button(NSLocalizedString("重试", comment: "Retry")) { Task { await model.retry(pending) } }
                .disabled(model.busy || model.uncertain != nil || model.state.connection != .online)
        }
        if !pending.dispatched {
            Button(NSLocalizedString("恢复到输入框", comment: "Recover unsent input")) {
                let config = AppConfigStore.shared
                guard config.chatComposerDraft.isEmpty && model.selectedImages.isEmpty else {
                    model.notice = NSLocalizedString("输入框已有文字，请先处理。", comment: "CFL draft occupied")
                    return
                }
                if pending.images?.isEmpty == false { Task { _ = await model.restoreImages(from: pending) } }
                else { config.chatComposerDraft = pending.text }
            }.disabled(model.busy)
        }
        Button(NSLocalizedString("移除", comment: "Remove"), role: .destructive) {
            Task { await model.dismiss(pending) }
        }.disabled(model.busy)
    }
}

private struct CFLHistoryHeader: View {
    @ObservedObject var model: CFLConversationModel
    let topPadding: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            if model.state.before != nil {
                Button(NSLocalizedString("加载更早的消息", comment: "CFL history")) {
                    Task { await model.earlier() }
                }.disabled(model.busy)
            }
            if model.state.historySyncFailed {
                HStack {
                    Text(NSLocalizedString("历史", comment: "History"))
                    Button(NSLocalizedString("重试", comment: "Retry")) { Task { await model.retryHistory() } }
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, model.state.before != nil || model.state.historySyncFailed ? topPadding : 0)
    }
}

/// Adapts a server-owned display row to ETOS's existing bubble presentation.
/// The UUID belongs only to this view state; CFL identities remain unchanged.
private struct CFLNativeMessageBubble: View {
    let item: CFLDisplayMessage
    @ObservedObject var model: CFLConversationModel
    @ObservedObject var voicePlayer: CFLVoicePlayer
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @StateObject private var renderState: ChatMessageRenderState
    @StateObject private var markdownImageStatus = CFLMarkdownImageStatus()
    @State private var showActions = false

    private var failedPending: CFLPending? {
        guard let pending = item.pending, CFLPendingPresentation.needsAction(pending, busy: model.busy) else { return nil }
        return pending
    }

    private var imageStoreContext: CFLMarkdownImageStore.Context {
        .init(target: item.id.target, session: item.id.session, revision: item.sessionRevision,
              clientID: item.clientID)
    }

    init(item: CFLDisplayMessage, model: CFLConversationModel, voicePlayer: CFLVoicePlayer) {
        self.item = item
        self.model = model
        self.voicePlayer = voicePlayer
        _renderState = StateObject(wrappedValue: ChatMessageRenderState(
            message: ChatMessage(role: item.outgoing ? .user : .assistant, content: item.text)
        ))
    }

    var body: some View {
        VStack(alignment: item.outgoing ? .trailing : .leading, spacing: 4) {
            if let voice = item.voice {
                CFLVoiceMessage(item: item, voice: voice, model: model, player: voicePlayer)
            }
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
                    onOpenMore: { _ in showActions = true },
                    leadingAccessory: failedPending.map { AnyView(CFLFailedSendIndicator(pending: $0, model: model)) }
                )
                .id("\(markdownImageStatus.attempt)|\(item.markdownSourcesRevision)|\(item.clientID)|\(item.sessionRevision)|\(String(describing: model.imageContext))")
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
                    if let pending = failedPending { CFLFailedSendActions(pending: pending, model: model) }
                    Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
                }
                .environment(\.markdownRemoteImagesEnabled, false)
                .environment(\.cflMarkdownImages, item.markdown ? CFLMarkdownImageContext(model: model, target: item.id.target, session: item.id.session, revision: item.sessionRevision, clientID: item.clientID, status: markdownImageStatus, originalSources: item.markdownSources, sourceRevision: item.markdownSourcesRevision) : nil)
                .onChange(of: item.text) { _, text in
                    var next = renderState.message
                    next.content = text
                    renderState.update(with: next)
                    renderState.updateVisualMessage(next)
                }
                .onChange(of: item.markdownSourcesRevision) { _, _ in
                    markdownImageStatus.invalidate()
                }
                if markdownImageStatus.inlineFailed {
                    Button { markdownImageStatus.retry() } label: {
                        Label(NSLocalizedString("图片加载失败，点按重试", comment: "Retry loading image"), systemImage: "photo.badge.exclamationmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            if !item.images.isEmpty || !item.previews.isEmpty {
                CFLMessageImages(images: item.images, previews: item.previews, outgoing: item.outgoing, model: model,
                                 target: item.id.target, session: item.id.session, revision: item.sessionRevision, clientID: item.clientID,
                                 failedPending: failedPending, showFailureIndicator: item.text.isEmpty)
            } else if let imageState = item.imageState, imageState != .ready {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
                        if imageState == .preparing {
                            ProgressView().accessibilityLabel(NSLocalizedString("生成中", comment: "Generating"))
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "photo.badge.exclamationmark")
                                Text(NSLocalizedString(imageState == .failed ? "图片生成失败" : "图片状态未确认", comment: "Image generation status"))
                                    .font(.caption2).multilineTextAlignment(.center)
                            }.foregroundStyle(.secondary).padding(4)
                        }
                    }.frame(width: 180, height: 120)
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 8)
            }
        }
        .onChange(of: model.imagePageActive) { _, active in
            if !active { markdownImageStatus.invalidate() }
        }
        .onChange(of: model.imageContext) { _, _ in markdownImageStatus.invalidate() }
        .onChange(of: imageStoreContext, initial: true) { _, context in
            markdownImageStatus.updateContext(context)
        }
        .onDisappear { markdownImageStatus.invalidate() }
    }
}

@MainActor
private final class CFLWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func signIn(url: URL) async throws -> URL {
        guard continuation == nil else { throw CFLAuthorizationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "etosllmstudio") { [weak self] url, error in
                Task { @MainActor in
                    if let url { self?.finish(.success(url)) }
                    else if let error {
                        let nsError = error as NSError
                        if nsError.domain == ASWebAuthenticationSessionError.errorDomain &&
                            nsError.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue {
                            self?.finish(.failure(CFLAuthorizationError.cancelled))
                        } else { self?.finish(.failure(error)) }
                    } else { self?.finish(.failure(CFLAuthorizationError.unavailable)) }
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { finish(.failure(CFLAuthorizationError.unavailable)) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        session = nil
        continuation?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

@MainActor
final class CFLConversationModel: ObservableObject {
    private struct PendingAnchor: Equatable, Sendable {
        let session: String
        let after: String?
        var predecessor: String? = nil
    }
    private var pendingAnchors: [String: PendingAnchor] = [:]
    private var nextSendAnchor: PendingAnchor?
    @Published var state = CFLChatState() {
        didSet {
            if oldValue.sessionId != state.sessionId || oldValue.sessionRevision != state.sessionRevision {
                cancelImageSelection()
                pendingAnchors.removeAll()
                nextSendAnchor = nil
            }
            if let session = state.sessionId {
                let previous = Set(oldValue.localDrafts.map(\.operationId) + oldValue.pending.filter { $0.sessionId == session }.map(\.operationId))
                let incoming = state.localDrafts.filter { $0.sessionId == session }.map { ($0.operationId, Optional<String>.none) } +
                    state.pending.filter { $0.sessionId == session }.map { ($0.operationId, $0.retrySource) }
                for (operation, source) in incoming where !previous.contains(operation) && pendingAnchors[operation] == nil {
                    if let source, let anchor = pendingAnchors[source] {
                        pendingAnchors[operation] = anchor
                    } else {
                        pendingAnchors[operation] = nextSendAnchor?.session == session
                            ? nextSendAnchor : PendingAnchor(session: session, after: oldValue.messages.last?.id)
                        if nextSendAnchor?.session == session { nextSendAnchor = nil }
                    }
                }
                let active = Set(incoming.flatMap { [$0.0, $0.1].compactMap { $0 } })
                pendingAnchors = pendingAnchors.filter { $0.value.session == session && active.contains($0.key) }
            }
            let input = ProjectionInput(target: connectedOrigin, session: state.sessionId, revision: state.sessionRevision, clientID: clientID, messages: state.messages,
                                        reply: state.connection == .online ? state.streamingReply : nil,
                                        drafts: state.localDrafts, previews: state.localPreviews, pending: state.pending,
                                        otherTargetPending: state.otherTargetPending,
                                        anchors: pendingAnchors)
            releaseUnusedPreviews()
            guard input != latestProjection else { return }
            if input.session != latestProjection?.session {
                visibleMessages = []
                visibleReply = []
                timelineRows = []
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
        let drafts: [CFLLocalDraft]
        let previews: [CFLLocalImagePreview]
        let pending: [CFLPending]
        let otherTargetPending: [CFLPending]
        let anchors: [String: PendingAnchor]
    }
    private struct ReplyCache: Sendable {
        let source: String
        let chunks: [CFLReplyPresentation.Chunk]
        let imageSources: CFLMarkdownImageSources
        let chunkImages: [Int: ChunkImageState]
    }
    private struct ChunkImageState: Sendable {
        let targets: [CFLMarkdownImageTarget]
        let revision: Int
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
    var timelineTransaction: TableUpdateTransaction?

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
                let update = {
                    guard self.latestProjection == input else { return }
                    self.visibleMessages = result.messages
                    self.visibleReply = result.reply
                    var rows = (result.messages + result.reply).map(CFLTimelineRow.message)
                    rows += input.pending.filter { $0.sessionId != input.session && CFLPendingPresentation.needsAction($0, busy: false) }.map(CFLTimelineRow.pending)
                    rows += input.otherTargetPending.filter { CFLPendingPresentation.needsAction($0, busy: false) }.map(CFLTimelineRow.otherTarget)
                    self.timelineRows = rows
                }
                if let transaction = self.timelineTransaction {
                    await transaction(animationMode: .natural, update)
                } else {
                    update()
                }
            }
            self.projectionTask = nil
            self.startProjectionIfNeeded()
        }
    }

    nonisolated private static func project(_ input: ProjectionInput, cache: [String: ReplyCache]) -> ProjectionResult {
        let messageIDs = Set(input.messages.map(\.id))
        var nextCache: [String: ReplyCache] = [:]
        func rows(id: String, text: String, streaming: Bool, images: [CFLImageRef] = [], imageState: CFLImageState? = nil) -> [CFLDisplayMessage] {
            let source = CFLReplyPresentation.visibleSource(text, streaming: streaming)
            let chunks = cache[id].flatMap { $0.source == source ? $0.chunks : nil }
                ?? CFLReplyPresentation.chunks(source)
            let imageSources = cache[id].flatMap { $0.source == source ? $0.imageSources : nil }
                ?? CFLMarkdownImageSources(markdown: source)
            var chunkImages: [Int: ChunkImageState] = [:]
            for chunk in chunks where chunk.text.contains("![") {
                let normalized = ETPreparedMarkdownRenderPayload.normalizedMarkdownForStreaming(chunk.text)
                let targets = imageSources.targets(in: normalized)
                let previous = cache[id]?.chunkImages[chunk.id]
                let revision = previous.map { $0.targets == targets ? $0.revision : $0.revision &+ 1 } ?? 1
                chunkImages[chunk.id] = ChunkImageState(targets: targets, revision: revision)
            }
            nextCache[id] = ReplyCache(source: source, chunks: chunks, imageSources: imageSources, chunkImages: chunkImages)
            if chunks.isEmpty && (!images.isEmpty || imageState != nil) {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: 0), text: "", outgoing: false, markdown: true, images: images, sessionRevision: input.revision, clientID: input.clientID, imageState: imageState)]
            }
            return chunks.enumerated().map { index, chunk in
                CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: chunk.id), text: chunk.text, outgoing: false, markdown: true, images: index == chunks.count - 1 ? images : [], sessionRevision: input.revision, clientID: input.clientID, markdownSources: imageSources, markdownSourcesRevision: chunkImages[chunk.id]?.revision ?? 0, imageState: index == chunks.count - 1 ? imageState : nil)
            }
        }
        func messageRows(_ message: CFLMessage) -> [CFLDisplayMessage] {
            let operation = message.operationId
            if let operation, let source = input.pending.first(where: { $0.sessionId == input.session && $0.operationId == operation })?.retrySource,
               input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == source }),
               !input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == operation }) {
                return []
            }
            if let voice = message.voice {
                let audio = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: -1), text: "", outgoing: false, markdown: false, images: [], sessionRevision: input.revision, clientID: input.clientID, voice: voice)
                if message.text.isEmpty && (message.images?.isEmpty ?? true) { return [audio] }
                if message.isReminder {
                    return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text, outgoing: false, markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, isReminder: true), audio]
                }
                if message.role == "agent" {
                    return rows(id: message.id, text: message.text, streaming: false, images: message.images ?? []) + [audio]
                }
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text, outgoing: message.role == "user", markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID), audio]
            }
            if message.isReminder {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text,
                                          outgoing: false, markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, isReminder: true)]
            }
            if message.role == "agent" { return rows(id: message.id, text: message.text, streaming: message.textState == .streaming, images: message.images ?? [], imageState: message.imageState) }
            let previews = input.previews.filter { preview in
                preview.sessionId == input.session && preview.operationId == operation &&
                    (message.images ?? []).contains(where: { $0.attachmentId == preview.attachmentId })
            }
            let rowID = previews.first.map { "local:\($0.originOperationId)" } ?? operation.map { "local:\($0)" } ?? message.id
            return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: rowID, offset: 0), text: message.text,
                                      outgoing: message.role == "user", markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, previews: previews)]
        }
        var groups = input.messages.map { (source: Optional($0.id), rows: messageRows($0)) }.filter { !$0.rows.isEmpty }
        let messageOperations = Set(input.messages.compactMap { message -> String? in
            guard let operation = message.operationId else { return nil }
            if let source = input.pending.first(where: { $0.sessionId == input.session && $0.operationId == operation })?.retrySource,
               input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == source }),
               !input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == operation }) { return nil }
            return operation
        })
        var tails: [String: String] = [:]
        func insert(_ row: CFLDisplayMessage, operation: String, source: String?) {
            let observed = input.messages.firstIndex { $0.operationId == operation }
            let anchor = input.anchors[operation]
            let after = anchor?.after
            var index = groups.count
            if let observed {
                for next in input.messages.dropFirst(observed + 1) {
                    if let found = groups.firstIndex(where: { $0.source == next.id }) { index = found; break }
                }
            } else {
                let key = after ?? ""
                let previousMessage = anchor?.predecessor.flatMap { predecessor in
                    input.messages.first(where: { $0.operationId == predecessor })?.id
                }
                let previousIndex = anchor?.predecessor.flatMap { predecessor in
                    groups.firstIndex(where: { $0.source == "pending:\(predecessor)" || (previousMessage != nil && $0.source == previousMessage) })
                } ?? -1
                let tailIndex = tails[key].flatMap { tail in groups.firstIndex(where: { $0.source == tail }) } ?? -1
                let afterIndex = after.flatMap { anchor in groups.firstIndex(where: { $0.source == anchor }) } ?? -1
                let latest = max(previousIndex, tailIndex, afterIndex)
                if latest >= 0 { index = latest + 1 }
                else if anchor != nil && after == nil { index = 0 }
                tails[key] = "pending:\(operation)"
            }
            groups.insert((source: source ?? "pending:\(operation)", rows: [row]), at: index)
        }
        for draft in input.drafts where draft.sessionId == input.session && !messageOperations.contains(draft.operationId) {
            let row = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "local:\(draft.operationId)", offset: 0), text: draft.text, outgoing: true, markdown: false, images: [], sessionRevision: input.revision, clientID: input.clientID, previews: draft.images)
            insert(row, operation: draft.operationId, source: nil)
        }
        let pendingRows = input.pending.filter { pending in
            pending.sessionId == input.session && !messageOperations.contains(pending.operationId) &&
                !input.drafts.contains(where: { $0.sessionId == pending.sessionId && $0.operationId == pending.operationId })
        }
        for pending in pendingRows {
            let previews = input.previews.filter { $0.sessionId == input.session && $0.operationId == (pending.retrySource ?? pending.operationId) }.sorted { $0.order < $1.order }
            let identity = previews.first?.originOperationId ?? pending.retrySource ?? pending.operationId
            let row = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "local:\(identity)", offset: 0), text: pending.text, outgoing: true, markdown: false, images: pending.images ?? [], sessionRevision: input.revision, clientID: input.clientID, previews: previews, pending: pending)
            insert(row, operation: pending.operationId, source: input.messages.first(where: { $0.operationId == pending.operationId })?.id)
        }
        let reply: [CFLDisplayMessage]
        if let streaming = input.reply, !messageIDs.contains(streaming.id) {
            reply = rows(id: streaming.id, text: streaming.text, streaming: true)
        } else { reply = [] }
        return ProjectionResult(messages: groups.flatMap(\.rows), reply: reply, cache: nextCache)
    }
    @Published private(set) var visibleMessages: [CFLDisplayMessage] = []
    @Published private(set) var visibleReply: [CFLDisplayMessage] = []
    @Published private(set) var timelineRows: [CFLTimelineRow] = []
    private func releaseUnusedPreviews() {
        guard let client, let session = state.sessionId else { return }
        let visible = Set(state.messages.compactMap(\.operationId))
        let inFlight = Set(state.pending.filter { $0.sessionId == session }.flatMap { [$0.operationId, $0.retrySource].compactMap { $0 } })
        let drafts = Set(state.localDrafts.filter { $0.sessionId == session }.map(\.operationId))
        let unused = Set(state.localPreviews.filter { $0.sessionId == session && !visible.contains($0.operationId) && !inFlight.contains($0.operationId) && !drafts.contains($0.operationId) }.map(\.operationId))
        guard !unused.isEmpty else { return }
        Task { for operation in unused { await client.releasePreviews(sessionId: session, operationId: operation) } }
    }
    @Published var busy = false
    @Published var notice: String?
    @Published private(set) var offlineSendRevision = 0
    @Published private(set) var signInError: String?
    @Published private(set) var needsSignIn = false
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
    private let authorization = CFLAuthorization(store: CFLKeychainCredentialStore())
    private let webAuthentication = CFLWebAuthentication()
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
    var canSignIn: Bool { connectedOrigin != nil && !busy }

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
        do {
            let data = try await client.media(image, original: original, expectedSessionId: context.session, expectedSessionRevision: context.revision)
            guard imagePageActive, imagePageRevision == pageRevision, imageContext == context else { throw CFLFailure.sessionChanged }
            return data
        } catch {
            if !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context { recordAuthorizationFailure(error) }
            throw error
        }
    }

    func voice(_ voice: CFLVoiceRef, target: String?, session: String?, revision: Int, clientID: UUID) async throws -> Data {
        guard imagePageActive, let context = imageContext,
              isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID),
              let client else { throw CFLFailure.sessionChanged }
        let pageRevision = imagePageRevision
        do {
            let data = try await client.voice(voice, expectedSessionId: context.session, expectedSessionRevision: context.revision)
            guard !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context else { throw CFLFailure.sessionChanged }
            return data
        } catch {
            if !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context { recordAuthorizationFailure(error) }
            throw error
        }
    }

    func markdownImage(_ source: String, target: String?, session: String?, revision: Int, clientID: UUID) async throws -> Data {
        guard imagePageActive, let context = imageContext,
              isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID),
              let client else { throw CFLFailure.sessionChanged }
        let pageRevision = imagePageRevision
        do {
            let data = try await client.markdownImage(source, expectedSessionId: context.session, expectedSessionRevision: context.revision)
            guard !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context else { throw CFLFailure.sessionChanged }
            return data
        } catch {
            if !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context { recordAuthorizationFailure(error) }
            throw error
        }
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
            if !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context {
                if !recordAuthorizationFailure(error) {
                    notice = NSLocalizedString("无法恢复图片，请检查连接或重新选择。", comment: "Image recovery failed")
                }
            }
            return false
        }
    }

    func connect(origin: String) async {
        await connect(origin: origin, replacingClient: false)
    }

    private func connect(origin: String, replacingClient: Bool) async {
        guard let origin = CFLHTTPSOrigin.normalized(origin), !origin.isEmpty,
              var components = URLComponents(string: origin) else { return }
        if !replacingClient && client != nil && connectedOrigin == origin { return }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        cancelImageSelection()
        AppConfigStore.shared.cflHTTPSOrigin = origin
        observation?.cancel()
        if let client { await client.disconnect() }
        if connectedOrigin != origin {
            do { try await authorization.select(origin: origin) }
            catch { notice = message(for: error); return }
            needsSignIn = false
            signInError = nil
        }
        client = nil
        connectedOrigin = nil
        state = CFLChatState()
        notice = nil
        if !replacingClient { uncertain = nil }
        components.scheme = "wss"
        components.path = "/api/chat/socket"
        guard let socketURL = components.url,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            notice = NSLocalizedString("无法保存聊天状态。", comment: "CFL storage error")
            return
        }
        let store = CFLFilePendingStore(file: support.appendingPathComponent("CFL/pending.json"))
        let authorization = self.authorization
        let next = CFLChatClient(target: origin, store: store,
                                 imageHTTP: CFLAuthorizedHTTP(authorization: authorization), transport: {
            let request = try await authorization.authenticatedRequest(URLRequest(url: socketURL))
            return CFLAuthorizedSocket(socket: CFLWebSocketTransport(request: request), authorization: authorization)
        })
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

    func signIn() async {
        guard let origin = connectedOrigin, !busy else { return }
        let startingClient = clientID
        busy = true
        notice = nil
        signInError = nil
        let result = await CFLSignInFlow.run(
            begin: { try await authorization.begin() },
            authenticate: { try await webAuthentication.signIn(url: $0.url) },
            complete: { try await authorization.complete($0, callback: $1) },
            isCurrent: { connectedOrigin == origin && clientID == startingClient },
            isCancellation: { ($0 as? CFLAuthorizationError) == .cancelled },
            isSuperseded: { ($0 as? CFLAuthorizationError) == .superseded }
        )
        switch result {
        case .completed:
            needsSignIn = false
            busy = false
            await connect(origin: origin, replacingClient: true)
        case .cancelled, .superseded:
            busy = false
        case .failed(let error):
            recordAuthorizationFailure(error)
            let description = message(for: error)
            signInError = description
            notice = description
            busy = false
        }
    }

    func send(_ text: String, draftRevision capturedRevision: Int) async -> Bool {
        guard let client, !busy, !needsSignIn, uncertain == nil, !isPreparingImages,
              imagesBelongToCurrentSession, let context = imageContext else { return false }
        let captured = selectedImages
        capturePendingAnchor(session: context.session)
        busy = true
        defer { busy = false }
        notice = nil
        do {
            _ = try await client.send(text, images: captured.map(\.prepared),
                                      expectedSessionId: context.session, expectedSessionRevision: context.revision)
            removeCapturedImages(captured.map(\.id))
            return imageContext == context
        } catch let error as CFLPendingStorageUncertain {
            nextSendAnchor = nil
            uncertain = error.pending
            uncertainImageIDs = captured.map(\.id)
            uncertainDraftRevision = capturedRevision
            notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
        } catch {
            nextSendAnchor = nil
            if imageContext == context { recordAuthorizationFailure(error) }
            if (error as? CFLFailure) == .offline {
                offlineSendRevision &+= 1
            } else {
                notice = message(for: error)
            }
        }
        return false
    }

    func capturePendingAnchor(session: String) {
        nextSendAnchor = PendingAnchor(session: session, after: state.messages.last?.id,
                                       predecessor: state.pending.last(where: { $0.sessionId == session })?.operationId)
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

    func retryHistory() async {
        guard let client else { return }
        await client.retryHistory()
    }

    func retry(_ pending: CFLPending) async {
        guard let client, !busy, uncertain == nil, pending.sessionId == state.sessionId else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.retryFailed(sessionId: pending.sessionId, operationId: pending.operationId,
                                             expectedSessionRevision: state.sessionRevision)
        } catch let error as CFLPendingStorageUncertain {
            uncertain = error.pending
            notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
        } catch { notice = message(for: error) }
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

    @discardableResult
    func recordAuthorizationFailure(_ error: Error) -> Bool {
        guard (error as? CFLFailure) == .accessDenied || (error as? CFLAuthorizationError) == .authorizationRequired else { return false }
        needsSignIn = true
        notice = NSLocalizedString("CFL认证需要重新登录", comment: "CFL sign in required")
        return true
    }

    private func message(for error: Error) -> String {
        if let error = error as? CFLAuthorizationError {
            switch error {
            case .authorizationRequired, .invalidCallback: return NSLocalizedString("CFL认证需要重新登录", comment: "CFL sign in required")
            case .storage: return NSLocalizedString("CFL认证无法保存", comment: "CFL credential storage error")
            case .cancelled, .superseded: return ""
            case .invalidOrigin, .unavailable: return NSLocalizedString("CFL认证暂时不可用", comment: "CFL authentication unavailable")
            }
        }
        switch error as? CFLFailure {
        case .offline: return NSLocalizedString("连接已断开，请等待重新连接。", comment: "CFL offline")
        case .accessDenied: return NSLocalizedString("CFL认证需要重新登录", comment: "CFL sign in required")
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
    @StateObject private var voicePlayer = CFLVoicePlayer()
    @State private var pendingRemoval: CFLPending?
    @State private var scrollToBottomRevision = 0
    @State private var timelineScroll: ScrollToParams?
    @State private var showScrollToBottom = false
    @State private var composerHeight: CGFloat = 66
    @State private var composerFocused = false
    @State private var sendToast: String?
    @State private var sendToastRevision = 0
    private let timelineEdgeFade: CGFloat = 20
    private let navigationOverlayHeight: CGFloat = 64
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var requiresSignIn: Bool {
        model.needsSignIn || model.state.connection == .accessDenied
    }

    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { config.chatComposerDraft = $0 })
    }
    var body: some View {
        ZStack {
            ChatBackgroundLayer(isChatVisible: true).ignoresSafeArea()
            VStack(spacing: 0) {
                if requiresSignIn {
                    signInView
                } else {
                    if config.cflHTTPSOrigin.isEmpty || !model.imagesBelongToCurrentSession
                        || model.uncertain != nil || model.notice != nil || model.stateError != nil {
                        connectionStatus
                            .padding(.top, navigationOverlayHeight)
                    }
                    conversationTimeline
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .topTrailing) { if !requiresSignIn { navigationBar } }
        .overlay(alignment: .bottom) {
            if let sendToast, !requiresSignIn {
                Text(sendToast)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.horizontal, 20)
                    .padding(.bottom, composerHeight + 16)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .task(id: sendToastRevision) {
            guard sendToast != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            sendToast = nil
        }
        .onChange(of: model.offlineSendRevision) { _, _ in showOfflineToast() }
        .onChange(of: requiresSignIn) { _, required in
            if required { composerFocused = false; sendToast = nil }
        }
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
        .onChange(of: model.imageContext) { _, _ in voicePlayer.stop() }
        .onChange(of: model.imagePageActive) { _, active in
            if !active { voicePlayer.stop() }
        }
        .onAppear { model.pageDidAppear() }
        .onDisappear { model.pageDidDisappear(); voicePlayer.stop() }
    }

    private var conversationTimeline: some View {
        let rows = model.timelineRows
        let firstVisibleID = rows.first?.message.id
        let hasHistoryHeader = model.state.before != nil || model.state.historySyncFailed
        func edgePadding(for id: String) -> (top: CGFloat, bottom: CGFloat) {
            let top = id == firstVisibleID ? timelineEdgeFade + (hasHistoryHeader ? 0 : navigationOverlayHeight) : 0
            return (top, 0)
        }
        let messages = (rows + [.bottomSpace(height: timelineEdgeFade + composerHeight)]).map { row in
            let padding = edgePadding(for: row.message.id)
            return row.message(topPadding: padding.top, bottomPadding: padding.bottom)
        }
        return ExyteChat.ChatView(messages: messages, didSendMessage: { _ in }) { params in
            if let row = params.message.customData["etosRow"] as? CFLTimelineRow {
                timelineRow(row)
                    .padding(.horizontal, 8)
                    .padding(.top, params.message.customData["etosTopPadding"] as? CGFloat ?? 0)
                    .padding(.bottom, params.message.customData["etosBottomPadding"] as? CGFloat ?? 0)
            }
        } inputViewBuilder: { _ in
            EmptyView()
        }
        .showScrollToBottomButton(false)
        .onContentOffsetChange { offset in
            let visible = offset > 0
            if showScrollToBottom != visible { showScrollToBottom = visible }
        }
        .showDateHeaders(false)
        .updateTransaction(Binding(get: { model.timelineTransaction }, set: { model.timelineTransaction = $0 }))
        .showMessageMenuOnLongPress(false)
        .keyboardDismissMode(.onDrag)
        .scrollTo(timelineScroll)
        .mainHeaderBuilder {
            CFLHistoryHeader(model: model, topPadding: navigationOverlayHeight + timelineEdgeFade)
        }
        .chatTheme(colors: .init(mainBG: .clear))
        .mask {
            GeometryReader { geometry in
                let edge = min(timelineEdgeFade / max(geometry.size.height, 1), 0.5)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: edge),
                    .init(color: .black, location: 1 - edge),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .background(CFLChatTableFocusBridge(focus: $composerFocused))
        .overlay(alignment: .bottom) {
            composer.onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                if height > 0 { composerHeight = height }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showScrollToBottom {
                ChatScrollNavigationButton(systemName: "chevron.down",
                    accessibilityLabel: NSLocalizedString("滚动到底部", comment: "Scroll to bottom"),
                    isEnabled: true, usesLiquidGlass: config.enableLiquidGlass, circleSize: 44) {
                    scrollTimelineToBottom()
                }
                .padding(.trailing, 16)
                .padding(.bottom, composerHeight + 8)
            }
        }
        .overlay {
            if model.state.messages.isEmpty && model.state.localDrafts.isEmpty && model.state.pending.isEmpty && model.state.connection == .online && model.state.activeTurnId == nil {
                Text(NSLocalizedString("还没有消息。", comment: "CFL empty chat"))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.state.sessionId) { _, session in
            if session != nil { scrollTimelineToBottom() }
        }
        .onChange(of: scrollToBottomRevision) { _, _ in scrollTimelineToBottom() }
    }

    @ViewBuilder
    private func timelineRow(_ row: CFLTimelineRow) -> some View {
        switch row {
        case .message(let message):
            VStack(spacing: 0) {
                if message.isReminder {
                    CFLReminderBubble(text: message.text)
                    if !message.images.isEmpty {
                        CFLMessageImages(images: message.images, outgoing: false, model: model,
                                         target: message.id.target, session: message.id.session,
                                         revision: message.sessionRevision, clientID: message.clientID)
                    }
                } else {
                    CFLNativeMessageBubble(item: message, model: model, voicePlayer: voicePlayer)
                }
            }
        case .pending(let pending):
            pendingRow(pending)
        case .otherTarget(let pending):
            otherTargetRow(pending)
        case .bottomSpace(let height):
            Color.clear.frame(height: height).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private func scrollTimelineToBottom() {
        timelineScroll = nil
        DispatchQueue.main.async { timelineScroll = ScrollToParams(.newestMessage) }
    }

    private var navigationBar: some View {
        let iconSize: CGFloat = 48
        let tintOpacity = LiquidGlassTintSetting.normalized(config.liquidGlassTintOpacity)
        let tint = colorScheme == .dark ? Color.black.opacity(tintOpacity) : Color.white.opacity(tintOpacity)
        return Button(action: openSettings) {
            ChatNavigationIconSurface(
                content: Image(systemName: "gearshape").etFont(.system(size: 17, weight: .semibold))
                    .foregroundColor(TelegramColors.navBarText).frame(width: iconSize, height: iconSize),
                usesLiquidGlass: config.enableLiquidGlass, tint: tint,
                strokeColor: Color.white.opacity(0.2), lineWidth: 0.5
            )
        }.buttonStyle(.plain).disabled(model.busy)
            .accessibilityLabel(NSLocalizedString("设置", comment: "Settings"))
            .padding(.trailing, 16).padding(.top, 8)
    }

    private var signInView: some View {
        VStack(spacing: 12) {
            Button { Task { await model.signIn() } } label: {
                Label(NSLocalizedString("CFL使用Passkey登录", comment: "CFL Passkey sign in"), systemImage: "person.badge.key.fill")
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSignIn)
            if let error = model.signInError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if config.cflHTTPSOrigin.isEmpty {
                    Text(NSLocalizedString("请先设置连接地址。", comment: "CFL setup"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.uncertain != nil {
                    Button(NSLocalizedString("检查状态", comment: "CFL reconcile")) { Task { await model.refresh() } }.font(.caption)
                        .disabled(model.state.connection != .online || model.busy)
                }
            }
            if let notice = model.notice ?? model.stateError { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if !model.imagesBelongToCurrentSession {
                Text(NSLocalizedString("图片属于之前的会话，请切回或移除图片。", comment: "Image draft session"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }

    private func showOfflineToast() {
        let reason = NSLocalizedString("连接已断开，请等待重新连接。", comment: "CFL offline")
        sendToast = String(format: NSLocalizedString("发送失败：%@", comment: "Send failed"), reason)
        sendToastRevision &+= 1
    }

    private var composer: some View {
        TelegramMessageComposer(
            text: text,
            sendAction: {
                guard model.state.connection == .online else {
                    showOfflineToast()
                    return false
                }
                let captured = draft.text
                let capturedRevision = model.draftRevision
                scrollToBottomRevision += 1
                Task {
                    if await model.send(captured, draftRevision: capturedRevision) {
                        if model.draftRevision == capturedRevision && draft.text == captured { config.chatComposerDraft = "" }
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
                canSend: !model.busy && !model.needsSignIn && !model.isPreparingImages && model.uncertain == nil
                    && (draft.hasSendableText || !model.selectedImages.isEmpty)
                    && (model.state.connection != .online || model.imagesBelongToCurrentSession),
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

    private func pendingRow(_ item: CFLPending, showsContent: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsContent { Text(item.text).textSelection(.enabled) }
            if showsContent, let images = item.images, !images.isEmpty {
                Text(String(format: NSLocalizedString("包含 %d 张图片", comment: "Pending images"), images.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.sessionId != model.state.sessionId {
                Text(NSLocalizedString("属于其他会话", comment: "CFL other session")).font(.caption).foregroundStyle(.secondary)
            }
            if item.status == .failed || (item.status == .unknown && !item.dispatched) {
                if item.status == .failed && item.dispatched && item.sessionId == model.state.sessionId {
                    Button(NSLocalizedString("重试", comment: "Retry")) { Task { await model.retry(item) } }
                        .font(.caption).disabled(model.busy || model.uncertain != nil || model.state.connection != .online)
                }
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

}
#endif
