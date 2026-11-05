// ============================================================================
// ETAdvancedMarkdownRendererMathImages.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS Markdown 数学公式图片提供、缓存与 SwiftMath 渲染。
// ============================================================================

import Foundation
import Combine
import SwiftUI
import MarkdownUI
import UIKit
import ETOSCore

#if canImport(SwiftMath)
import SwiftMath
#endif

@MainActor
final class CFLMarkdownImageStatus: ObservableObject {
    @Published private(set) var inlineFailed = false
    @Published var attempt = 0
    private let store = CFLMarkdownImageStore()

    func data(for key: Data, context: CFLMarkdownImageStore.Context, load: @escaping @MainActor () async throws -> Data) async throws -> Data {
        try await store.data(for: key, context: context, load: load)
    }

    func updateContext(_ context: CFLMarkdownImageStore.Context) {
        store.updateContext(context)
        inlineFailed = store.inlineFailed
    }

    var stamp: UInt64 { store.stamp }

    func inlineFailure(_ url: URL, stamp: UInt64) {
        store.inlineFailure(url.absoluteString, stamp: stamp)
        inlineFailed = store.inlineFailed
    }

    func inlineSuccess(_ url: URL, stamp: UInt64) {
        store.inlineSuccess(url.absoluteString, stamp: stamp)
        inlineFailed = store.inlineFailed
    }

    func invalidate() {
        store.invalidate()
        inlineFailed = false
    }

    func discard(_ key: Data) { store.discard(key) }

    func retry() {
        store.clearInlineFailures()
        inlineFailed = false
        attempt += 1
    }
}

/// A rendering context is tied to the connection and page that produced the message.
struct CFLMarkdownImageContext {
    let model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    let status: CFLMarkdownImageStatus
    let originalSources: CFLMarkdownImageSources?
    var sourceRevision = 0
    var renderedSources: CFLMarkdownImageSources? = nil

    func rendered(sources: CFLMarkdownImageSources) -> Self {
        var result = self
        result.renderedSources = sources
        return result
    }

    func source(for url: URL) -> String? {
        guard let source = originalSources?.source(for: url),
              let renderedSource = renderedSources?.source(for: url),
              CFLMarkdownImageSources.areEquivalent(source, renderedSource) else { return nil }
        return source
    }

    @MainActor
    func load(_ url: URL) async throws -> UIImage {
        let data = try await data(for: url)
        guard let image = UIImage(data: data) else {
            discard(for: url)
            throw CFLFailure.protocolError
        }
        return image
    }

    private func cacheKey(for target: CFLMarkdownImage) throws -> Data {
        switch target {
        case .workspace(let path): return Data([0]) + Data(path.utf8)
        case .external(let path): return Data([1]) + Data(path.utf8)
        case .api(let path): return Data([2]) + Data(path.utf8)
        case .invalid: throw CFLFailure.invalidInput
        }
    }

    @MainActor
    func discard(for url: URL) {
        guard let source = source(for: url), let key = try? cacheKey(for: CFLMarkdownImage.resolve(source)) else { return }
        status.discard(key)
    }

    @MainActor
    func data(for url: URL) async throws -> Data {
        guard model.imagePageActive,
              model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else {
            throw CFLFailure.sessionChanged
        }
        let pageRevision = model.imagePageRevision
        do {
            guard let source = source(for: url) else { throw CFLFailure.invalidInput }
            let resolvedTarget = CFLMarkdownImage.resolve(source)
            let key = try cacheKey(for: resolvedTarget)
            let context = CFLMarkdownImageStore.Context(target: target, session: session, revision: revision,
                                                        clientID: clientID)
            status.updateContext(context)
            let data = try await status.data(for: key, context: context) {
                switch resolvedTarget {
                case .external(let destination):
                    return try await model.externalImage(destination, target: self.target, session: session, revision: revision, clientID: clientID)
                case .workspace, .api:
                    return try await model.markdownImage(source, target: self.target, session: session, revision: revision, clientID: clientID)
                case .invalid:
                    throw CFLFailure.invalidInput
                }
            }
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                  model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else {
                throw CFLFailure.sessionChanged
            }
            return data
        } catch {
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                  model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else {
                throw CFLFailure.sessionChanged
            }
            throw error
        }
    }
}

private struct CFLMarkdownBlockImage: View {
    let url: URL
    let context: CFLMarkdownImageContext
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Button { attempt += 1 } label: {
                    Label(NSLocalizedString("图片加载失败，点按重试", comment: "Retry loading image"), systemImage: "photo.badge.exclamationmark")
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(url.absoluteString)|\(context.source(for: url) ?? "")|\(context.clientID)|\(context.revision)|\(context.model.imagePageRevision)|\(attempt)") {
            image = nil
            failed = false
            do {
                let loaded = try await context.load(url)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled, (error as? CFLFailure) != .sessionChanged, context.model.imagePageActive,
                      context.model.isCurrentMediaContext(target: context.target, session: context.session, revision: context.revision, clientID: context.clientID) else { return }
                failed = true
            }
        }
    }
}

struct ETIOSMarkdownImageProvider: ImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double
    var remoteImagesEnabled = true
    var cflImages: CFLMarkdownImageContext? = nil

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let request = ETNativeMathMarkdownCodec.request(from: url) {
            ETIOSMathBlockImageView(
                request: request,
                textColor: textColor,
                fontScale: fontScale
            )
        } else if let cflImages, let url {
            CFLMarkdownBlockImage(url: url, context: cflImages)
        } else if remoteImagesEnabled {
            DefaultImageProvider.default.makeImage(url: url)
        } else {
            Image(systemName: "photo")
        }
    }
}

