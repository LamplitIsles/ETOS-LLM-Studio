#if os(iOS)
import SwiftUI
import UIKit
import ImageIO
import Kingfisher
import ETOSCore

/// Displays every server-provided image, including image-only assistant messages.
struct CFLMessageImages: View {
    let images: [CFLImageRef]
    var previews: [CFLLocalImagePreview] = []
    let outgoing: Bool
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    var failedPending: CFLPending? = nil
    var showFailureIndicator = false
    var canFavorite = true

    private var items: [CFLPresentedImage] {
        if images.isEmpty {
            return previews.sorted { $0.order < $1.order }.map { CFLPresentedImage(id: $0.draftId, ref: nil, preview: $0.data) }
        }
        return images.map { ref in
            let preview = previews.first { $0.attachmentId == ref.attachmentId }
            return CFLPresentedImage(id: preview?.draftId ?? ref.attachmentId, ref: ref, preview: preview?.data)
        }
    }

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 40) }
            if showFailureIndicator, let failedPending {
                CFLFailedSendIndicator(pending: failedPending, model: model)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(items.count, 3)), spacing: 4) {
                ForEach(items) { image in
                    CFLMessageImage(image: image, model: model, target: target, session: session, revision: revision, clientID: clientID, canFavorite: canFavorite)
                }
            }
            .frame(maxWidth: items.count == 1 ? 180 : 260)
            .contextMenu {
                if let failedPending { CFLFailedSendActions(pending: failedPending, model: model) }
            }
            if !outgoing { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 8)
    }
}

private struct CFLPresentedImage: Identifiable {
    let id: String
    let ref: CFLImageRef?
    let preview: Data?
}

private struct CFLMessageImage: View {
    let image: CFLPresentedImage
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    let canFavorite: Bool
    @State private var thumbnail: CFLDecodedImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var showingOriginal = false

    var body: some View {
        Button {
            if thumbnail != nil { showingOriginal = true }
            else if failed { attempt += 1 }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
                if let thumbnail {
                    CFLImageContent(image: thumbnail, contentMode: .scaleAspectFill)
                } else if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text(NSLocalizedString("图片加载失败，点按重试", comment: "Retry loading image"))
                            .font(.caption2).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(4)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image.ref?.name ?? NSLocalizedString("图片", comment: "Image"))
        .contextMenu {
            if canFavorite, let ref = image.ref, ref.availability == "available",
               let context = model.imageContext, context.target == target, context.session == session,
               context.revision == revision, context.clientID == clientID {
                Button {
                    Task { await model.favoriteChatImage(ref, context: context) }
                } label: {
                    Label(NSLocalizedString("收藏表情", comment: "Favorite sticker"), systemImage: "heart")
                }
            }
        }
        .task(id: "\(clientID)|\(target ?? "")|\(session ?? "")|\(revision)|\(model.imagePageRevision)|\(model.imagePageActive)|\(image.id)|\(image.preview != nil)|\(attempt)") { await loadThumbnail() }
        .sheet(isPresented: $showingOriginal) {
            CFLOriginalImage(image: image, model: model, target: target, session: session, revision: revision, clientID: clientID)
        }
    }

    private func loadThumbnail() async {
        guard model.imagePageActive else { return }
        let pageRevision = model.imagePageRevision
        thumbnail = nil
        failed = false
        do {
            let data: Data
            if let preview = image.preview { data = preview }
            else if let ref = image.ref {
                data = try await model.media(ref, target: target, session: session, revision: revision, clientID: clientID, original: CFLImageDecoder.needsOriginal(ref))
            }
            else { failed = true; return }
            let decoded = await Task.detached(priority: .userInitiated) {
                CFLImageDecoder.decode(data, maxPixelSize: 600)
            }.value
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                  model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
            guard let decoded else { failed = true; return }
            thumbnail = decoded
        } catch {
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                  model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
            failed = true
        }
    }
}

