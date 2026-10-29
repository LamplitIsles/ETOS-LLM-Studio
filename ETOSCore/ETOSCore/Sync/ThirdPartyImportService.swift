// ============================================================================
// ThirdPartyImportService.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责第三方导入的公共入口与同步包组装。
// ============================================================================

import Foundation

public enum ThirdPartyImportSource: String, CaseIterable, Codable, Sendable {
    case etosBackup
    case cherryStudio
    case rikkahub
    case kelivo
    case chatbox
    case openMinis

    public var displayName: String {
        switch self {
        case .etosBackup: return NSLocalizedString("ETOS 数据包", comment: "Third-party import source")
        case .cherryStudio: return "Cherry Studio"
        case .rikkahub: return "RikkaHub"
        case .kelivo: return "Kelivo"
        case .chatbox: return "ChatBox"
        case .openMinis: return "OpenMinis"
        }
    }

    public var suggestedFileExtensions: [String] {
        switch self {
        case .etosBackup:
            return [SnapshotBuilder.fileExtension, "json"]
        case .cherryStudio:
            return ["json", "zip", "bak"]
        case .rikkahub:
            return ["json", "zip"]
        case .kelivo:
            return ["json", "zip"]
        case .chatbox:
            return ["json"]
        case .openMinis:
            return ["json", "zip"]
        }
    }
}

public struct ThirdPartyImportPreparedResult {
    public var source: ThirdPartyImportSource
    public var package: SyncPackage
    public var warnings: [String]
    public var recognizedSkillNames: [String]
    public var containsSensitiveCredentials: Bool

    public init(
        source: ThirdPartyImportSource,
        package: SyncPackage,
        warnings: [String] = [],
        recognizedSkillNames: [String] = [],
        containsSensitiveCredentials: Bool = false
    ) {
        self.source = source
        self.package = package
        self.warnings = warnings
        self.recognizedSkillNames = recognizedSkillNames
        self.containsSensitiveCredentials = containsSensitiveCredentials
    }

    public var parsedProvidersCount: Int { package.providers.count }
    public var parsedSkillsCount: Int { package.skills.count }
}

public struct ThirdPartyImportReport {
    public var source: ThirdPartyImportSource
    public var parsedProvidersCount: Int
    public var summary: SyncMergeSummary
    public var warnings: [String]

    public init(
        source: ThirdPartyImportSource,
        parsedProvidersCount: Int,
        summary: SyncMergeSummary,
        warnings: [String] = []
    ) {
        self.source = source
        self.parsedProvidersCount = parsedProvidersCount
        self.summary = summary
        self.warnings = warnings
    }
}

public enum ThirdPartyImportError: LocalizedError {
    case fileNotReadable
    case invalidJSON
    case unsupportedBackupFormat(reason: String)
    case noImportableContent

    public var errorDescription: String? {
        switch self {
        case .fileNotReadable:
            return NSLocalizedString("无法读取所选文件。", comment: "")
        case .invalidJSON:
            return NSLocalizedString("文件不是有效的 JSON 数据。", comment: "")
        case .unsupportedBackupFormat(let reason):
            return reason
        case .noImportableContent:
            return NSLocalizedString("未解析到可导入的内容。", comment: "")
        }
    }
}

public enum ThirdPartyImportService {
    public static func prepareImport(
        source: ThirdPartyImportSource,
        fileURLs: [URL]
    ) throws -> ThirdPartyImportPreparedResult {
        guard let first = fileURLs.first else { throw ThirdPartyImportError.fileNotReadable }
        guard fileURLs.count > 1 else { return try prepareImport(source: source, fileURL: first) }
        guard source == .openMinis else { return try prepareImport(source: source, fileURL: first) }

        let prepared = try fileURLs.map { try prepareImport(source: source, fileURL: $0) }
        var providerIDs = Set<UUID>()
        var skillNames = Set<String>()
        let providers = prepared.flatMap(\.package.providers).filter { providerIDs.insert($0.id).inserted }
        let skills = prepared.flatMap(\.package.skills).filter { skillNames.insert($0.name).inserted }
        var options: SyncOptions = []
        if !providers.isEmpty { options.insert(.providers) }
        if !skills.isEmpty { options.insert(.skills) }
        return ThirdPartyImportPreparedResult(
            source: source,
            package: SyncPackage(
                options: options,
                sourcePlatform: "OpenMinis",
                providers: providers,
                skills: skills
            ),
            warnings: Array(Set(prepared.flatMap(\.warnings))).sorted(),
            recognizedSkillNames: Array(Set(prepared.flatMap(\.recognizedSkillNames))).sorted(),
            containsSensitiveCredentials: prepared.contains(where: \.containsSensitiveCredentials)
        )
    }

