// ============================================================================
// PersistenceStorePaths.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 的目录、路径、时间戳、legacy 迁移与兼容提醒辅助。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    /// 获取用于存储聊天记录的目录URL
    /// - Returns: 存储目录的URL路径
    public static func getChatsDirectory() -> URL {
        let chatsDirectory = StorageUtility.documentsDirectory.appendingPathComponent("ChatSessions")
        if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
            logger.info("Chat history directory does not exist, creating: \(chatsDirectory.path)")
            try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        }
        return chatsDirectory
    }

    static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeSQLiteSidecars(at url: URL) {
        let fileManager = FileManager.default
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"
        if fileManager.fileExists(atPath: walPath) {
            try? fileManager.removeItem(atPath: walPath)
        }
        if fileManager.fileExists(atPath: shmPath) {
            try? fileManager.removeItem(atPath: shmPath)
        }
    }

    static func ensureDirectoryExists(_ directoryURL: URL) throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    static func requestLogsDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(requestLogsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func dailyPulseDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(dailyPulseDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func requestLogsFileURL() -> URL {
        requestLogsDirectoryURL().appendingPathComponent(requestLogsFileName)
    }

    static func effectiveRequestLogRetentionLimit() -> Int {
        max(requestLogRetentionLimitOverride ?? defaultRequestLogRetentionLimit, 1)
    }

    static func dailyPulseRunsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseRunsFileName)
    }

    static func dailyPulseFeedbackHistoryFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseFeedbackHistoryFileName)
    }

    static func dailyPulsePendingCurationFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulsePendingCurationFileName)
    }

    static func dailyPulseExternalSignalsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseExternalSignalsFileName)
    }

    static func dailyPulseTasksFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseTasksFileName)
    }

    static func dailyPulseGenerationRuntimeFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseGenerationRuntimeFileName)
    }

    static func iso8601Timestamp() -> String {
        iso8601Timestamp(from: Date())
    }

    static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
