#if os(iOS)
import SwiftUI
import UIKit
import ImageIO
import ETOSCore

/// Displays every server-provided image, including image-only assistant messages.
struct CFLMessageImages: View {
    let images: [CFLImageRef]
    let outgoing: Bool
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 40) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(images.count, 3)), spacing: 4) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    CFLMessageImage(image: image, model: model, target: target, session: session, revision: revision, clientID: clientID)
                }
            }
            .frame(maxWidth: images.count == 1 ? 180 : 260)
            if !outgoing { Spacer(minLength: 40) }
        }
    }
}

private struct CFLMessageImage: View {
    let image: CFLImageRef
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    @State private var thumbnail: UIImage?
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
                    Image(uiImage: thumbnail).resizable().scaledToFill()
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
        .accessibilityLabel(image.name)
        .task(id: "\(clientID)|\(target ?? "")|\(session ?? "")|\(revision)|\(model.imagePageRevision)|\(model.imagePageActive)|\(image.attachmentId)|\(attempt)") { await loadThumbnail() }
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
            let data = try await model.media(image, target: target, session: session, revision: revision, clientID: clientID)
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.thumbnail(data)
            }.value
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                  model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
            guard let decoded else { failed = true; return }
            thumbnail = decoded
        } catch {
            guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision else { return }
            failed = true
        }
    }

    nonisolated private static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct CFLOriginalImage: View {
    let image: CFLImageRef
    @ObservedObject var model: CFLConversationModel
    let target: String?
    let session: String?
    let revision: Int
    let clientID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var decoded: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let decoded {
                    Image(uiImage: decoded).resizable().scaledToFit()
                } else if failed {
                    Button(NSLocalizedString("图片加载失败，点按重试", comment: "Retry loading image")) { attempt += 1 }
                        .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "Done")) { dismiss() }
            } }
        }
        .task(id: "\(attempt)|\(model.imagePageRevision)|\(model.imagePageActive)") {
            guard model.imagePageActive else { return }
            let pageRevision = model.imagePageRevision
            failed = false
            do {
                let data = try await model.media(image, target: target, session: session, revision: revision, clientID: clientID, original: true)
                let result = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value
                guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision,
                      model.isCurrentMediaContext(target: target, session: session, revision: revision, clientID: clientID) else { return }
                decoded = result
                failed = result == nil
            } catch {
                guard !Task.isCancelled, model.imagePageActive, model.imagePageRevision == pageRevision else { return }
                failed = true
            }
        }
    }
}
#endif