struct ETIOSMarkdownInlineImageProvider: InlineImageProvider {
    let textColor: ETIOSMathColorComponents
    let fontScale: Double
    var remoteImagesEnabled = true
    var cflImages: CFLMarkdownImageContext? = nil

    func image(with url: URL, label: String) async throws -> Image {
        guard let request = ETNativeMathMarkdownCodec.request(from: url) else {
            if let cflImages {
                let stamp: UInt64? = await MainActor.run {
                    let model = cflImages.model
                    guard model.imagePageActive,
                          model.isCurrentMediaContext(target: cflImages.target, session: cflImages.session,
                                                      revision: cflImages.revision, clientID: cflImages.clientID) else { return nil }
                    cflImages.status.updateContext(.init(target: cflImages.target, session: cflImages.session,
                                                         revision: cflImages.revision, clientID: cflImages.clientID))
                    return cflImages.status.stamp
                }
                guard let stamp else { return Image(systemName: "photo") }
                do {
                    let image = try await cflImages.load(url)
                    await MainActor.run {
                        if !Task.isCancelled && cflImages.model.imagePageActive && cflImages.model.isCurrentMediaContext(target: cflImages.target, session: cflImages.session, revision: cflImages.revision, clientID: cflImages.clientID) {
                            cflImages.status.inlineSuccess(url, stamp: stamp)
                        }
                    }
                    return Image(uiImage: image)
                } catch {
                    if !Task.isCancelled && (error as? CFLFailure) != .sessionChanged {
                        await MainActor.run {
                            if cflImages.model.imagePageActive && cflImages.model.isCurrentMediaContext(target: cflImages.target, session: cflImages.session, revision: cflImages.revision, clientID: cflImages.clientID) {
                                cflImages.status.inlineFailure(url, stamp: stamp)
                            }
                        }
                    }
                    return Image(systemName: "photo.badge.exclamationmark")
                }
            }
            if remoteImagesEnabled {
                return try await DefaultInlineImageProvider.default.image(with: url, label: label)
            }
            return Image(systemName: "photo")
        }

        guard let data = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale),
              let image = UIImage(data: data, scale: UIScreen.main.scale) else {
            return Image(systemName: "function")
        }

        return Image(uiImage: image)
    }
}

private struct ETIOSMathBlockImageView: View {
    let request: ETNativeMathMarkdownCodec.Request
    let textColor: ETIOSMathColorComponents
    let fontScale: Double

    @State private var renderedImageData: Data?
    @State private var didAttemptRender = false

    var body: some View {
        Group {
            if let renderedImage {
                ScrollView(.horizontal, showsIndicators: false) {
                    Image(uiImage: renderedImage)
                        .interpolation(.high)
                        .antialiased(true)
                }
            } else if didAttemptRender {
                Text(verbatim: request.latex)
                    .font(.system(size: request.renderKind.fallbackFontSize(fontScale: fontScale), design: .serif))
                    .foregroundStyle(textColor.swiftUIColor.opacity(0.9))
                    .textSelection(.enabled)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(textColor.swiftUIColor.opacity(0.08))
                    .frame(height: request.renderKind.placeholderHeight(fontScale: fontScale))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(request.latex)
        .task(id: taskKey) {
            didAttemptRender = false
            renderedImageData = nil
            renderedImageData = await ETIOSMathImageRenderer.imageData(for: request, textColor: textColor, fontScale: fontScale)
            didAttemptRender = true
        }
    }

    private var renderedImage: UIImage? {
        guard let renderedImageData else { return nil }
        return UIImage(data: renderedImageData, scale: UIScreen.main.scale)
    }

    private var taskKey: String {
        "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)"
    }
}

struct ETIOSMathColorComponents: Hashable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: Color) {
        let resolvedColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        } else {
            self.red = 0
            self.green = 0
            self.blue = 0
            self.alpha = 1
        }
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var swiftUIColor: Color {
        Color(uiColor: uiColor)
    }

    var cacheKey: String {
        "\(red)|\(green)|\(blue)|\(alpha)"
    }
}

enum ETIOSMathImageRenderer {
#if canImport(SwiftMath)
    private static let cache = NSCache<NSString, NSData>()
    // SwiftMath 共享字体及排版缓存；整个渲染操作必须串行，且不能占用主线程。
    private static let renderQueue = DispatchQueue(label: "com.ericterminal.els.math-render", qos: .userInitiated)

    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            renderQueue.async {
                let cacheKey = "\(request.renderKind.rawValue)|\(request.latex)|\(textColor.cacheKey)|\(fontScale)" as NSString
                // 队列内复查，使并发请求同一公式时只实际渲染一次。
                if let cachedData = cache.object(forKey: cacheKey) {
                    continuation.resume(returning: cachedData as Data)
                    return
                }
                let image = MTMathImage(
                    latex: request.latex,
                    fontSize: request.renderKind.fontSize(fontScale: fontScale),
                    textColor: textColor.uiColor,
                    labelMode: request.renderKind.labelMode,
                    textAlignment: .left
                )
                image.contentInsets = UIEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
                let result = image.asImage()
                guard result.0 == nil, let renderedImage = result.1 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = renderedImage.pngData()
                if let data {
                    cache.setObject(data as NSData, forKey: cacheKey)
                }
                continuation.resume(returning: data)
            }
        }
    }
#else
    static func imageData(
        for request: ETNativeMathMarkdownCodec.Request,
        textColor: ETIOSMathColorComponents,
        fontScale: Double
    ) async -> Data? {
        _ = request
        _ = textColor
        _ = fontScale
        return nil
    }
#endif
}
