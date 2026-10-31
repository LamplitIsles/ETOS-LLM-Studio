// ============================================================================
// ThirdPartyImportETOS.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责解析 ETOS 原生导出的同步数据包。
// ============================================================================

import Foundation

extension ThirdPartyImportService {
    static func parseETOSBackup(fileURL: URL) throws -> SyncPackage {
        let rootURL: URL
        if isDirectory(fileURL) {
            guard let foundURL = findETOSPackageFile(inDirectory: fileURL) else {
                throw ThirdPartyImportError.noImportableContent
            }
            rootURL = foundURL
        } else {
            rootURL = fileURL
        }

        if isETOSSnapshotFile(rootURL) {
            throw ThirdPartyImportError.invalidJSON
        }

        if isLikelyCompressedBackup(rootURL) {
            throw ThirdPartyImportError.invalidJSON
        }

        guard let data = try? Data(contentsOf: rootURL) else {
            throw ThirdPartyImportError.fileNotReadable
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw ThirdPartyImportError.invalidJSON
        }

        guard let package = try? SyncPackageTransferService.decodePackage(from: data) else {
            throw ThirdPartyImportError.noImportableContent
        }
        guard !package.options.isEmpty else {
            throw ThirdPartyImportError.noImportableContent
        }
        return package
    }

    static func findETOSPackageFile(inDirectory directoryURL: URL) -> URL? {
        guard isDirectory(directoryURL) else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var firstJSON: URL?
        while let fileURL = enumerator?.nextObject() as? URL {
            if isDirectory(fileURL) { continue }
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            if fileURL.lastPathComponent.hasPrefix("ETOS-数据导出-") {
                firstJSON = fileURL
                continue
            }
            firstJSON = firstJSON ?? fileURL
        }

        return firstJSON
    }

    static func isETOSSnapshotFile(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == SnapshotBuilder.fileExtension
    }
}