private struct CFLOriginalImage: View {
    let image: CFLPresentedImage
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var decoded: CFLDecodedImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let decoded {
                    CFLImageContent(image: decoded, contentMode: .scaleAspectFit)
                } else if failed {
                    VStack(spacing: 12) {
                        Button(NSLocalizedString("图片加载失败，点按重试", comment: "Retry loading image")) { attempt += 1 }
                        if model.needsSignIn || model.state.connection == .accessDenied {
                            Button(NSLocalizedString("CFL使用Passkey登录", comment: "CFL Passkey sign in")) {
                                Task {
                                    await model.signIn()
                                    if isVisible && !model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) { dismiss() }
                                }
                            }
                                .disabled(!model.canSignIn)
                        }
                        if let error = model.signInError {
                            Text(error).font(.caption).multilineTextAlignment(.center)
                        }
                    }.foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "Done")) { dismiss() }
            } }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: "\(attempt)|\(model.imagePageRevision)|\(model.imagePageActive)") {
            guard model.imagePageActive else { return }
            let pageRevision = model.imagePageRevision
            failed = false
            do {
                let data: Data
                if let ref = image.ref { data = try await model.media(ref, target: target, session: session, revision: revision, clientID: clientID, original: true) }
                else if let preview = image.preview { data = preview }
                else { failed = true; return }
                let result = await Task.detached(priority: .userInitiated) { CFLImageDecoder.decode(data, maxPixelSize: 2048, fullResolution: true) }.value
                guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                      model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
                decoded = result
                failed = result == nil
            } catch {
                guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                      model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
                failed = true
            }
        }
    }
}

// ImageIO supplies frame data; Kingfisher displays a bounded number of frames without a disk cache.
struct CFLDecodedImage {
    let image: UIImage
    let animated: Bool
}

enum CFLImageDecoder {
    nonisolated static func needsOriginal(_ ref: CFLImageRef) -> Bool {
        ref.mediaType == "image/gif" || ref.mediaType == "image/webp" || (ref.mediaType == "image/png" && ref.sticker != nil)
    }

    nonisolated static func decode(_ data: Data, maxPixelSize: Int, fullResolution: Bool = false) -> CFLDecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetCount(source) > 1 {
            let frames = CFLImageFrameSource(data: data, maxPixelSize: maxPixelSize)
            guard let image = KingfisherWrapper<UIImage>.animatedImage(source: frames, options: ImageCreatingOptions()) else { return nil }
            return CFLDecodedImage(image: image, animated: true)
        }
        if fullResolution {
            return UIImage(data: data).map { CFLDecodedImage(image: $0, animated: false) }
        }
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary) else { return nil }
        return CFLDecodedImage(image: UIImage(cgImage: frame), animated: false)
    }
}

private struct CFLImageFrameSource: ImageFrameSource {
    let data: Data?
    let maxPixelSize: Int
    private let source: CGImageSource?

    init(data: Data, maxPixelSize: Int) {
        self.data = data
        self.maxPixelSize = maxPixelSize
        self.source = CGImageSourceCreateWithData(data as CFData, nil)
    }

    var frameCount: Int { source.map(CGImageSourceGetCount) ?? 0 }

    func frame(at index: Int, maxSize: CGSize?) -> CGImage? {
        guard let source, index >= 0, index < frameCount else { return nil }
        let requested = maxSize.map { max($0.width, $0.height) }
        let limit = requested.flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded(.up)) : nil } ?? maxPixelSize
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(1, limit))
        ] as CFDictionary)
    }

    func duration(at index: Int) -> TimeInterval {
        guard let source, index >= 0, index < frameCount,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] else { return 0 }
        let formats: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
        ]
        for (dictionary, unclamped, delay) in formats {
            guard let values = properties[dictionary as String] as? [String: Any] else { continue }
            let value = (values[unclamped as String] as? NSNumber)?.doubleValue ?? (values[delay as String] as? NSNumber)?.doubleValue ?? 0.1
            return value.isFinite && value >= 0.02 ? value : 0.1
        }
        return 0.1
    }

    func copy() -> Self { Self(data: data ?? Data(), maxPixelSize: maxPixelSize) }
}

struct CFLImageContent: View {
    let image: CFLDecodedImage
    let contentMode: UIView.ContentMode

    var body: some View {
        if image.animated {
            CFLAnimatedImage(image: image.image, contentMode: contentMode)
        } else {
            Image(uiImage: image.image).resizable().aspectRatio(contentMode: contentMode == .scaleAspectFill ? .fill : .fit)
        }
    }
}

private struct CFLAnimatedImage: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView()
        view.framePreloadCount = 3
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.image = image
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AnimatedImageView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateUIView(_ view: AnimatedImageView, context: Context) {
        view.contentMode = contentMode
        if view.image !== image { view.image = image }
    }

    static func dismantleUIView(_ view: AnimatedImageView, coordinator: ()) {
        view.stopAnimating()
        view.image = nil
    }
}
#endif
