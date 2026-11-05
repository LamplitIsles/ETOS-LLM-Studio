#if os(iOS)
import SwiftUI
import Combine
import CryptoKit
import ETOSCore
import ExyteChat

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
            let imageInfo = item.images.filter { image in
                !item.previews.contains { $0.attachmentId == image.attachmentId }
            }.map { "image:" + Self.encoded($0) }
            let previews = item.previews.map {
                "preview:" + Self.key([$0.sessionId, $0.originOperationId, $0.draftId,
                                       String($0.order), String($0.data.count)])
            }
            signature = [text, String(item.markdown), String(item.sessionRevision), item.clientID.uuidString,
                         String(item.markdownSourcesRevision), String(item.isReminder), item.voice?.id ?? "",
                         item.imageState?.rawValue ?? "", item.historyGap?.status.rawValue ?? "", item.pending.flatMap {
                             CFLPendingPresentation.needsAction($0, busy: item.sendingLocally) ? Self.encoded($0) : nil
                         } ?? ""] + imageInfo + previews + item.files.map { "file:" + Self.key([$0.name, String($0.size), $0.ref.map(Self.encoded) ?? ""]) }
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


/// A cell observes only changes to its own content or actionable metadata.
@MainActor
final class CFLBubbleState: ObservableObject {
    private(set) var item: CFLDisplayMessage
    init(_ item: CFLDisplayMessage) { self.item = item }

    func update(_ next: CFLDisplayMessage) {
        let changed = CFLTimelineRow.message(item).message != CFLTimelineRow.message(next).message
            || item.images != next.images || item.previews != next.previews || item.files != next.files
            || (!next.images.isEmpty && (item.pending == nil) != (next.pending == nil))
        if changed {
            CFLTimelineDiagnostics.event("bubble-update", "row=\(CFLTimelineDiagnostics.token(.message(next)))")
            objectWillChange.send()
        }
        item = next
    }

    func invalidate() { objectWillChange.send() }
}

/// Serializes visible list changes through Exyte without coupling the conversation model to its transaction.
@MainActor
final class CFLTimelineAdapter: ObservableObject {
    @Published private(set) var rows: [CFLTimelineRow] = []
    var transaction: TableUpdateTransaction?
    private var pending: [CFLTimelineRow]?
    private var task: Task<Void, Never>?
    private var revision = 0

    func offer(_ next: [CFLTimelineRow]) {
        CFLTimelineDiagnostics.rows("adapter-offer", old: rows, new: next)
        revision &+= 1
        pending = next
        guard task == nil else { return }
        guard transaction != nil else {
            pending = nil
            if rows.map(\.message) != next.map(\.message) { rows = next }
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            while let next = self.pending {
                self.pending = nil
                guard self.rows.map(\.message) != next.map(\.message) else {
                    CFLTimelineDiagnostics.event("adapter-unchanged")
                    continue
                }
                let revision = self.revision
                if let transaction = self.transaction {
                    CFLTimelineDiagnostics.event("transaction-start", "revision=\(revision) rows=\(next.count)")
                    await transaction(animationMode: .natural) {
                        if self.revision == revision {
                            CFLTimelineDiagnostics.event("transaction-commit", "revision=\(revision)")
                            self.rows = next
                        } else {
                            CFLTimelineDiagnostics.event("transaction-superseded", "revision=\(revision)")
                        }
                    }
                    CFLTimelineDiagnostics.event("transaction-end", "revision=\(revision)")
                } else {
                    self.rows = next
                }
            }
            self.task = nil
        }
    }
}

/// At most one automatic page per visit, even if the marker moves after a page arrives.
struct CFLHistoryGapVisits {
    private var visited: Set<UUID> = []
    mutating func update(_ gap: CFLHistoryGap, visible: Bool) -> Bool {
        guard visible else { visited.remove(gap.id); return false }
        return gap.status == .pending && visited.insert(gap.id).inserted
    }
    mutating func reset() { visited.removeAll() }
    static func visible(_ frame: CGRect, in viewport: CGRect) -> Bool {
        !frame.isNull && !viewport.isNull && frame.intersects(viewport)
    }
}

struct CFLTimelineView<RowContent: View, Composer: View>: View {
    @ObservedObject var model: CFLConversationModel
    @StateObject private var adapter = CFLTimelineAdapter()
    @State private var timelineFrame: CGRect = .null
    @State private var gapVisits = CFLHistoryGapVisits()
    @Binding var timelineScroll: ScrollToParams?
    @Binding var showScrollToBottom: Bool
    @Binding var composerHeight: CGFloat
    @Binding var composerFocused: Bool
    @Binding var showsStickerPanel: Bool
    @Binding var scrollToBottomRevision: Int
    let timelineEdgeFade: CGFloat
    let navigationOverlayHeight: CGFloat
    let rowContent: (CFLTimelineRow) -> RowContent
    let composer: Composer

