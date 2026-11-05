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
        if (pending.status == .failed && pending.dispatched) || (!pending.dispatched && model.canRetryLocalSend(pending.operationId)) {
            Button { Task { await model.retry(pending) } } label: {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22)).foregroundStyle(.red)
                    .frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(NSLocalizedString("重试", comment: "Retry")))
            .disabled(model.retryIsBusy || model.uncertain != nil || model.state.connection != .online)
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
        if (pending.status == .failed && pending.dispatched) || (!pending.dispatched && model.canRetryLocalSend(pending.operationId)) {
            Button(NSLocalizedString("重试", comment: "Retry")) { Task { await model.retry(pending) } }
                .disabled(model.retryIsBusy || model.uncertain != nil || model.state.connection != .online)
        }
        if !pending.dispatched {
            Button(NSLocalizedString("恢复到输入框", comment: "Recover unsent input")) {
                let config = AppConfigStore.shared
                guard config.chatComposerDraft.isEmpty && model.selectedImages.isEmpty else {
                    model.notice = NSLocalizedString("输入框已有文字，请先处理。", comment: "CFL draft occupied")
                    return
                }
                if model.hasLocalSend(pending.operationId) { model.restoreLocalSend(pending.operationId) }
                else if pending.images?.isEmpty == false { Task { _ = await model.restoreImages(from: pending) } }
                else { config.chatComposerDraft = pending.text }
            }.disabled(model.busy)
        }
        Button(NSLocalizedString("移除", comment: "Remove"), role: .destructive) {
            Task { await model.dismiss(pending) }
        }.disabled(model.busy)
    }
}

/// Adapts a server-owned display row to ETOS's existing bubble presentation.
/// The UUID belongs only to this view state; CFL identities remain unchanged.
private struct CFLNativeMessageBubble: View {
    private let model: CFLConversationModel
    @ObservedObject private var rowState: CFLBubbleState
    @ObservedObject var voicePlayer: CFLVoicePlayer
    @ObservedObject private var config = AppConfigStore.shared
    @ObservedObject private var background = ChatBackgroundModel.shared
    @StateObject private var renderState: ChatMessageRenderState
    @StateObject private var markdownImageStatus = CFLMarkdownImageStatus()
    @State private var showActions = false

    private var item: CFLDisplayMessage { rowState.item }

    private var failedPending: CFLPending? {
        guard let pending = item.pending, CFLPendingPresentation.needsAction(pending, busy: model.isSendingLocally(pending.operationId)) else { return nil }
        return pending
    }

    private var imageStoreContext: CFLMarkdownImageStore.Context {
        .init(target: item.id.target, session: item.id.session, revision: item.sessionRevision,
              clientID: item.clientID)
    }

    init(item: CFLDisplayMessage, model: CFLConversationModel, voicePlayer: CFLVoicePlayer) {
        self.model = model
        _rowState = ObservedObject(wrappedValue: model.bubbleState(for: item))
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
                    enableAdvancedRenderer: config.enableAdvancedRenderer,
                    enableMathRendering: config.enableAdvancedRenderer,
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
                                 failedPending: failedPending, showFailureIndicator: item.text.isEmpty,
                                 canFavorite: item.pending == nil)
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
    @State private var showsStickerPanel = false
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
            if required { composerFocused = false; showsStickerPanel = false; sendToast = nil }
        }
        .onChange(of: composerFocused) { _, focused in
            if focused { showsStickerPanel = false }
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
        .onChange(of: model.imageContext) { _, _ in voicePlayer.stop(); showsStickerPanel = false }
        .onChange(of: model.imagePageActive) { _, active in
            if !active { voicePlayer.stop() }
        }
        .onAppear { model.pageDidAppear() }
        .onDisappear { model.pageDidDisappear(); voicePlayer.stop() }
    }

    private var conversationTimeline: some View {
        CFLTimelineView(model: model, timelineScroll: $timelineScroll, showScrollToBottom: $showScrollToBottom,
                        composerHeight: $composerHeight, composerFocused: $composerFocused,
                        showsStickerPanel: $showsStickerPanel, scrollToBottomRevision: $scrollToBottomRevision,
                        timelineEdgeFade: timelineEdgeFade, navigationOverlayHeight: navigationOverlayHeight,
                        rowContent: { row in timelineRow(row) }, composer: composer)
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

    private var navigationBar: some View {
        let iconSize: CGFloat = 48
        return ChatCircleActionButton(systemName: "gearshape",
            accessibilityLabel: NSLocalizedString("设置", comment: "Settings"),
            isEnabled: !model.busy, circleSize: iconSize, symbolSize: 17,
            iconColor: TelegramColors.navBarText, action: openSettings)
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
                        .disabled(model.state.connection != .online || model.retryIsBusy)
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
                let accepted = model.sendImmediately(captured) { config.chatComposerDraft = "" }
                if accepted { scrollToBottomRevision += 1 }
                return accepted
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
            removeImage: { model.removeImage($0) },
            showsStickerPanel: showsStickerPanel,
            toggleStickers: {
                if showsStickerPanel {
                    showsStickerPanel = false
                    composerFocused = true
                } else {
                    guard model.imageContext != nil else {
                        model.notice = NSLocalizedString("暂时无法打开表情，请检查连接。", comment: "Sticker panel unavailable")
                        return
                    }
                    composerFocused = false
                    showsStickerPanel = true
                }
            }
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
