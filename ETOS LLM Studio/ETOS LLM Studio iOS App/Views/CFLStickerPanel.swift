#if os(iOS)
import SwiftUI
import UIKit
import ImageIO
import ETOSCore

/// A session-scoped picker. Server pages and media are loaded only as needed.
struct CFLStickerPanel: View {
    @ObservedObject var model: CFLConversationModel
    let context: CFLImageContext
    let didSend: () -> Void

    @State private var packs: [CFLStickerPack] = []
    @State private var packsCursor: String?
    @State private var packsLoading = false
    @State private var packsToken = UUID()
    @State private var checkingPackCache = false
    @State private var packsHaveSnapshot = false
    @State private var packFirstIDs: Set<String> = []
    @State private var packFirstCursor: String?
    @State private var packsError = false
    @State private var selection = "favorites"
    @State private var query = ""
    @State private var stickers: [CFLSticker] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var checkingContentCache = false
    @State private var hasContentSnapshot = false
    @State private var displayedContentKey = ""
    @State private var firstPageIDs: Set<String> = []
    @State private var firstPageCursor: String?
    @State private var rememberedContent: [String: CFLStickerContentSnapshot] = [:]
    @State private var rememberedOrder: [String] = []
    @State private var error = false
    @State private var pageToken = UUID()
    @State private var favoriteIDs: Set<String>?
    @State private var favoritesComplete = false
    @State private var favoriteUnknownIDs: Set<String> = []
    @State private var favoritesToken = UUID()
    @State private var favoriteError = false
    @State private var changingFavorite = false
    @State private var actionError: String?
    @State private var preview: CFLStickerPreviewTarget?
    @FocusState private var searching: Bool

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var contentKey: String { "\(selection)|\(query)|\(model.stickerFavoritesRevision)|\(model.state.connection)" }
    private var client: CFLChatClient? { model.cachedStickerClient(for: context) }
    private var current: Bool { model.cachedStickerClient(for: context) != nil }
    private var selectedPackName: String? {
        guard searchText.isEmpty, selection.hasPrefix("pack:") else { return nil }
        let packID = String(selection.dropFirst("pack:".count))
        return packs.first(where: { $0.id == packID })?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("搜索表情名称或标签", comment: "Search stickers"), text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .accessibilityLabel(NSLocalizedString("搜索表情", comment: "Search stickers"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(NSLocalizedString("清除搜索", comment: "Clear search"))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tab(selected: selection == "favorites" && searchText.isEmpty,
                        label: NSLocalizedString("收藏", comment: "Favorites")) {
                        Image(systemName: "heart")
                    } action: { query = ""; searching = false; selection = "favorites" }
                    ForEach(packs) { pack in
                        tab(selected: selection == "pack:\(pack.id)" && searchText.isEmpty, label: pack.name) {
                            CFLStickerThumbnail(model: model, context: context, sticker: pack.cover)
                                .frame(width: 30, height: 30)
                        } action: { query = ""; searching = false; selection = "pack:\(pack.id)" }
                    }
                    if packsCursor != nil || packsError {
                        Button {
                            Task { await loadPacks(reset: packsError && packs.isEmpty) }
                        } label: {
                            Image(systemName: packsError ? "arrow.clockwise" : "ellipsis")
                                .frame(width: 38, height: 38)
                        }
                        .disabled(packsLoading)
                        .accessibilityLabel(NSLocalizedString("加载更多表情包", comment: "Load more sticker packs"))
                    }
                    if packsLoading && !checkingPackCache && !packsHaveSnapshot { ProgressView().frame(width: 38, height: 38) }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            if let selectedPackName {
                Text(selectedPackName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            if let actionError {
                HStack {
                    Text(actionError).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(NSLocalizedString("关闭", comment: "Dismiss")) { self.actionError = nil }.font(.caption)
                }.padding(.horizontal, 12).padding(.top, 5)
            }
            if favoriteError {
                Button(NSLocalizedString("收藏列表加载失败，点按重试", comment: "Retry favorites")) {
                    Task { await loadFavoriteIDs() }
                }.font(.caption).padding(.top, 5)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(stickers) { sticker in
                        CFLStickerCell(model: model, context: context, sticker: sticker,
                                       favorite: favoriteState(for: sticker.id),
                                       favoriteBusy: changingFavorite,
                                       preview: $preview) {
                            searching = false
                            Task { if await model.sendSticker(sticker, context: context) { didSend() } }
                        } toggleFavorite: {
                            guard let favorite = favoriteState(for: sticker.id) else { return }
                            Task { await setFavorite(sticker, favorite: !favorite) }
                        }
                    }
                }.padding(12)
                if loading {
                    if !checkingContentCache && (!hasContentSnapshot || loadingMore) { ProgressView().padding(8) }
                    else if hasContentSnapshot && stickers.isEmpty {
                        Text(NSLocalizedString("没有表情", comment: "No stickers"))
                            .font(.footnote).foregroundStyle(.secondary).padding(12)
                    }
                } else if error {
                    Button(NSLocalizedString("加载失败，点按重试", comment: "Retry stickers")) {
                        Task { await loadContent(reset: stickers.isEmpty) }
                    }.padding(8)
                } else if let _ = cursor {
                    Button(NSLocalizedString("加载更多", comment: "Load more")) {
                        Task { await loadContent(reset: false) }
                    }.padding(8)
                } else if stickers.isEmpty && !checkingContentCache && !loading {
                    Text(NSLocalizedString("没有表情", comment: "No stickers"))
                        .font(.footnote).foregroundStyle(.secondary).padding(12)
                }
            }
        }
        .background(.regularMaterial)
        .coordinateSpace(name: "CFLStickerPanel")
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let preview {
                    let panelFrame = geometry.frame(in: .global)
                    let anchorX = preview.location.point.x
                    let halfWidth = CFLStickerHeldPreview.width / 2
                    let centerX = min(max(anchorX, halfWidth + 8), max(halfWidth + 8, geometry.size.width - halfWidth - 8))
                    let top = max(8 - panelFrame.minY,
                                  preview.location.frame.minY - CFLStickerHeldPreview.height - 8)
                    CFLStickerHeldPreview(model: model, context: context, sticker: preview.sticker,
                                          tailOffset: anchorX - centerX)
                        .offset(x: centerX - halfWidth, y: top)
                        .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: query) { _, _ in changeContentSelection() }
        .onChange(of: selection) { _, _ in changeContentSelection() }
        .task(id: String(describing: model.state.connection)) { await loadPacks(reset: true) }
        .task(id: contentKey) {
            if !searchText.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await loadContent(reset: true)
        }
        .task(id: "\(model.stickerFavoritesRevision)|\(model.state.connection)") { await loadFavoriteIDs() }
    }

    private func tab<Content: View>(selected: Bool, label: String,
                                    @ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content().frame(width: 38, height: 38)
                .background(selected ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func changeContentSelection() {
        pageToken = UUID()
        if hasContentSnapshot && !displayedContentKey.isEmpty {
            rememberedContent[displayedContentKey] = CFLStickerContentSnapshot(
                stickers: stickers, cursor: cursor, firstIDs: firstPageIDs, firstCursor: firstPageCursor)
            rememberedOrder.removeAll { $0 == displayedContentKey }
            rememberedOrder.append(displayedContentKey)
            if rememberedOrder.count > 12 {
                rememberedContent.removeValue(forKey: rememberedOrder.removeFirst())
            }
        }
        let nextKey = "\(selection)|\(searchText)"
        displayedContentKey = nextKey
        if let snapshot = rememberedContent[nextKey] {
            stickers = snapshot.stickers
            cursor = snapshot.cursor
            firstPageIDs = snapshot.firstIDs
            firstPageCursor = snapshot.firstCursor
            hasContentSnapshot = true
            checkingContentCache = false
        } else {
            stickers = []
            cursor = nil
            firstPageIDs = []
            firstPageCursor = nil
            hasContentSnapshot = false
            checkingContentCache = true
        }
        loading = false
        loadingMore = false
        error = false
    }

    @MainActor private func loadPacks(reset: Bool) async {
        if !reset && packsLoading { return }
        guard let client else { packsError = true; return }
        let token = UUID()
        packsToken = token
        packsLoading = true
        defer { if packsToken == token { packsLoading = false; checkingPackCache = false } }
        if reset && !packsHaveSnapshot {
            checkingPackCache = true
            var next: String?
            var seen = Set<String>()
            do {
                repeat {
                    guard let page = try await client.cachedStickerPacks(session: context.session, revision: context.revision, cursor: next),
                          !Task.isCancelled, current, packsToken == token else { break }
                    if next == nil {
                        packs = page.packs
                        packFirstIDs = Set(page.packs.map(\.id))
                        packFirstCursor = page.nextCursor
                        packsHaveSnapshot = true
                    } else {
                        let existing = Set(packs.map(\.id))
                        packs.append(contentsOf: page.packs.filter { !existing.contains($0.id) })
                    }
                    packsCursor = page.nextCursor
                    next = page.nextCursor
                    if let next, !seen.insert(next).inserted { break }
                } while next != nil && seen.count < 32
            } catch { model.recordAuthorizationFailure(error) }
            guard !Task.isCancelled, current, packsToken == token else { return }
            checkingPackCache = false
        }
        do {
            let page = try await client.stickerPacks(session: context.session, revision: context.revision, cursor: reset ? nil : packsCursor)
            guard !Task.isCancelled, current, packsToken == token else { return }
            if reset {
                let updated = CFLStickerPanelPaging.refresh(existing: packs, firstIDs: packFirstIDs,
                    firstCursor: packFirstCursor, cursor: packsCursor, page: page.packs, nextCursor: page.nextCursor)
                packs = updated.items
                packFirstIDs = Set(page.packs.map(\.id))
                packFirstCursor = page.nextCursor
                packsCursor = updated.cursor
                packsHaveSnapshot = true
            } else {
                let existing = Set(packs.map(\.id))
                packs.append(contentsOf: page.packs.filter { !existing.contains($0.id) })
                packsCursor = page.nextCursor
            }
            packsError = false
        } catch {
            guard !Task.isCancelled, current, packsToken == token else { return }
            model.recordAuthorizationFailure(error)
            packsError = !packsHaveSnapshot
        }
    }

    private func favoriteState(for id: String) -> Bool? {
        guard !favoriteUnknownIDs.contains(id) else { return nil }
        guard let favoriteIDs else { return nil }
        if favoriteIDs.contains(id) { return true }
        return favoritesComplete ? false : nil
    }

    @MainActor private func cachedPage(_ client: CFLChatClient, selection: String, search: String,
                                        cursor: String?) async throws -> (page: CFLStickerPage, canContinue: Bool)? {
        if !search.isEmpty {
            guard let page = try await client.cachedSearchStickers(search, session: context.session, revision: context.revision, cursor: cursor) else { return nil }
            return (page, true)
        }
        if selection == "favorites" {
            guard let snapshot = try await client.cachedFavoriteSnapshot(session: context.session, revision: context.revision, cursor: cursor) else { return nil }
            return (snapshot.page, !snapshot.needsRevalidation)
        }
        guard let page = try await client.cachedStickerPackMembers(String(selection.dropFirst("pack:".count)), session: context.session, revision: context.revision, cursor: cursor) else { return nil }
        return (page, true)
    }

    @MainActor private func loadContent(reset: Bool) async {
        if !reset && loading { return }
        guard let client else { loading = false; error = true; return }
        let token = UUID()
        pageToken = token
        let selected = selection
        let search = searchText
        let selectedKey = "\(selected)|\(search)"
        if reset && displayedContentKey != selectedKey {
            displayedContentKey = selectedKey
            stickers = []
            cursor = nil
            firstPageIDs = []
            firstPageCursor = nil
            hasContentSnapshot = false
        }
        loading = true
        loadingMore = !reset
        error = false
        if reset && !hasContentSnapshot {
            checkingContentCache = true
            var cachedCursor: String?
            var seen = Set<String>()
            do {
                repeat {
                    guard let cached = try await cachedPage(client, selection: selected, search: search, cursor: cachedCursor),
                          !Task.isCancelled, current, pageToken == token else { break }
                    if cachedCursor == nil {
                        stickers = cached.page.stickers
                        firstPageIDs = Set(cached.page.stickers.map(\.id))
                        firstPageCursor = cached.page.nextCursor
                        hasContentSnapshot = true
                    } else {
                        let existing = Set(stickers.map(\.id))
                        stickers.append(contentsOf: cached.page.stickers.filter { !existing.contains($0.id) })
                    }
                    cursor = cached.canContinue ? cached.page.nextCursor : nil
                    cachedCursor = cursor
                    if let cachedCursor, !seen.insert(cachedCursor).inserted { break }
                } while cachedCursor != nil && seen.count < 32
            } catch { model.recordAuthorizationFailure(error) }
            guard !Task.isCancelled, current, pageToken == token else { return }
            checkingContentCache = false
        }
        let next = reset ? nil : cursor
        do {
            let page: CFLStickerPage
            if !search.isEmpty {
                page = try await client.searchStickers(search, session: context.session, revision: context.revision, cursor: next)
            } else if selected == "favorites" {
                page = try await client.favoriteStickers(session: context.session, revision: context.revision, cursor: next)
            } else {
                page = try await client.stickerPackMembers(String(selected.dropFirst("pack:".count)), session: context.session, revision: context.revision, cursor: next)
            }
            guard !Task.isCancelled, current, pageToken == token else { return }
            if reset {
                let updated = CFLStickerPanelPaging.refresh(existing: stickers, firstIDs: firstPageIDs,
                    firstCursor: firstPageCursor, cursor: cursor, page: page.stickers, nextCursor: page.nextCursor)
                stickers = updated.items
                firstPageIDs = Set(page.stickers.map(\.id))
                firstPageCursor = page.nextCursor
                cursor = updated.cursor
                hasContentSnapshot = true
            } else {
                let existing = Set(stickers.map(\.id))
                stickers.append(contentsOf: page.stickers.filter { !existing.contains($0.id) })
                cursor = page.nextCursor
            }
            loading = false
            loadingMore = false
        } catch {
            guard !Task.isCancelled, current, pageToken == token else { return }
            model.recordAuthorizationFailure(error)
            loading = false
            loadingMore = false
            self.error = !hasContentSnapshot || !reset
        }
    }

    @MainActor private func loadFavoriteIDs() async {
        guard let client else { favoriteError = favoriteIDs == nil; return }
        let token = UUID()
        favoritesToken = token
        favoriteError = false
        if favoriteIDs == nil {
            var cachedIDs = Set<String>()
            var cachedCursor: String?
            var seen = Set<String>()
            var foundSnapshot = false
            do {
                repeat {
                    guard let snapshot = try await client.cachedFavoriteSnapshot(session: context.session, revision: context.revision, cursor: cachedCursor),
                          !Task.isCancelled, current, favoritesToken == token else { break }
                    foundSnapshot = true
                    cachedIDs.formUnion(snapshot.page.stickers.map(\.id))
                    favoriteIDs = cachedIDs
                    if snapshot.needsRevalidation { break }
                    cachedCursor = snapshot.page.nextCursor
                    // Cached pages may come from different refreshes; only a complete
                    // current read can establish that an absent item is not a favorite.
                    if cachedCursor == nil { break }
                    if let cachedCursor, !seen.insert(cachedCursor).inserted { break }
                } while seen.count < 32
            } catch { model.recordAuthorizationFailure(error) }
            guard !Task.isCancelled, current, favoritesToken == token else { return }
            if !foundSnapshot { favoriteIDs = nil; favoritesComplete = false }
        }
        var found = Set<String>()
        var next: String?
        var seen = Set<String>()
        do {
            repeat {
                let page = try await client.favoriteStickers(session: context.session, revision: context.revision, cursor: next)
                guard !Task.isCancelled, current, favoritesToken == token else { return }
                found.formUnion(page.stickers.map(\.id))
                next = page.nextCursor
                if let next, !seen.insert(next).inserted { throw CFLFailure.protocolError }
            } while next != nil
            favoriteIDs = found
            favoritesComplete = true
            favoriteUnknownIDs.removeAll()
        } catch {
            guard !Task.isCancelled, current, favoritesToken == token else { return }
            model.recordAuthorizationFailure(error)
            favoriteError = favoriteIDs == nil
        }
    }

    @MainActor private func setFavorite(_ sticker: CFLSticker, favorite: Bool) async {
        guard !changingFavorite, let client = model.stickerClient(for: context) else { return }
        changingFavorite = true
        favoritesToken = UUID()
        defer { changingFavorite = false }
        do {
            _ = try await client.setStickerFavorite(sticker.id, favorite: favorite, session: context.session, revision: context.revision)
            guard current else { return }
            favoriteUnknownIDs.remove(sticker.id)
            if favorite { favoriteIDs?.insert(sticker.id) }
            else {
                favoriteIDs?.remove(sticker.id)
                if var snapshot = rememberedContent["favorites|"] {
                    snapshot.stickers.removeAll { $0.id == sticker.id }
                    snapshot.firstIDs.remove(sticker.id)
                    rememberedContent["favorites|"] = snapshot
                }
                if selection == "favorites" && searchText.isEmpty {
                    stickers.removeAll { $0.id == sticker.id }
                    firstPageIDs.remove(sticker.id)
                }
            }
            actionError = nil
        } catch {
            guard current else { return }
            favoriteUnknownIDs.insert(sticker.id)
            model.recordAuthorizationFailure(error)
            actionError = NSLocalizedString("收藏未确认，请检查收藏列表。", comment: "Favorite outcome unknown")
        }
        // A lost response does not authorize a repeat of the mutation.
        await loadFavoriteIDs()
        if selection == "favorites" && searchText.isEmpty { await loadContent(reset: true) }
    }
}

enum CFLStickerPanelPaging {
    static func refresh<Item: Identifiable>(existing: [Item], firstIDs: Set<Item.ID>, firstCursor: String?,
                                            cursor: String?, page: [Item], nextCursor: String?) -> (items: [Item], cursor: String?) {
        let newIDs = Set(page.map(\.id))
        let tail = nextCursor == firstCursor
            ? existing.filter { !firstIDs.contains($0.id) && !newIDs.contains($0.id) }
            : []
        return (page + tail, tail.isEmpty ? nextCursor : cursor)
    }
}

private struct CFLStickerContentSnapshot {
    var stickers: [CFLSticker]
    var cursor: String?
    var firstIDs: Set<String>
    var firstCursor: String?
}

private struct CFLStickerPreviewTarget {
    let sticker: CFLSticker
    let location: CFLStickerTouchLocation
}

private struct CFLStickerTouchLocation {
    let frame: CGRect
    let point: CGPoint
}

private struct CFLStickerCell: View {
    @ObservedObject var model: CFLConversationModel
    let context: CFLImageContext
    let sticker: CFLSticker
    let favorite: Bool?
    let favoriteBusy: Bool
    @Binding var preview: CFLStickerPreviewTarget?
    let send: () -> Void
    let toggleFavorite: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            CFLStickerThumbnail(model: model, context: context, sticker: sticker)
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    GeometryReader { geometry in
                        CFLStickerTouchTarget(enabled: sticker.available, onTap: {
                            if !model.busy { send() }
                        }, onHold: { point in
                            if let point {
                                let frame = geometry.frame(in: .named("CFLStickerPanel"))
                                let location = CFLStickerTouchLocation(
                                    frame: frame, point: CGPoint(x: frame.minX + point.x, y: frame.minY + point.y))
                                preview = CFLStickerPreviewTarget(sticker: sticker, location: location)
                            } else if preview?.sticker.id == sticker.id {
                                preview = nil
                            }
                        })
                    }
                }
                .onDisappear { if preview?.sticker.id == sticker.id { preview = nil } }
                .onChange(of: sticker.available) { _, available in
                    if !available && preview?.sticker.id == sticker.id { preview = nil }
                }
                .accessibilityElement()
                .accessibilityLabel(sticker.name)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if sticker.available && !model.busy { send() } }
            if let favorite {
                Button(action: toggleFavorite) {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(favoriteBusy)
                .accessibilityLabel(favorite ? NSLocalizedString("取消收藏", comment: "Remove favorite") : NSLocalizedString("收藏表情", comment: "Favorite sticker"))
            }
        }
    }
}

/// UIKit recognizers let the enclosing scroll view cancel a tap on drag, while
/// a recognized long press owns the preview until the touch ends or is cancelled.
private struct CFLStickerTouchTarget: UIViewRepresentable {
    let enabled: Bool
    let onTap: () -> Void
    let onHold: (CGPoint?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isAccessibilityElement = false
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45
        hold.allowableMovement = 12
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.isUserInteractionEnabled = enabled
    }