    var body: some View {
        let rows = adapter.rows
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
                Group {
                    if case .message(let item) = row, let gap = item.historyGap {
                        CFLHistoryGapRow(gap: gap, viewport: visibleTimelineFrame) { visible in
                            gapVisibilityChanged(gap, visible: visible)
                        } load: {
                            Task { await model.fillHistoryGap(gap.id) }
                        }
                    } else {
                        rowContent(row)
                    }
                }
                    .padding(.horizontal, 8)
                    .padding(.top, params.message.customData["etosTopPadding"] as? CGFloat ?? 0)
                    .padding(.bottom, params.message.customData["etosBottomPadding"] as? CGFloat ?? 0)
                    .background(CFLTimelineRowMarker(token: CFLTimelineDiagnostics.token(row)))
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
        .updateTransaction(Binding(get: { adapter.transaction }, set: { adapter.transaction = $0 }))
        .showMessageMenuOnLongPress(false)
        .keyboardDismissMode(.onDrag)
        .scrollTo(timelineScroll)
        .mainHeaderBuilder {
            CFLHistoryHeader(model: model, topPadding: navigationOverlayHeight + timelineEdgeFade)
        }
        .chatTheme(colors: .init(mainBG: .clear))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { timelineFrame = $0 }
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
        .background(CFLChatTableFocusBridge(focus: $composerFocused, onDismiss: { showsStickerPanel = false }))
        .background(CFLTimelineLayoutProbe())
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                composer
                if showsStickerPanel, let context = model.imageContext {
                    CFLStickerPanel(model: model, context: context) {
                        scrollToBottomRevision += 1
                    }
                    .id("\(context.clientID)|\(context.session)|\(context.revision)")
                    .frame(height: 280)
                }
            }.onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                CFLTimelineDiagnostics.event("composer-height", "old=\(composerHeight) new=\(height)")
                if height > 0 { composerHeight = height }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showScrollToBottom {
                ChatCircleActionButton(systemName: "chevron.down",
                    accessibilityLabel: NSLocalizedString("滚动到底部", comment: "Scroll to bottom"),
                    isEnabled: true, circleSize: 44) {
                    scrollTimelineToBottom()
                }
                .padding(.trailing, 16)
                .padding(.bottom, composerHeight + 8)
            }
        }
        .overlay {
            if model.visibleMessages.isEmpty && model.state.messages.isEmpty && model.state.localDrafts.isEmpty && model.state.pending.isEmpty && model.state.connection == .online && model.state.activeTurnId == nil {
                Text(NSLocalizedString("还没有消息。", comment: "CFL empty chat"))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: model.state.sessionId) { _, session in
            gapVisits.reset()
            if session != nil { scrollTimelineToBottom(reason: "session") }
        }
        .onReceive(model.$timelineRows) { adapter.offer($0) }
        .onChange(of: composerFocused) { _, focused in
            CFLTimelineDiagnostics.event("composer-focus", "focused=\(focused ? 1 : 0)")
        }
        .onChange(of: scrollToBottomRevision) { _, _ in scrollTimelineToBottom(reason: "explicit") }
    }

    private func scrollTimelineToBottom(reason: String = "button") {
        CFLTimelineDiagnostics.event("scroll-bottom-request", "reason=\(reason)")
        timelineScroll = nil
        DispatchQueue.main.async {
            CFLTimelineDiagnostics.event("scroll-bottom-apply", "reason=\(reason)")
            timelineScroll = ScrollToParams(.newestMessage)
        }
    }

    private var visibleTimelineFrame: CGRect {
        guard !timelineFrame.isNull else { return .null }
        return CGRect(x: timelineFrame.minX, y: timelineFrame.minY + navigationOverlayHeight,
                      width: timelineFrame.width,
                      height: max(0, timelineFrame.height - navigationOverlayHeight - composerHeight))
    }

    private func gapVisibilityChanged(_ gap: CFLHistoryGap, visible: Bool) {
        guard gapVisits.update(gap, visible: visible) else { return }
        Task { await model.fillHistoryGap(gap.id) }
    }

}

private struct CFLHistoryGapRow: View {
    let gap: CFLHistoryGap
    let viewport: CGRect
    let visibility: (Bool) -> Void
    let load: () -> Void
    @State private var frame: CGRect = .null

    var body: some View {
        HStack(spacing: 8) {
            switch gap.status {
            case .loading:
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("正在加载…", comment: "Loading history gap"))
            case .unavailable:
                Text(NSLocalizedString("无法继续加载这段消息。", comment: "History gap unavailable"))
            case .error:
                Text(NSLocalizedString("中间的消息加载失败。", comment: "History gap failed"))
                Button(NSLocalizedString("重试", comment: "Retry"), action: load)
            case .pending:
                Button(NSLocalizedString("加载中间的消息", comment: "Load missing history"), action: load)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { value in
            frame = value
            visibility(CFLHistoryGapVisits.visible(value, in: viewport))
        }
        .onChange(of: viewport) { _, value in
            visibility(CFLHistoryGapVisits.visible(frame, in: value))
        }
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

#endif
