import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CFLHTTPSOrigin {
    /// Returns an empty string for an unset origin and nil for invalid input.
    public static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard trimmed.lowercased().hasPrefix("https://"), var parts = URLComponents(string: trimmed),
              let rawHost = parts.host, !rawHost.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.url != nil else { return nil }
        let authority = String(trimmed.dropFirst(8).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let portText: Substring?
        if authority.hasPrefix("[") {
            guard let closing = authority.firstIndex(of: "]") else { return nil }
            let suffix = authority[authority.index(after: closing)...]
            guard suffix.isEmpty || suffix.first == ":" else { return nil }
            portText = suffix.isEmpty ? nil : suffix.dropFirst()
        } else if let colon = authority.lastIndex(of: ":") {
            portText = authority[authority.index(after: colon)...]
        } else { portText = nil }
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(portText), (1...65535).contains(port), parts.port == port else { return nil }
            parts.port = port == 443 ? nil : port
        }
        let host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let address = String(host.dropFirst().dropLast())
            var binary = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &binary) }) == 1 else { return nil }
            let bufferSize = Int(INET6_ADDRSTRLEN)
            var buffer = [CChar](repeating: 0, count: bufferSize)
            guard inet_ntop(AF_INET6, &binary, &buffer, socklen_t(bufferSize)) != nil else { return nil }
            parts.host = "[\(String(cString: buffer))]"
        } else {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            }) else { return nil }
            if host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789.").contains($0) }) {
                guard labels.count == 4, labels.allSatisfy({ label in
                    (label.count == 1 || label.first != "0") && Int(label).map { $0 <= 255 } == true
                }) else { return nil }
            }
            parts.host = host
        }
        parts.scheme = "https"; parts.path = ""
        return parts.url?.absoluteString
    }
}

public struct CFLMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let text: String
    /// End offsets of published reply segments, measured in UTF-16 code units.
    public let ends: [Int]?
    /// Milliseconds since the Unix epoch, as provided by the shared contract.
    public let createdAt: Double
    public let operationId: String?
    public let turnId: String?
    public let images: [CFLImageRef]?
    public let files: [CFLFileRef]?
    public let imageState: CFLImageState?
    public let textState: CFLTextState?
    public let voice: CFLVoiceRef?
    public let source: CFLMessageSource?
    public var isReminder: Bool { source?.kind == "reminder" }
    var valid: Bool {
        guard !id.isEmpty, ["user", "agent", "notice"].contains(role), createdAt.isFinite,
              images?.allSatisfy(\.valid) ?? true, files?.allSatisfy(\.valid) ?? true, voice?.valid ?? true else { return false }
        if let imageState {
            guard role == "agent" else { return false }
            if imageState == .ready { return images?.count == 1 && images?.first?.availability == "available" }
            return images == nil
        }
        return true
    }
}
public enum CFLImageState: String, Codable, Equatable, Sendable { case preparing, ready, failed, unknown }
public enum CFLTextState: String, Codable, Equatable, Sendable { case streaming, complete }
public struct CFLVoiceRef: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public init(id: String) { self.id = id }
    var valid: Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
