#if os(iOS)
import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
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
    private enum LocalSendPhase: Equatable { case queued, sending, awaiting, failed, uncertain }
    private struct LocalSend {
        let context: CFLImageContext
        let origin: String
        var operation: String
        let text: String
        let images: [CFLSelectedImage]
        let createdAt: Date
        let anchor: PendingAnchor
        var phase: LocalSendPhase

        var draft: CFLLocalDraft {
            CFLLocalDraft(sessionId: context.session, operationId: operation, text: text,
                images: images.enumerated().map { index, image in
                    CFLLocalImagePreview(sessionId: context.session, operationId: operation,
                        originOperationId: origin, draftId: image.prepared.id, order: index,
                        attachmentId: nil, data: image.prepared.preview)
                })
        }
    }
    private typealias LocalProjection = CFLTimelineProjection.LocalProjection
    private var localSends: [LocalSend] = []
    private var sendQueueTask: Task<Void, Never>?
    @Published private(set) var sendQueueActive = false
    private var displayOrigins: [String: String] = [:]
    private var bubbleStates: [CFLDisplayMessage.ID: CFLBubbleState] = [:]

    func bubbleState(for item: CFLDisplayMessage) -> CFLBubbleState {
        if let existing = bubbleStates[item.id] { return existing }
        let result = CFLBubbleState(item)
        bubbleStates[item.id] = result
        return result
    }

    private func updateBubbleStates(_ items: [CFLDisplayMessage]) {
        let ids = Set(items.map(\.id))
        bubbleStates = bubbleStates.filter { ids.contains($0.key) }
        for item in items { bubbleState(for: item).update(item) }
    }
    private typealias PendingAnchor = CFLTimelineProjection.PendingAnchor
    private var pendingAnchors: [String: PendingAnchor] = [:]
    private var nextSendAnchor: PendingAnchor?
    @Published var state = CFLChatState() {
        didSet {
            CFLTimelineDiagnostics.event("state", "messages=\(state.messages.count) pending=\(state.pending.count) drafts=\(state.localDrafts.count) revision=\(state.sessionRevision) sessionChanged=\(oldValue.sessionId != state.sessionId ? 1 : 0) active=\(state.activeTurnId != nil ? 1 : 0) online=\(state.connection == .online ? 1 : 0)")
            if oldValue.sessionId != state.sessionId || oldValue.sessionRevision != state.sessionRevision {
                cancelImageSelection()
                pendingAnchors.removeAll()
                nextSendAnchor = nil
                if uncertain?.sessionId != state.sessionId { uncertain = nil }
                if uncertain == nil, let item = localSends.first(where: {
                    $0.phase == .uncertain && $0.context.target == connectedOrigin && $0.context.session == state.sessionId
                }) {
                    uncertain = CFLPending(target: item.context.target, sessionId: item.context.session, operationId: item.operation,
                        text: item.text, createdAt: item.createdAt, dispatched: false, status: .unknown)
                }
            }
            if let session = state.sessionId {
                for item in localSends where item.context.target == connectedOrigin && item.context.session == session {
                    pendingAnchors[item.operation] = item.anchor
                }
                let previous = Set(oldValue.localDrafts.map(\.operationId) + oldValue.pending.filter { $0.sessionId == session }.map(\.operationId))
                let incoming = state.localDrafts.filter { $0.sessionId == session }.map { ($0.operationId, Optional<String>.none) } +
                    state.pending.filter { $0.sessionId == session }.map { ($0.operationId, $0.retrySource) }
                for (operation, source) in incoming {
                    if let source { displayOrigins[operation] = displayOrigins[source] ?? source }
                }
                for (operation, source) in incoming where !previous.contains(operation) && pendingAnchors[operation] == nil {
                    if let source, let anchor = pendingAnchors[source] {
                        pendingAnchors[operation] = anchor
                    } else {
                        pendingAnchors[operation] = nextSendAnchor?.session == session
                            ? nextSendAnchor : PendingAnchor(session: session, after: oldValue.messages.last?.id)
                        if nextSendAnchor?.session == session { nextSendAnchor = nil }
                    }
                }
                let active = Set(incoming.flatMap { [$0.0, $0.1].compactMap { $0 } } + localSends.filter { $0.context.session == session }.map(\.operation))
                pendingAnchors = pendingAnchors.filter { $0.value.session == session && active.contains($0.key) }
            }
            scheduleProjection()
        }
    }

    private func scheduleProjection() {
            // Once the server row and its local previews are available, the
            // original upload bytes no longer need to remain in the UI queue.
            localSends.removeAll { item in
                guard item.phase == .awaiting,
                      let message = state.messages.first(where: { $0.operationId == item.operation }),
                      item.context.target == connectedOrigin, item.context.session == state.sessionId else { return false }
                if item.images.isEmpty { return true }
                let refs = message.images ?? []
                return refs.count == item.images.count && refs.allSatisfy { ref in
                    state.localPreviews.contains { $0.operationId == item.operation && $0.attachmentId == ref.attachmentId }
                }
            }
            let locals = localSends.filter { $0.context.target == connectedOrigin && $0.context.session == state.sessionId }.map { item in
                let pending = state.pending.first { $0.operationId == item.operation && $0.sessionId == item.context.session }
                    ?? (item.phase == .failed ? CFLPending(target: item.context.target, sessionId: item.context.session,
                        operationId: item.operation, text: item.text, createdAt: item.createdAt, dispatched: false, status: .failed) : nil)
                return LocalProjection(origin: item.origin, draft: item.draft, pending: pending,
                                       sending: item.phase == .queued || item.phase == .sending || item.phase == .uncertain)
            }
            let input = ProjectionInput(target: connectedOrigin, session: state.sessionId, revision: state.sessionRevision, clientID: clientID, messages: state.messages,
                                        reply: state.connection == .online ? state.streamingReply : nil,
                                        historyGaps: state.historyGaps,
                                        drafts: state.localDrafts, previews: state.localPreviews, pending: state.pending,
                                        otherTargetPending: state.otherTargetPending,
                                        anchors: pendingAnchors, locals: locals, origins: displayOrigins)
            releaseUnusedPreviews()
            guard input != latestProjection else { return }
            CFLTimelineDiagnostics.event("projection-enqueue", "messages=\(input.messages.count) reply=\(input.reply != nil ? 1 : 0) inFlight=\(projectionTask != nil ? 1 : 0)")
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
    private typealias ProjectionInput = CFLTimelineProjection.ProjectionInput
    private typealias ReplyCache = CFLTimelineProjection.ReplyCache
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
                CFLTimelineProjection.project(input, cache: cache)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.replyCache = result.cache
            if self.latestProjection == input {
                self.updateBubbleStates(result.messages + result.reply)
                self.visibleMessages = result.messages
                self.visibleReply = result.reply
                var rows = (result.messages + result.reply).map(CFLTimelineRow.message)
                for gap in input.historyGaps {
                    guard let boundary = input.messages.firstIndex(where: { $0.id == gap.beforeId }) else { continue }
                    let newerSources = Set(input.messages.dropFirst(boundary).map(\.id))
                    let firstReplyIndex = result.reply.first.flatMap { first in
                        rows.firstIndex { row in
                            if case .message(let item) = row { return item.id == first.id }
                            return false
                        }
                    }
                    let index = rows.firstIndex(where: { row in
                        if case .message(let item) = row, let source = item.sourceID { return newerSources.contains(source) }
                        return false
                    }) ?? firstReplyIndex ?? rows.count
                    let marker = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "gap:\(gap.id.uuidString)", offset: 0),
                        text: "", outgoing: false, markdown: false, images: [], sessionRevision: input.revision,
                        clientID: input.clientID, historyGap: gap)
                    rows.insert(.message(marker), at: index)
                }
                rows += input.pending.filter { $0.sessionId != input.session && CFLPendingPresentation.needsAction($0, busy: false) }.map(CFLTimelineRow.pending)
                rows += input.otherTargetPending.filter { CFLPendingPresentation.needsAction($0, busy: false) }.map(CFLTimelineRow.otherTarget)
                CFLTimelineDiagnostics.rows("projection-result", old: self.timelineRows, new: rows)
                if self.timelineRows.map(\.message) != rows.map(\.message) { self.timelineRows = rows }
            } else {
                CFLTimelineDiagnostics.event("projection-superseded")
            }
            self.projectionTask = nil
            self.startProjectionIfNeeded()
        }
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
    @Published private(set) var stickerFavoritesRevision = 0
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

    /// Inject an already-connected client for isolated conversation tests.
    convenience init(client: CFLChatClient, target: String, initialState: CFLChatState,
                     initialImages: [CFLSelectedImage] = [], draftChanges: AnyPublisher<String, Never>? = nil) {
        self.init(draftChanges: draftChanges)
        self.client = client
        self.connectedOrigin = target
        self.state = initialState
        self.selectedImages = initialImages
        if !initialImages.isEmpty, let session = initialState.sessionId { self.imageDraftOwner = (target, session) }
        observation = Task { [weak self] in
            for await state in await client.states() {
                guard !Task.isCancelled else { break }
                self?.state = state
            }
        }
    }

    deinit {
        observation?.cancel()
        projectionTask?.cancel()
        sendQueueTask?.cancel()
        selectionTask?.cancel()
        if let client { Task { await client.disconnect() } }
    }

    var stateError: String? { state.error.map { message(for: $0) } }
    var canSignIn: Bool { connectedOrigin != nil && !busy }

    var imageContext: CFLImageContext? {
        guard let target = connectedOrigin, let session = state.sessionId else { return nil }
        return CFLImageContext(clientID: clientID, target: target, session: session, revision: state.sessionRevision)
    }

    func stickerClient(for context: CFLImageContext) -> CFLChatClient? {
        guard imagePageActive, imageContext == context, state.connection == .online, !needsSignIn else { return nil }
        return client
    }

    func cachedStickerClient(for context: CFLImageContext) -> CFLChatClient? {
        guard imagePageActive, imageContext == context, state.connection != .accessDenied, !needsSignIn else { return nil }
        return client
    }

    func favoriteChatImage(_ image: CFLImageRef, context: CFLImageContext) async {
        guard let client = stickerClient(for: context) else {
            if imageContext == context { notice = NSLocalizedString("暂时无法收藏，请检查连接。", comment: "Favorite unavailable") }
            return
        }
        do {
            _ = try await client.favoriteChatImage(image, session: context.session, revision: context.revision)
            guard imageContext == context else { return }
            stickerFavoritesRevision &+= 1
        } catch {
            guard imageContext == context else { return }
            stickerFavoritesRevision &+= 1
            recordAuthorizationFailure(error)
            notice = NSLocalizedString("收藏未确认，请检查收藏列表。", comment: "Favorite outcome unknown")
        }
    }

    func sendSticker(_ sticker: CFLSticker, context: CFLImageContext) async -> Bool {
        guard let client = stickerClient(for: context), !busy, sendQueueTask == nil, uncertain == nil, !isPreparingImages else {
            notice = NSLocalizedString("暂时无法发送表情，请稍后再试。", comment: "Sticker send unavailable")
            return false
        }
        capturePendingAnchor(session: context.session)
        busy = true
        defer { busy = false }
        do {
            _ = try await client.sendSticker(sticker, expectedSessionId: context.session, expectedSessionRevision: context.revision)
            return imageContext == context
        } catch let error as CFLPendingStorageUncertain {
            nextSendAnchor = nil
            uncertain = error.pending
            uncertainImageIDs = []
            uncertainDraftRevision = nil
            notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
        } catch {
            nextSendAnchor = nil
            guard imageContext == context else { return false }
            recordAuthorizationFailure(error)
            notice = NSLocalizedString("表情发送失败，请稍后再试。", comment: "Sticker send failed")
        }
        return false
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
        for state in bubbleStates.values { state.invalidate() }
    }

    func pageDidAppear() {
        imagePageActive = true
        for state in bubbleStates.values { state.invalidate() }
    }

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

    func externalImage(_ source: String, target: String?, session: String?, revision: Int, clientID: UUID) async throws -> Data {
        guard imagePageActive, let context = imageContext,
              isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID),
              let client else { throw CFLFailure.sessionChanged }
        let pageRevision = imagePageRevision
        let data = try await client.externalImage(source, expectedSessionId: context.session, expectedSessionRevision: context.revision)
        guard !Task.isCancelled, imagePageActive, imagePageRevision == pageRevision, imageContext == context else { throw CFLFailure.sessionChanged }
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
                                 imageHTTP: CFLAuthorizedHTTP(authorization: authorization),
                                 mediaCache: CFLMediaDiskCache.shared, transport: {
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

    /// Accept and display one operation synchronously; persistence happens later.
    func sendImmediately(_ text: String, clearDraft: () -> Void) -> Bool {
        CFLTimelineDiagnostics.event("send-request")
        guard client != nil, !busy, !needsSignIn, uncertain == nil, !isPreparingImages,
              state.connection == .online, imagesBelongToCurrentSession, let context = imageContext else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !selectedImages.isEmpty), trimmed != "/compact", text.utf16.count <= 16000 else { return false }
        let operation = UUID().uuidString.lowercased()
        let predecessor = localSends.last(where: { $0.context.target == context.target && $0.context.session == context.session })?.operation
            ?? state.pending.last(where: { $0.sessionId == context.session })?.operationId
        let anchor = PendingAnchor(session: context.session, after: state.messages.last?.id, predecessor: predecessor)
        pendingAnchors[operation] = anchor
        let item = LocalSend(context: context, origin: operation, operation: operation, text: text,
                             images: selectedImages, createdAt: Date(), anchor: anchor, phase: .queued)
        localSends.append(item)
        displayOrigins[operation] = operation
        selectedImages = []
        imageDraftOwner = nil
        clearDraft()
        notice = nil
        let row = CFLDisplayMessage(id: .init(target: context.target, session: context.session, message: "local:\(operation)", offset: 0),
            text: text, outgoing: true, markdown: false, images: [], sessionRevision: context.revision,
            clientID: context.clientID, previews: item.draft.images, sendingLocally: true)
        _ = bubbleState(for: row)
        visibleMessages.append(row)
        let replyIDs = Set(visibleReply.map(\.id))
        let position = timelineRows.firstIndex { row in
            if case .message(let item) = row { return replyIDs.contains(item.id) }
            return true
        } ?? timelineRows.count
        timelineRows.insert(.message(row), at: position)
        scheduleProjection()
        startSendQueue()
        return true
    }

    func isSendingLocally(_ operation: String) -> Bool {
        guard let item = localSends.first(where: { $0.operation == operation }) else { return busy }
        return item.phase == .queued || item.phase == .sending || item.phase == .uncertain
    }

    var retryIsBusy: Bool { busy || sendQueueActive }

    func hasLocalSend(_ operation: String) -> Bool {
        localSends.contains { $0.operation == operation }
    }

    func canRetryLocalSend(_ operation: String) -> Bool {
        localSends.contains { $0.operation == operation && $0.phase == .failed }
    }

    func restoreLocalSend(_ operation: String) {
        guard let item = localSends.first(where: { $0.operation == operation && $0.phase == .failed }),
              let context = imageContext, context.target == item.context.target, context.session == item.context.session,
              AppConfigStore.shared.chatComposerDraft.isEmpty, selectedImages.isEmpty else { return }
        AppConfigStore.shared.chatComposerDraft = item.text
        selectedImages = item.images
        if !item.images.isEmpty { imageDraftOwner = (context.target, context.session) }
    }

    private func startSendQueue() {
        guard sendQueueTask == nil else { return }
        sendQueueActive = true
        sendQueueTask = Task { [weak self] in
            guard let self else { return }
            await self.drainSendQueue()
        }
    }

    private func drainSendQueue() async {
        defer { sendQueueTask = nil; sendQueueActive = false }
        while let index = localSends.firstIndex(where: { $0.phase == .queued }) {
            let item = localSends[index]
            guard let client, imageContext == item.context, state.connection == .online, !needsSignIn else {
                localSends[index].phase = .failed
                scheduleProjection()
                continue
            }
            localSends[index].phase = .sending
            scheduleProjection()
            do {
                let outcome = try await client.send(item.text, images: item.images.map(\.prepared), operationId: item.operation,
                    expectedSessionId: item.context.session, expectedSessionRevision: item.context.revision)
                guard let current = localSends.firstIndex(where: { $0.operation == item.operation }) else { continue }
                if outcome == .notDispatched {
                    let latest = await client.currentState()
                    guard let current = localSends.firstIndex(where: { $0.operation == item.operation }) else { continue }
                    if let pending = latest.pending.first(where: { $0.operationId == item.operation && $0.sessionId == item.context.session }), !pending.dispatched {
                        localSends[current].phase = .failed
                    } else {
                        localSends[current].phase = .uncertain
                        if imageContext == item.context {
                            uncertain = CFLPending(target: item.context.target, sessionId: item.context.session, operationId: item.operation,
                                text: item.text, createdAt: item.createdAt, dispatched: false, status: .unknown)
                            notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
                        }
                    }
                } else {
                    localSends[current].phase = .awaiting
                }
            } catch let error as CFLPendingStorageUncertain {
                if let current = localSends.firstIndex(where: { $0.operation == item.operation }) { localSends[current].phase = .uncertain }
                if imageContext == item.context {
                    uncertain = error.pending
                    notice = NSLocalizedString("无法确认内容是否已保存在本机。请先检查保存状态。", comment: "CFL uncertain storage")
                }
            } catch CFLSendFailure.duplicateOperationId {
                if let current = localSends.firstIndex(where: { $0.operation == item.operation }) { localSends[current].phase = .awaiting }
            } catch {
                if let current = localSends.firstIndex(where: { $0.operation == item.operation }) { localSends[current].phase = .failed }
                if imageContext == item.context { recordAuthorizationFailure(error) }
            }
            scheduleProjection()
        }
    }

    func capturePendingAnchor(session: String) {
        nextSendAnchor = PendingAnchor(session: session, after: state.messages.last?.id,
                                       predecessor: state.pending.last(where: { $0.sessionId == session })?.operationId)
    }

    func refresh() async {
        guard let client, !retryIsBusy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.reconcile()
            if let uncertain {
                let current = await client.currentState()
                if let index = localSends.firstIndex(where: { $0.operation == uncertain.operationId }) {
                    let pending = current.pending.first { $0.operationId == uncertain.operationId && $0.sessionId == uncertain.sessionId }
                    localSends[index].phase = pending?.dispatched == true ? .awaiting : .failed
                }
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
                scheduleProjection()
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

    func fillHistoryGap(_ id: UUID) async {
        guard let client else { return }
        await client.fillGap(id: id)
    }

    func retry(_ pending: CFLPending) async {
        guard let client, !retryIsBusy, uncertain == nil, pending.sessionId == state.sessionId else { return }
        busy = true
        defer { busy = false }
        do {
            if let index = localSends.firstIndex(where: { $0.operation == pending.operationId && $0.phase == .failed }), !pending.dispatched,
               let context = imageContext, context.target == localSends[index].context.target,
               context.session == localSends[index].context.session, state.connection == .online {
                let item = localSends[index]
                let latest = await client.currentState()
                guard imageContext == context else { return }
                if let saved = latest.pending.first(where: { $0.operationId == item.operation && $0.sessionId == context.session }) {
                    guard !saved.dispatched, saved.status != .submitted else { return }
                    try await client.dismissPending(sessionId: context.session, operationId: item.operation)
                    let afterDismissal = await client.currentState()
                    guard imageContext == context, afterDismissal.sessionId == context.session,
                          afterDismissal.sessionRevision == context.revision else { return }
                    state = afterDismissal
                }
                guard imageContext == context, let current = localSends.firstIndex(where: { $0.operation == item.operation }) else { return }
                let attempt = UUID().uuidString.lowercased()
                localSends[current] = LocalSend(context: context, origin: item.origin, operation: attempt,
                    text: item.text, images: item.images, createdAt: item.createdAt, anchor: item.anchor, phase: .queued)
                pendingAnchors[attempt] = pendingAnchors.removeValue(forKey: item.operation)
                displayOrigins[attempt] = item.origin
                scheduleProjection()
                startSendQueue()
            } else {
                let origin = localSends.first(where: { $0.operation == pending.operationId })?.origin ?? pending.operationId
                let attempt = try await client.retryFailed(sessionId: pending.sessionId, operationId: pending.operationId,
                                                            expectedSessionRevision: state.sessionRevision)
                displayOrigins[attempt] = origin
                localSends.removeAll { $0.operation == pending.operationId }
                scheduleProjection()
            }
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
        do {
            let latest = await client.currentState()
            if let saved = latest.pending.first(where: { $0.operationId == pending.operationId && $0.sessionId == pending.sessionId }) {
                guard saved.status == .failed || (saved.status == .unknown && !saved.dispatched) else { return }
                try await client.dismissPending(sessionId: pending.sessionId, operationId: pending.operationId)
            } else {
                guard localSends.contains(where: { $0.operation == pending.operationId && $0.phase == .failed }) else { return }
            }
            localSends.removeAll { $0.operation == pending.operationId }
            scheduleProjection()
        }
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

#endif
