#if os(iOS)
import Foundation
import ETOSCore

struct CFLDisplayFile: Equatable, Sendable {
    let name: String
    let size: Int
    var ref: CFLFileRef? = nil

    init(name: String, size: Int, ref: CFLFileRef? = nil) {
        self.name = name; self.size = size; self.ref = ref
    }
    init(_ ref: CFLFileRef) { self.init(name: ref.name, size: ref.size, ref: ref) }
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
    var files: [CFLDisplayFile] = []
    var markdownSources: CFLMarkdownImageSources? = nil
    var markdownSourcesRevision = 0
    var isReminder = false
    var voice: CFLVoiceRef? = nil
    var ui: CFLJSONValue? = nil
    var imageState: CFLImageState? = nil
    var previews: [CFLLocalImagePreview] = []
    var pending: CFLPending? = nil
    var sendingLocally = false
    var sourceID: String? = nil
    var historyGap: CFLHistoryGap? = nil
}

nonisolated enum CFLTimelineProjection {
    struct LocalProjection: Equatable, Sendable {
        let origin: String
        let draft: CFLLocalDraft
        var files: [CFLDisplayFile] = []
        let pending: CFLPending?
        let sending: Bool
    }
    struct PendingAnchor: Equatable, Sendable {
        let session: String
        let after: String?
        var predecessor: String? = nil
    }
    struct ProjectionInput: Equatable, Sendable {
        let target: String?
        let session: String?
        let revision: Int
        let clientID: UUID
        let messages: [CFLMessage]
        let reply: CFLStreamingReply?
        let historyGaps: [CFLHistoryGap]
        let drafts: [CFLLocalDraft]
        let previews: [CFLLocalImagePreview]
        let pending: [CFLPending]
        let otherTargetPending: [CFLPending]
        let anchors: [String: PendingAnchor]
        let locals: [LocalProjection]
        let origins: [String: String]
    }
    struct ReplyCache: Sendable {
        let source: String
        let ends: [Int]
        let chunks: [ReplyChunk]
        let imageSources: CFLMarkdownImageSources
        let chunkImages: [Int: ChunkImageState]
    }
    struct ReplyChunk: Sendable {
        let id: Int
        let text: String
    }
    struct ChunkImageState: Sendable {
        let targets: [CFLMarkdownImageTarget]
        let revision: Int
    }
    struct ProjectionResult: Sendable {
        let messages: [CFLDisplayMessage]
        let reply: [CFLDisplayMessage]
        let cache: [String: ReplyCache]
    }
    nonisolated static func project(_ input: ProjectionInput, cache: [String: ReplyCache]) -> ProjectionResult {
        let messageIDs = Set(input.messages.map(\.id))
        var nextCache: [String: ReplyCache] = [:]
        func stablePreviews(_ previews: [CFLLocalImagePreview], operation: String?) -> [CFLLocalImagePreview] {
            guard let operation, let origin = input.origins[operation] else { return previews }
            return previews.map { preview in
                guard preview.originOperationId != origin else { return preview }
                return CFLLocalImagePreview(sessionId: preview.sessionId, operationId: preview.operationId,
                    originOperationId: origin, draftId: preview.draftId, order: preview.order,
                    attachmentId: preview.attachmentId, data: preview.data)
            }
        }
        func rows(id: String, text: String, ends: [Int], images: [CFLImageRef] = []) -> [CFLDisplayMessage] {
            guard let texts = try? CFLReplySegments.texts(text, ends: ends) else { return [] }
            let source = (text as NSString).substring(to: ends.last ?? 0)
            let chunks = cache[id].flatMap { $0.source == source && $0.ends == ends ? $0.chunks : nil }
                ?? texts.enumerated().map { ReplyChunk(id: $0.offset, text: $0.element) }
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
            nextCache[id] = ReplyCache(source: source, ends: ends, chunks: chunks, imageSources: imageSources, chunkImages: chunkImages)
            if chunks.isEmpty && !images.isEmpty {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: 0), text: "", outgoing: false, markdown: true, images: images, sessionRevision: input.revision, clientID: input.clientID)]
            }
            return chunks.enumerated().map { index, chunk in
                CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: id, offset: chunk.id), text: chunk.text, outgoing: false, markdown: true, images: index == chunks.count - 1 ? images : [], sessionRevision: input.revision, clientID: input.clientID, markdownSources: imageSources, markdownSourcesRevision: chunkImages[chunk.id]?.revision ?? 0)
            }
        }
        func messageRows(_ message: CFLMessage) -> [CFLDisplayMessage] {
            let operation = message.operationId
            if let ui = message.ui {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: -1), text: "", outgoing: false, markdown: false, images: [], sessionRevision: input.revision, clientID: input.clientID, ui: ui)]
            }
            if let operation, let source = input.pending.first(where: { $0.sessionId == input.session && $0.operationId == operation })?.retrySource,
               (input.pending.first(where: { $0.operationId == operation && $0.sessionId == input.session })?.files?.isEmpty == false ||
                (input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == source }) &&
                 !input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == operation }))) {
                return []
            }
            if let voice = message.voice {
                let audio = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: -1), text: "", outgoing: false, markdown: false, images: [], sessionRevision: input.revision, clientID: input.clientID, voice: voice)
                if message.text.isEmpty && (message.images?.isEmpty ?? true) { return [audio] }
                if message.isReminder {
                    return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text, outgoing: false, markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, isReminder: true), audio]
                }
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text, outgoing: message.role == "user", markdown: message.role == "agent", images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, markdownSources: message.role == "agent" ? CFLMarkdownImageSources(markdown: message.text) : nil), audio]
            }
            if message.isReminder {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text,
                                          outgoing: false, markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, isReminder: true)]
            }
            if message.role == "agent", message.source == nil, message.imageState == nil {
                return rows(id: message.id, text: message.text, ends: message.ends ?? [], images: message.images ?? [])
            }
            if message.role == "agent" {
                return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: message.id, offset: 0), text: message.text, outgoing: false, markdown: message.imageState == nil, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID, imageState: message.imageState)]
            }
            let local = operation.flatMap { id in input.locals.first { $0.draft.operationId == id } }
            let previews = stablePreviews(input.previews.filter { preview in
                preview.sessionId == input.session && preview.operationId == operation &&
                    (message.images ?? []).contains(where: { $0.attachmentId == preview.attachmentId })
            }, operation: operation)
            let localPreviews: [CFLLocalImagePreview]
            if let local, let refs = message.images, refs.count == local.draft.images.count {
                localPreviews = zip(local.draft.images, refs).map { preview, ref in
                    CFLLocalImagePreview(sessionId: preview.sessionId, operationId: preview.operationId,
                        originOperationId: preview.originOperationId, draftId: preview.draftId,
                        order: preview.order, attachmentId: ref.attachmentId, data: preview.data)
                }
            } else { localPreviews = local?.draft.images ?? [] }
            let rowID = operation.map { "local:\(input.origins[$0] ?? previews.first?.originOperationId ?? $0)" }
                ?? message.id
            return [CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: rowID, offset: 0), text: message.text,
                                      outgoing: message.role == "user", markdown: false, images: message.images ?? [], sessionRevision: input.revision, clientID: input.clientID,
                                      files: (message.files ?? []).map(CFLDisplayFile.init), previews: previews.isEmpty ? localPreviews : previews)]
        }
        var groups = input.messages.map { message in
            (source: Optional(message.id), rows: messageRows(message).map { row in
                var row = row; row.sourceID = message.id; return row
            })
        }.filter { !$0.rows.isEmpty }
        let messageOperations = Set(input.messages.compactMap { message -> String? in
            guard let operation = message.operationId else { return nil }
            if let source = input.pending.first(where: { $0.sessionId == input.session && $0.operationId == operation })?.retrySource,
               (input.pending.first(where: { $0.operationId == operation && $0.sessionId == input.session })?.files?.isEmpty == false ||
                (input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == source }) &&
                 !input.previews.contains(where: { $0.sessionId == input.session && $0.operationId == operation }))) { return nil }
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
        let localOperations = Set(input.locals.map { $0.draft.operationId })
        for local in input.locals where !messageOperations.contains(local.draft.operationId) {
            let draft = local.draft
            let realPreviews = stablePreviews(input.previews.filter { $0.sessionId == input.session && $0.operationId == draft.operationId }.sorted { $0.order < $1.order }, operation: draft.operationId)
            let row = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "local:\(local.origin)", offset: 0),
                text: draft.text, outgoing: true, markdown: false, images: local.pending?.images ?? [],
                sessionRevision: input.revision, clientID: input.clientID,
                files: local.pending?.files.map { $0.map(CFLDisplayFile.init) } ?? local.files, previews: realPreviews.isEmpty ? draft.images : realPreviews, pending: local.pending, sendingLocally: local.sending)
            insert(row, operation: draft.operationId, source: nil)
        }
        for draft in input.drafts where draft.sessionId == input.session && !messageOperations.contains(draft.operationId) && !localOperations.contains(draft.operationId) {
            let row = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "local:\(draft.operationId)", offset: 0), text: draft.text, outgoing: true, markdown: false, images: [], sessionRevision: input.revision, clientID: input.clientID, previews: draft.images)
            insert(row, operation: draft.operationId, source: nil)
        }
        let pendingRows = input.pending.filter { pending in
            pending.sessionId == input.session && !messageOperations.contains(pending.operationId) && !localOperations.contains(pending.operationId) &&
                !input.drafts.contains(where: { $0.sessionId == pending.sessionId && $0.operationId == pending.operationId })
        }
        for pending in pendingRows {
            let previews = input.previews.filter { $0.sessionId == input.session && $0.operationId == (pending.retrySource ?? pending.operationId) }.sorted { $0.order < $1.order }
            let identity = input.origins[pending.operationId] ?? previews.first?.originOperationId ?? pending.retrySource ?? pending.operationId
            let row = CFLDisplayMessage(id: .init(target: input.target, session: input.session, message: "local:\(identity)", offset: 0), text: pending.text, outgoing: true, markdown: false, images: pending.images ?? [], sessionRevision: input.revision, clientID: input.clientID, files: (pending.files ?? []).map(CFLDisplayFile.init), previews: previews, pending: pending)
            insert(row, operation: pending.operationId, source: input.messages.first(where: { $0.operationId == pending.operationId })?.id)
        }
        let reply: [CFLDisplayMessage]
        if let streaming = input.reply, !messageIDs.contains(streaming.id) {
            reply = rows(id: streaming.id, text: streaming.text, ends: streaming.ends ?? [])
        } else { reply = [] }
        return ProjectionResult(messages: groups.flatMap(\.rows), reply: reply, cache: nextCache)
    }
}
#endif