public struct CFLMessageSource: Codable, Equatable, Sendable {
    public let kind: String?

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = try? container?.decode(String.self, forKey: .kind)
    }
}
public struct CFLImageRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String { attachmentId }
    public let attachmentId: String
    public let name: String
    public let mediaType: String
    public let availability: String
    public let sticker: CFLStickerIdentity?
    public init(attachmentId: String, name: String, mediaType: String, availability: String, sticker: CFLStickerIdentity? = nil) {
        self.attachmentId = attachmentId; self.name = name; self.mediaType = mediaType; self.availability = availability; self.sticker = sticker
    }
    var valid: Bool {
        !attachmentId.isEmpty && attachmentId.utf8.count <= 100 && attachmentId.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && !name.isEmpty && name.utf16.count <= 200 && CFLImageLimits.types.contains(mediaType)
            && ["available", "missing"].contains(availability) && (sticker?.valid ?? true)
    }
}
/// File metadata is untrusted; never use it as a path or HTTP header.
public struct CFLFileRef: Codable, Equatable, Sendable, Identifiable {
    public var id: String { attachmentId }
    public let attachmentId: String, name: String, mediaType: String
    public let size: Int
    public let availability: String
    public init(attachmentId: String, name: String, mediaType: String, size: Int, availability: String) {
        self.attachmentId = attachmentId; self.name = name; self.mediaType = mediaType
        self.size = size; self.availability = availability
    }
    var valid: Bool {
        !attachmentId.isEmpty && attachmentId.utf8.count <= 100 && attachmentId.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && (1...200).contains(name.unicodeScalars.count) && mediaType.unicodeScalars.count <= 255
            && (0...100_000_000).contains(size) && ["available", "missing"].contains(availability)
    }
}
public struct CFLFileLimits: Codable, Equatable, Sendable {
    public let maxFilesPerMessage: Int, maxFileBytes: Int, maxMessageFileBytes: Int
    var valid: Bool {
        (1...6).contains(maxFilesPerMessage) && (1...100_000_000).contains(maxFileBytes) && (1...200_000_000).contains(maxMessageFileBytes)
    }
}
/// File-backed draft; callers retain the snapshot if staging fails.
public struct CFLPreparedFile: Sendable {
    public let id: String, name: String, mediaType: String
    public let size: Int
    public let ownedFileURL: URL
    public let sha256: String
    init(id: String, name: String, mediaType: String, ownedFile: URL, size: Int, sha256: String) {
        self.id = id; self.name = name; self.mediaType = mediaType
        self.size = size; self.ownedFileURL = ownedFile; self.sha256 = sha256
    }
}
struct CFLFileStagingStatus: Sendable {
    let uploaded: [String]
    let files: [CFLFileRef]?
}
/// Upload may have reached the server; no message was submitted. The user can
/// explicitly select files again for a new operation.
public struct CFLFileStagingUncertain: Error, Sendable {
    public let sessionId: String, operationId: String
}
/// The remote file operation was permanently retired.
public struct CFLFileOperationRetired: Error, Sendable { public init() {} }
public struct CFLInputRecovery: Codable, Equatable, Sendable {
    public let sourceId: String, operationId: String, text: String
    public let images: [CFLImageRef]
    public let files: [CFLFileRef]?
    public let replacementEligible: Bool
}
public struct CFLStickerIdentity: Codable, Equatable, Sendable {
    public let id: String, version: String
    public init(id: String, version: String) { self.id = id; self.version = version }
    var valid: Bool {
        !id.isEmpty && id.utf8.count <= 100 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && CFLVoiceRef(id: version).valid
    }
}
/// A catalog entry has no favorite flag; read the Human favorites pages to derive it.
public struct CFLSticker: Codable, Equatable, Sendable, Identifiable {
    public let id: String, version: String, name: String
    public let tags: [String]
    public let mediaType: String
    public let available: Bool
    public var identity: CFLStickerIdentity { CFLStickerIdentity(id: id, version: version) }
    var valid: Bool {
        identity.valid && name.utf16.count <= 160 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        tags.count <= 32 && Set(tags).count == tags.count && tags.allSatisfy {
            $0.utf16.count <= 80 && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } && CFLImageLimits.types.contains(mediaType)
    }
}
public struct CFLStickerPack: Codable, Equatable, Sendable, Identifiable {
    public let id: String, name: String, description: String
    public let cover: CFLSticker
    var valid: Bool {
        CFLStickerIdentity(id: id, version: String(repeating: "0", count: 64)).valid &&
        name.utf16.count <= 160 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        description.utf16.count <= 2000 && cover.valid
    }
}
public struct CFLStickerPage: Codable, Equatable, Sendable {
    public let stickers: [CFLSticker]
    public let nextCursor: String?
}
/// A cached page is historical; `needsRevalidation` means its cursor and page
/// boundaries must not be treated as a current, complete ordering.
public struct CFLFavoriteSnapshot: Codable, Equatable, Sendable {
    public let page: CFLStickerPage
    public let needsRevalidation: Bool
    public init(page: CFLStickerPage, needsRevalidation: Bool) {
        self.page = page; self.needsRevalidation = needsRevalidation
    }
}
public struct CFLStickerPackPage: Codable, Equatable, Sendable {
    public let packs: [CFLStickerPack]
    public let nextCursor: String?
}
public struct CFLStickerFavoriteResult: Codable, Equatable, Sendable {
    public let sticker: CFLSticker
    public let favorite: Bool
}

