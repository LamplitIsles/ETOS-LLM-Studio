// ============================================================================
// SystemEntrySharedModels.swift
// ETOS LLM Studio
// ============================================================================

import Foundation

public enum ETOSSystemEntryConstants {
    public static let appGroupIdentifier = "group.com.ericterminal.els"
    public static let appURLScheme = "etosllmstudio"
    public static let maximumInboxRequestBytes = 32 * 1_024 * 1_024
    public static let maximumInboxItemCount = 32
}

public struct ETOSSharedStorageLayout: Sendable {
    public let container: URL
    public let inbox: URL
    public let shared: URL
    public let exports: URL
    public let receipts: URL
    public let staging: URL

    public init(container: URL) {
        self.container = container
        inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        shared = container.appendingPathComponent("Shared", isDirectory: true)
        exports = container.appendingPathComponent("Exports", isDirectory: true)
        receipts = container.appendingPathComponent("Receipts", isDirectory: true)
        staging = container.appendingPathComponent("Staging", isDirectory: true)
    }

    public static func resolve(fileManager: FileManager = .default) -> ETOSSharedStorageLayout? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ETOSSystemEntryConstants.appGroupIdentifier
        ).map(ETOSSharedStorageLayout.init(container:))
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [inbox, shared, exports, receipts, staging] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// Validate filenames used by the shared inbox.
public enum ETOSSharedWorkspacePathValidator {
    public static func fileName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              (trimmed as NSString).lastPathComponent == trimmed,
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return String(trimmed.prefix(255))
    }
}

public enum ETOSInboxMode: String, Codable, CaseIterable, Sendable {
    case chat
    case agent
}

public enum ETOSInboxItemKind: String, Codable, Sendable {
    case text
    case url
    case image
    case audio
    case file
}

public struct ETOSInboxItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ETOSInboxItemKind
    public let displayName: String
    public let relativeFilePath: String?
    public let text: String?
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        kind: ETOSInboxItemKind,
        displayName: String,
        relativeFilePath: String? = nil,
        text: String? = nil,
        byteCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.displayName = String(displayName.prefix(160))
        self.relativeFilePath = relativeFilePath
        self.text = text.map { String($0.prefix(16_000)) }
        self.byteCount = max(0, byteCount)
    }
}

public struct ETOSInboxRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let mode: ETOSInboxMode
    public let preferredSessionID: UUID?
    public let items: [ETOSInboxItem]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: ETOSInboxMode,
        preferredSessionID: UUID? = nil,
        items: [ETOSInboxItem]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.preferredSessionID = preferredSessionID
        self.items = Array(items.prefix(ETOSSystemEntryConstants.maximumInboxItemCount))
    }
}

public struct ETOSInboxPayloadItem: Sendable {
    public let item: ETOSInboxItem
    public let data: Data?

    public init(item: ETOSInboxItem, data: Data?) {
        self.item = item
        self.data = data
    }
}

