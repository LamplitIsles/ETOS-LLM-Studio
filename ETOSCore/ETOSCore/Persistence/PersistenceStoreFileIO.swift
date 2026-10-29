// ============================================================================
// PersistenceStoreFileIO.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 请求日志文件的底层读写辅助。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    static func loadRequestLogEnvelope() throws -> RequestLogFileEnvelope? {
        let fileURL = requestLogsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RequestLogFileEnvelope.self, from: data)
    }

    static func writeRequestLogEnvelope(_ envelope: RequestLogFileEnvelope) throws {
        let fileURL = requestLogsFileURL()
        try ensureDirectoryExists(fileURL.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

}