public struct CFLImageLimits: Codable, Equatable, Sendable {
    static let types: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif"]
    public let mediaTypes: [String]
    public let maxImagesPerMessage: Int
    public let maxImageBytes: Int
    public let maxMessageImageBytes: Int
    var valid: Bool {
        !mediaTypes.isEmpty && Set(mediaTypes).count == mediaTypes.count && Set(mediaTypes).isSubset(of: Self.types)
            && (1...6).contains(maxImagesPerMessage) && (1...8_000_000).contains(maxImageBytes)
            && (1...24_000_000).contains(maxMessageImageBytes)
    }
}
/// Prepared in memory by the caller; preview and model are separate JPEG variants.
public struct CFLPreparedImage: Sendable {
    public let id: String, name: String, mediaType: String
    public let original: Data, preview: Data, model: Data
    public init(id: String = UUID().uuidString, name: String, mediaType: String, original: Data, preview: Data, model: Data) {
        self.id = id; self.name = name; self.mediaType = mediaType
        self.original = original; self.preview = preview; self.model = model
    }
}
#if canImport(ImageIO)
public extension CFLPreparedImage {
    /// Keeps original bytes intact and derives independent bounded JPEG variants.
    static func prepare(name: String, mediaType: String, original: Data) throws -> CFLPreparedImage {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw CFLFailure.invalidInput }
        func variant(maxDimension: Int, maxBytes: Int) throws -> Data {
            for dimension in [maxDimension, maxDimension / 2, maxDimension / 4, maxDimension / 8] {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(dimension, 32)]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CFLFailure.invalidInput }
                for quality in [0.8, 0.6, 0.4] {
                    let data = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw CFLFailure.invalidInput }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw CFLFailure.invalidInput }
                    if data.length <= maxBytes { return data as Data }
                }
            }
            throw CFLFailure.invalidInput
        }
        return try CFLPreparedImage(name: name, mediaType: mediaType, original: original,
                                    preview: variant(maxDimension: 512, maxBytes: 160_000),
                                    model: variant(maxDimension: 1568, maxBytes: 320_000))
    }
}
#endif
public struct CFLStreamingReply: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let turnId: String?
    /// Milliseconds since the Unix epoch, as provided by the shared contract.
    public let createdAt: Double
    public let text: String
    /// End offsets of published reply segments, measured in UTF-16 code units.
    public let ends: [Int]?
}

/// Slices only at host-provided boundaries; it does not infer Markdown segments.
public enum CFLReplySegments {
    static func valid(_ text: String, ends: [Int]) -> Bool {
        valid(Array(text.utf16), ends: ends)
    }
    private static func valid(_ units: [UInt16], ends: [Int]) -> Bool {
        var previous = 0
        for end in ends {
            guard end > previous, end <= units.count else { return false }
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]),
               (0xDC00...0xDFFF).contains(units[end]) { return false }
            previous = end
        }
        return true
    }
    public static func texts(_ text: String, ends: [Int]) throws -> [String] {
        let units = Array(text.utf16)
        guard valid(units, ends: ends) else { throw CFLFailure.protocolError }
        var start = 0
        var result: [String] = []
        for end in ends {
            result.append(String(decoding: units[start..<end], as: UTF16.self))
            start = end
        }
        return result
    }
}
struct CFLView: Decodable, Sendable {
    let version: Int
    let sessionId: String
    let name: String
    let activeTurnId: String?
    let streamingReply: CFLStreamingReply?
    let replyCompletedTurnId: String?
    let messages: [CFLMessage]
    let before: String?
}
struct CFLPage: Decodable, Sendable { let messages: [CFLMessage]; let before: String? }
struct CFLReceipt: Decodable, Sendable {
    let operationId: String
    let state: String
    let messageId: String?
    let turnId: String?
    let error: String?
    let retryImages: CFLRetryImageMapping?
    let retryFiles: CFLRetryFileMapping?
}
struct CFLRetryImageMapping: Decodable, Sendable {
    struct Item: Decodable, Sendable { let sourceAttachmentId: String; let ref: CFLImageRef }
    let sessionId: String
    let sourceOperationId: String
    let images: [Item]
}
struct CFLRetryFileMapping: Decodable, Sendable {
    struct Item: Decodable, Sendable { let sourceAttachmentId: String; let ref: CFLFileRef }
    let sessionId: String, sourceOperationId: String
    let files: [Item]
}
public enum CFLConnection: Equatable, Sendable { case offline, connecting, online, accessDenied, protocolError }
/// The supplied directory item is unavailable. HTTP read failures use CFLFailure.
public enum CFLStickerThumbnailFailure: Error, Equatable, Sendable { case removed }

public enum CFLFailure: Error, Equatable, Sendable { case offline, accessDenied, invalidInput, storage, protocolError, requestFailed, sessionChanged }

/// Classifies the original Markdown destination, before any URL decoding.
public enum CFLMarkdownImage: Equatable, Sendable {
    case external(String), api(String), workspace(String), invalid