public enum ETOSInboxStore {
    public static func persist(
        payloads: [ETOSInboxPayloadItem],
        mode: ETOSInboxMode,
        preferredSessionID: UUID?,
        requestID: UUID = UUID(),
        layout providedLayout: ETOSSharedStorageLayout? = nil,
        fileManager: FileManager = .default
    ) throws -> ETOSInboxRequest {
        guard payloads.count <= ETOSSystemEntryConstants.maximumInboxItemCount else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let totalBytes = payloads.reduce(0) { partial, payload in
            partial + (payload.data?.count ?? payload.item.byteCount)
        }
        guard totalBytes <= ETOSSystemEntryConstants.maximumInboxRequestBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard let layout = providedLayout ?? ETOSSharedStorageLayout.resolve(fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try layout.prepare(fileManager: fileManager)
        let destination = layout.inbox.appendingPathComponent(requestID.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            return try load(requestID: requestID, layout: layout, fileManager: fileManager)
        }

        let stagedDirectory = layout.staging.appendingPathComponent(requestID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        defer {
            if fileManager.fileExists(atPath: stagedDirectory.path) {
                try? fileManager.removeItem(at: stagedDirectory)
            }
        }

        var persistedItems: [ETOSInboxItem] = []
        for (index, payload) in payloads.enumerated() {
            guard let data = payload.data else {
                persistedItems.append(payload.item)
                continue
            }
            let sourceName = (payload.item.displayName as NSString).lastPathComponent
            let fallbackName = sourceName.isEmpty ? "item-\(index + 1)" : sourceName
            let fileName = try ETOSSharedWorkspacePathValidator.fileName("\(index + 1)-\(fallbackName)")
            try data.write(
                to: stagedDirectory.appendingPathComponent(fileName),
                options: [.atomic, .completeFileProtection]
            )
            persistedItems.append(
                ETOSInboxItem(
                    id: payload.item.id,
                    kind: payload.item.kind,
                    displayName: payload.item.displayName,
                    relativeFilePath: "\(requestID.uuidString)/\(fileName)",
                    byteCount: data.count
                )
            )
        }
        let request = ETOSInboxRequest(
            id: requestID,
            mode: mode,
            preferredSessionID: preferredSessionID,
            items: persistedItems
        )
        try ETOSSharedFileStore.write(
            request,
            to: stagedDirectory.appendingPathComponent("request.json"),
            fileManager: fileManager
        )
        try fileManager.moveItem(at: stagedDirectory, to: destination)
        return try load(requestID: requestID, layout: layout, fileManager: fileManager)
    }

    public static func load(
        requestID: UUID,
        layout providedLayout: ETOSSharedStorageLayout? = nil,
        fileManager: FileManager = .default
    ) throws -> ETOSInboxRequest {
        guard let layout = providedLayout ?? ETOSSharedStorageLayout.resolve(fileManager: fileManager) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = layout.inbox.appendingPathComponent(requestID.uuidString, isDirectory: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let request = try ETOSSharedFileStore.read(
            ETOSInboxRequest.self,
            from: directory.appendingPathComponent("request.json"),
            maximumBytes: 256 * 1_024
        )
        guard request.id == requestID else { throw CocoaError(.fileReadCorruptFile) }
        return request
    }
}

public enum ETOSSystemEntryRequestKind: String, Codable, Sendable {
    case appIntent
    case shareExtension = "share_extension"
    case deepLink = "deep_link"
}

public struct ETOSSystemEntryReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ETOSSystemEntryRequestKind
    public let sessionID: UUID?
    public let createdAt: Date

    public init(id: UUID, kind: ETOSSystemEntryRequestKind, sessionID: UUID?, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.createdAt = createdAt
    }
}

public enum ETOSSharedFileStore {
    public static func write<T: Encodable>(
        _ value: T,
        to destination: URL,
        fileProtection: Data.WritingOptions = .completeFileProtection,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).staging")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try encoder.encode(value).write(to: staging, options: fileProtection)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    public static func read<T: Decodable>(
        _ type: T.Type,
        from source: URL,
        maximumBytes: Int = 1_024 * 1_024
    ) throws -> T {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: source, options: .mappedIfSafe))
    }
}

public enum ETOSSystemEntryURL {
    public static func openSession(_ sessionID: UUID) -> URL {
        URL(string: "\(ETOSSystemEntryConstants.appURLScheme)://open/session/\(sessionID.uuidString)")!
    }

    public static func openMemory(_ memoryID: UUID) -> URL {
        URL(string: "\(ETOSSystemEntryConstants.appURLScheme)://open/memory/\(memoryID.uuidString)")!
    }

    public static func openBrowser(sessionID: UUID? = nil) -> URL {
        routeURL(component: "browser", id: sessionID)
    }

    public static func openTerminal(sessionID: UUID? = nil) -> URL {
        routeURL(component: "terminal", id: sessionID)
    }

    public static func consumeInbox(_ requestID: UUID) -> URL {
        URL(string: "\(ETOSSystemEntryConstants.appURLScheme)://inbox/\(requestID.uuidString)")!
    }

    private static func routeURL(component: String, id: UUID?) -> URL {
        var components = URLComponents()
        components.scheme = ETOSSystemEntryConstants.appURLScheme
        components.host = "open"
        components.path = "/\(component)"
        if let id { components.queryItems = [URLQueryItem(name: "session", value: id.uuidString)] }
        return components.url!
    }
}
