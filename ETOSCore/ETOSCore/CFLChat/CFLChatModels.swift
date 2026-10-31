import Foundation
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
    /// Milliseconds since the Unix epoch, as provided by the shared contract.
    public let createdAt: Double
    public let operationId: String?
    public let turnId: String?
}
public struct CFLStreamingReply: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let turnId: String?
    /// Milliseconds since the Unix epoch, as provided by the shared contract.
    public let createdAt: Double
    public let text: String
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
}
public enum CFLConnection: Equatable, Sendable { case offline, connecting, online, accessDenied, protocolError }
public enum CFLFailure: Error, Equatable, Sendable { case offline, accessDenied, invalidInput, storage, protocolError, requestFailed, sessionChanged }
public enum CFLPendingStatus: String, Codable, Equatable, Sendable { case unknown, submitted, failed }
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
}
/// The first save failed and its outcome could not be read back. No submit was dispatched.
/// Preserve the input and identity until the pending store can be read again.
public struct CFLPendingStorageUncertain: Error, Sendable {
    public let pending: CFLPending
}
public struct CFLChatState: Sendable {
    public var connection: CFLConnection = .offline
    public var sessionId: String?
    public var name: String = ""
    public var messages: [CFLMessage] = []
    public var before: String?
    public var activeTurnId: String?
    public var streamingReply: CFLStreamingReply?
    public var replyCompletedTurnId: String?
    /// Pending records for this client's target, including other sessions.
    public var pending: [CFLPending] = []
    /// Records belonging to other targets; switch back to their origin to reconcile or dismiss.
    public var otherTargetPending: [CFLPending] = []
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