    final class Coordinator: NSObject {
        var parent: CFLStickerTouchTarget
        init(parent: CFLStickerTouchTarget) { self.parent = parent }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { parent.onTap() }
        }

        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let view = recognizer.view, view.window != nil else { return }
                parent.onHold(recognizer.location(in: view))
            case .ended, .cancelled, .failed:
                parent.onHold(nil)
            default:
                break
            }
        }
    }
}

private struct CFLStickerHeldPreview: View {
    static let width: CGFloat = 192
    static let height: CGFloat = 216
    @ObservedObject var model: CFLConversationModel
    let context: CFLImageContext
    let sticker: CFLSticker
    let tailOffset: CGFloat
    @State private var image: CFLDecodedImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    CFLImageContent(image: image, contentMode: .scaleAspectFit)
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 144, height: 144)
            Text(sticker.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
        }
        .padding(16)
        .frame(width: Self.width, height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottom) {
            CFLStickerPreviewTail()
                .fill(.regularMaterial)
                .frame(width: 18, height: 9)
                .offset(x: min(max(tailOffset, -Self.width / 2 + 18), Self.width / 2 - 18), y: 8)
        }
        .shadow(radius: 12)
        .task(id: "\(context.clientID)|\(context.session)|\(context.revision)|\(sticker.id)|\(sticker.version)") {
            image = nil
            failed = false
            guard let client = model.cachedStickerClient(for: context) else { return }
            do {
                let data = try await client.stickerMedia(sticker, original: true, session: context.session, revision: context.revision)
                let decoded = await Task.detached(priority: .userInitiated) {
                    CFLImageDecoder.decode(data, maxPixelSize: 600)
                }.value
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                image = decoded
                failed = decoded == nil
            } catch {
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                failed = true
                model.recordAuthorizationFailure(error)
            }
        }
    }
}