    public static func resolve(_ source: String) -> Self {
        if source.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .external(source)
        }
        if source.hasPrefix("/api/") { return .api(source) }
        guard let path = source.removingPercentEncoding,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.range(of: #"[\x{0000}-\x{001f}\x{007f}-\x{009f}\\]"#, options: .regularExpression) == nil,
              path.range(of: #"^[a-z][a-z\d+.-]*:"#, options: [.regularExpression, .caseInsensitive]) == nil,
              !path.hasPrefix("//"),
              path.range(of: #"^/api(?:/|$)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              path.range(of: #"\.(?:png|jpe?g|webp|gif)$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return .invalid }
        return .workspace(path)
    }
}
public enum CFLPendingStatus: String, Codable, Equatable, Sendable { case unknown, submitted, failed }
/// Result of this invocation; pending state may subsequently change through reconciliation.
public enum CFLSendOutcome: Equatable, Sendable {
    /// This invocation did not send submit. Inspect pending state and resolve any
    /// storage error before deciding how to handle or retry the original input.
    case notDispatched
    /// A submit may have reached the server. Reconcile; never send it again.
    case unknown
    case submitted, failed
}
public enum CFLSendFailure: Error, Equatable, Sendable { case duplicateOperationId }
public struct CFLPending: Codable, Equatable, Sendable, Identifiable {
    public var id: String { operationId }
    public let target: String
    public let sessionId: String
    public let operationId: String
    public let text: String
    public let createdAt: Date
    /// Persisted before dispatch; true means the input may have reached the server.
    public var dispatched: Bool
    public var status: CFLPendingStatus
    /// Nil for existing text-only records. Never contains image bytes.
    public var images: [CFLImageRef]? = nil
    /// A manually retried failed operation; operationId is the new attempt.
    public var retrySource: String? = nil
    public var files: [CFLFileRef]? = nil

    public init(target: String, sessionId: String, operationId: String, text: String, createdAt: Date,
                dispatched: Bool, status: CFLPendingStatus, images: [CFLImageRef]? = nil, retrySource: String? = nil, files: [CFLFileRef]? = nil) {
        self.target = target; self.sessionId = sessionId; self.operationId = operationId; self.text = text
        self.createdAt = createdAt; self.dispatched = dispatched; self.status = status
        self.images = images; self.retrySource = retrySource; self.files = files
    }
}
public struct CFLLocalImageIdentity: Hashable, Sendable {
    public let sessionId: String, originOperationId: String, draftId: String
}
public struct CFLLocalImagePreview: Equatable, Sendable, Identifiable {
    public var id: CFLLocalImageIdentity { CFLLocalImageIdentity(sessionId: sessionId, originOperationId: originOperationId, draftId: draftId) }
    public let sessionId: String, operationId: String, originOperationId: String, draftId: String
    public let order: Int
    public let attachmentId: String?
    public let data: Data

    public init(sessionId: String, operationId: String, originOperationId: String, draftId: String,
                order: Int, attachmentId: String?, data: Data) {
        self.sessionId = sessionId; self.operationId = operationId; self.originOperationId = originOperationId
        self.draftId = draftId; self.order = order; self.attachmentId = attachmentId; self.data = data
    }
}
public struct CFLLocalDraft: Equatable, Sendable, Identifiable {
    public var id: String { operationId }
    public let sessionId: String, operationId: String, text: String
    public let images: [CFLLocalImagePreview]

    public init(sessionId: String, operationId: String, text: String, images: [CFLLocalImagePreview]) {
        self.sessionId = sessionId; self.operationId = operationId; self.text = text; self.images = images
    }
}
/// The first save failed and its outcome could not be read back. No submit was dispatched.
/// Preserve the input and identity until the pending store can be read again.
public struct CFLPendingStorageUncertain: Error, Sendable {
    public let pending: CFLPending
}
public enum CFLHistoryGapStatus: String, Equatable, Sendable {
    case pending, loading, error, unavailable
}
/// A discontinuity between retained source messages, in the current session.
public struct CFLHistoryGap: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let afterId: String
    public var beforeId: String
    public var status: CFLHistoryGapStatus
}
public struct CFLChatState: Sendable {
    public var connection: CFLConnection = .offline
    public var sessionId: String?
    /// In-memory generation for this client, advanced whenever its session changes.
    /// Pair it with sessionId and the owning client/target when retaining UI work.
    public var sessionRevision: Int = 0
    public var name: String = ""
    public var messages: [CFLMessage] = []
    public var before: String?
    public var historyGaps: [CFLHistoryGap] = []
    public var activeTurnId: String?
    public var streamingReply: CFLStreamingReply?
    public var replyCompletedTurnId: String?
    /// Nil means image upload is unavailable; saved media may still be readable.
    public var imageLimits: CFLImageLimits?
    /// Nil means file intake is unavailable; existing files may still be downloaded.
    public var fileLimits: CFLFileLimits?
    public var recovery: [CFLInputRecovery] = []
    /// Pending records for this client's target, including other sessions.
    public var pending: [CFLPending] = []
    /// Records belonging to other targets; switch back to their origin to reconcile or dismiss.
    public var otherTargetPending: [CFLPending] = []
    /// Ephemeral upload-in-progress messages; never persisted.
    public var localDrafts: [CFLLocalDraft] = []
    /// Validated preview associations, retained until explicitly released.
    public var localPreviews: [CFLLocalImagePreview] = []
    public var historySyncFailed = false
    public var error: CFLFailure?
    public init() {}
}

/// All operations must be durable before they return. A store belongs to one client.
public protocol CFLPendingStore: Sendable {
    func load() async throws -> [CFLPending]
    func save(_ entries: [CFLPending]) async throws
}

/// Caller supplies an application-private file URL; it is never derived from a URL or credential.
public actor CFLFilePendingStore: CFLPendingStore {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> [CFLPending] {
        do { return try JSONDecoder().decode([CFLPending].self, from: Data(contentsOf: file)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
    }
    public func save(_ entries: [CFLPending]) throws {
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Caller-owned temporary snapshots for an active composition or send. The
/// caller removes them once no current in-memory operation needs their bytes.
public enum CFLFileDraftStorage {
    /// Call while the source's security scope and file coordination are active.
    /// The destination directory must be app-private temporary storage.
    public static func copy(source: URL, directory: URL, name: String, mediaType: String,
                            maximumBytes: Int = 100_000_000) throws -> CFLPreparedFile {
        try copy(source: source, directory: directory, name: name, mediaType: mediaType,
                 maximumBytes: maximumBytes, didCopyChunk: nil)
    }
    // Internal observer permits deterministic cancellation tests of a partial copy.
    static func copy(source: URL, directory: URL, name: String, mediaType: String,
                     maximumBytes: Int, didCopyChunk: ((Int) -> Void)?) throws -> CFLPreparedFile {
        try Task.checkCancellation()
        guard source.isFileURL, directory.isFileURL, (0...100_000_000).contains(maximumBytes) else { throw CFLFailure.invalidInput }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= maximumBytes else { throw CFLFailure.invalidInput }
        let id = UUID().uuidString.lowercased()
        guard (1...200).contains(name.unicodeScalars.count), mediaType.unicodeScalars.count <= 255 else { throw CFLFailure.invalidInput }
        let destination = try createEmpty(in: directory)
        do {
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            #if canImport(CryptoKit)
            var hash = SHA256()
            var total = 0
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                try Task.checkCancellation()
                guard chunk.count <= maximumBytes - total else { throw CFLFailure.invalidInput }
                total += chunk.count; hash.update(data: chunk); try output.write(contentsOf: chunk)
                didCopyChunk?(total)
            }
            try Task.checkCancellation()
            guard total == size else { throw CFLFailure.invalidInput }
            try output.synchronize()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            try Task.checkCancellation()
            return CFLPreparedFile(id: id, name: name, mediaType: mediaType, ownedFile: destination, size: total, sha256: digest)
            #else
            throw CFLFailure.requestFailed
            #endif
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    static func createEmpty(in directory: URL) throws -> URL {
        guard directory.isFileURL else { throw CFLFailure.invalidInput }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for _ in 0..<5 {
            let url = directory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: false)
            let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
            if fd >= 0 { _ = close(fd); return url }
            if errno != EEXIST { throw CFLFailure.storage }
        }
        throw CFLFailure.storage
    }
    /// Rechecks the app-owned snapshot in bounded chunks before and after upload.
    static func verify(_ file: CFLPreparedFile) throws {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: file.ownedFileURL)
        defer { try? handle.close() }
        var hash = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard chunk.count <= file.size - count else { throw CFLFailure.invalidInput }
            count += chunk.count; hash.update(data: chunk)
        }
        guard count == file.size, hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw CFLFailure.invalidInput }
        #else
        throw CFLFailure.requestFailed
        #endif
    }
    /// Deletes only the snapshot represented by this prepared file; do not call
    /// while an operation or a draft still needs it.
    public static func remove(_ file: CFLPreparedFile) throws {
        try FileManager.default.removeItem(at: file.ownedFileURL)
    }
}