    public static func prepareImport(
        source: ThirdPartyImportSource,
        fileURL: URL
    ) throws -> ThirdPartyImportPreparedResult {
        try withSecurityScopedAccess(to: fileURL) {
            if source == .etosBackup {
                let package = try parseETOSBackup(fileURL: fileURL)
                return ThirdPartyImportPreparedResult(
                    source: source,
                    package: package,
                    warnings: []
                )
            }

            if source == .openMinis {
                let parsed = try parseOpenMinis(fileURL: fileURL)
                var options: SyncOptions = []
                if !parsed.payload.providers.isEmpty { options.insert(.providers) }
                if !parsed.skills.isEmpty { options.insert(.skills) }
                let package = SyncPackage(
                    options: options,
                    sourcePlatform: "OpenMinis",
                    providers: parsed.payload.providers,
                    skills: parsed.skills
                )
                return ThirdPartyImportPreparedResult(
                    source: source,
                    package: package,
                    warnings: parsed.payload.warnings,
                    recognizedSkillNames: parsed.recognizedSkillNames,
                    containsSensitiveCredentials: parsed.containsSensitiveCredentials
                )
            }

            let parsed: ParsedPayload
            switch source {
            case .cherryStudio:
                parsed = try parseCherryStudio(fileURL: fileURL)
            case .rikkahub:
                parsed = try parseRikkaHub(fileURL: fileURL)
            case .kelivo:
                parsed = try parseKelivo(fileURL: fileURL)
            case .chatbox:
                parsed = try parseChatBox(fileURL: fileURL)
            case .openMinis:
                throw ThirdPartyImportError.unsupportedBackupFormat(reason: NSLocalizedString("导入来源未实现。", comment: "Third-party import unsupported source error"))
            case .etosBackup:
                // 已在前置分支返回，这里仅为穷尽匹配。
                throw ThirdPartyImportError.unsupportedBackupFormat(reason: NSLocalizedString("导入来源未实现。", comment: "Third-party import unsupported source error"))
            }

            let package = try makePackage(from: parsed)
            return ThirdPartyImportPreparedResult(
                source: source,
                package: package,
                warnings: parsed.warnings
            )
        }
    }

    public static func prepareImportInBackground(
        source: ThirdPartyImportSource,
        fileURL: URL
    ) async throws -> ThirdPartyImportPreparedResult {
        try await Task.detached(priority: .userInitiated) {
            try prepareImport(source: source, fileURL: fileURL)
        }.value
    }

    public static func prepareImportInBackground(
        source: ThirdPartyImportSource,
        fileURLs: [URL]
    ) async throws -> ThirdPartyImportPreparedResult {
        try await Task.detached(priority: .userInitiated) {
            try prepareImport(source: source, fileURLs: fileURLs)
        }.value
    }

    @discardableResult
    public static func importAndApply(
        source: ThirdPartyImportSource,
        fileURL: URL,
        chatService: ChatService = .shared,
        userDefaults: UserDefaults = .standard
    ) async throws -> ThirdPartyImportReport {
        let prepared = try await prepareImportInBackground(source: source, fileURL: fileURL)
        let summary = await Task.detached(priority: .userInitiated) {
            await SyncEngine.apply(
                package: prepared.package,
                chatService: chatService,
                userDefaults: userDefaults
            )
        }.value
        return ThirdPartyImportReport(
            source: source,
            parsedProvidersCount: prepared.parsedProvidersCount,
            summary: summary,
            warnings: prepared.warnings
        )
    }
}

extension ThirdPartyImportService {
    struct ParsedPayload {
        var providers: [Provider]
        var warnings: [String]
    }

    static func makePackage(from parsed: ParsedPayload) throws -> SyncPackage {
        var options: SyncOptions = []
        if !parsed.providers.isEmpty {
            options.insert(.providers)
        }
        guard !options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return SyncPackage(
            options: options,
            providers: parsed.providers
        )
    }
}