private struct CFLStickerPreviewTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct CFLStickerThumbnail: View {
    @ObservedObject var model: CFLConversationModel
    let context: CFLImageContext
    let sticker: CFLSticker
    @State private var image: UIImage?
    @State private var failed = false
    @State private var displayedIdentity = ""

    var body: some View {
        Group {
            if !sticker.available {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(context.clientID)|\(context.session)|\(context.revision)|\(sticker.id)|\(sticker.version)|\(sticker.available)|\(model.state.connection)") {
            let identity = "\(context.clientID)|\(context.session)|\(context.revision)|\(sticker.id)|\(sticker.version)"
            if displayedIdentity != identity {
                image = nil
                displayedIdentity = identity
            }
            failed = false
            guard sticker.available, let client = model.cachedStickerClient(for: context) else { return }
            do {
                if let cached = try await client.cachedStickerThumbnail(sticker, session: context.session, revision: context.revision) {
                    let thumbnail = await Task.detached(priority: .userInitiated) {
                        CFLStickerPreview.firstFrame(cached)
                    }.value
                    guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                    image = thumbnail
                }
                let data = try await client.stickerMedia(sticker, session: context.session, revision: context.revision)
                let thumbnail = await Task.detached(priority: .userInitiated) {
                    CFLStickerPreview.firstFrame(data)
                }.value
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                image = thumbnail
                failed = image == nil
            } catch CFLStickerThumbnailFailure.removed {
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                image = nil
                failed = true
            } catch CFLFailure.accessDenied {
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                image = nil
                failed = true
                model.recordAuthorizationFailure(CFLFailure.accessDenied)
            } catch {
                guard !Task.isCancelled, model.cachedStickerClient(for: context) != nil else { return }
                failed = image == nil
                model.recordAuthorizationFailure(error)
            }
        }
    }
}

/// Decode the server's static thumbnail at the size needed by the picker.
enum CFLStickerPreview {
    nonisolated static func firstFrame(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: frame)
    }
}
#endif
