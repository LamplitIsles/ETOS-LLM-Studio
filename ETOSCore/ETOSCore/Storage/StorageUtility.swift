// ============================================================================
// StorageUtility.swift
// ============================================================================
// ETOS LLM Studio - 存储管理工具
//
// 功能特性:
// - 计算各类目录的存储空间占用
// - 列出目录中的文件及其详细信息
// - 检测和清理孤立文件
// - 提供缓存清理功能
// ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "StorageUtility")

// MARK: - 存储工具类

public enum StorageUtility {
    private static let resolvedDocumentsDirectory: URL = {
        let fileManager = FileManager.default
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            #if os(macOS)
            // 原生 Mac 客户端可能不启用沙盒；所有相对数据库和附件路径仍保持
            // 移动端布局，只把根目录放入应用专属的 Application Support。
            return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ETOS LLM Studio", isDirectory: true)
            #else
            return fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            #endif
        }

        // 测试不能读写模拟器长期保留的 Documents，否则不同测试运行会相互污染。
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ETOSCoreTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
    
    // MARK: - 目录访问
    
    /// 获取应用数据根目录；macOS 使用 Application Support，移动端使用 Documents。
    public static var documentsDirectory: URL {
        resolvedDocumentsDirectory
    }
    
    /// 获取指定类别的目录 URL
    public static func getDirectory(for category: StorageCategory) -> URL {
        documentsDirectory.appendingPathComponent(category.rawValue)
    }
    
    // MARK: - 大小计算
    
    /// 格式化文件大小
    public static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// 格式化传输进度中的文件大小，固定保留小数位以避免数值变化时文字宽度跳动。
    public static func formatTransferSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.zeroPadsFractionDigits = true
        return formatter.string(fromByteCount: bytes)
    }
    
    /// 计算单个文件或目录的大小
    public static func calculateSize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        
        if isDirectory.boolValue {
            return calculateDirectorySize(url)
        } else {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                return attributes[.size] as? Int64 ?? 0
            } catch {
                logger.warning("Failed to get file size: \(error.localizedDescription)")
                return 0
            }
        }
    }
    
    /// 计算目录总大小（递归）
    public static func calculateDirectorySize(_ directoryURL: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == false {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                logger.warning("Failed to get size for \(fileURL.path): \(error.localizedDescription)")
            }
        }
        
        return totalSize
    }
    
    /// 获取存储统计信息
    public static func getStorageBreakdown() -> StorageBreakdown {
        var breakdown = StorageBreakdown()
        
        // 计算各类别大小
        for category in StorageCategory.allCases {
            let directory = getDirectory(for: category)
            let size = calculateDirectorySize(directory)
            breakdown.categorySize[category] = size
            breakdown.totalSize += size
        }
        
        // 计算其他文件大小（直接在 Documents 根目录的文件）
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
            )
            
            let knownDirectories = Set(StorageCategory.allCases.map { $0.rawValue })
            
            for url in contents {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues.isDirectory == true {
                    if !knownDirectories.contains(url.lastPathComponent) {
                        let size = calculateDirectorySize(url)
                        breakdown.otherSize += size
                        breakdown.totalSize += size
                    }
                } else {
                    let size = Int64(resourceValues.fileSize ?? 0)
                    breakdown.otherSize += size
                    breakdown.totalSize += size
                }
            }
        } catch {
            logger.warning("Failed to scan documents directory: \(error.localizedDescription)")
        }
        
        return breakdown
    }
    
    // MARK: - 文件列表
    
    /// 获取目录中的所有文件（非递归）
    public static func listFiles(in directory: URL) -> [FileItem] {
        let fileManager = FileManager.default
        var items: [FileItem] = []
        
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
            )
            
            for url in contents {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let item = FileItem(url: url, attributes: attributes)
                items.append(item)
            }
        } catch {
            logger.warning("Failed to list files in \(directory.path): \(error.localizedDescription)")
        }
        
        return items.sorted { $0.modificationDate > $1.modificationDate }
    }
    
    /// 获取指定类别的文件列表
    public static func listFiles(for category: StorageCategory) -> [FileItem] {
        let directory = getDirectory(for: category)
        return listFiles(in: directory)
    }
    
    /// 获取 Documents 根目录的内容
    public static func listDocumentsRoot() -> [FileItem] {
        return listFiles(in: documentsDirectory)
    }
    
    // MARK: - 文件操作
    
    /// 删除单个文件
    public static func deleteFile(at url: URL) throws {
        logger.info("Deleting file: \(url.path)")
        try FileManager.default.removeItem(at: url)
        invalidateRelatedCaches(for: url)
        logger.info("File deleted successfully: \(url.lastPathComponent)")
    }
    
    /// 批量删除文件
    public static func deleteFiles(_ urls: [URL]) -> (success: Int, failed: Int) {
        var successCount = 0
        var failedCount = 0
        
        for url in urls {
            do {
                try deleteFile(at: url)
                successCount += 1
            } catch {
                logger.error("Failed to delete \(url.path): \(error.localizedDescription)")
                failedCount += 1
            }
        }
        
        return (successCount, failedCount)
    }
    
    /// 清空指定类别的所有文件
    public static func clearCategory(_ category: StorageCategory) throws {
        let directory = getDirectory(for: category)
        let fileManager = FileManager.default
        
        logger.info("Clearing category: \(category.rawValue)")
        
        let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents {
            try fileManager.removeItem(at: url)
        }

        invalidateRelatedCaches(for: directory)
        
        logger.info("Category cleared: \(category.rawValue)")
    }

    /// 通知共享层某个沙盒文件路径发生了变更，用于刷新相关缓存。
    public static func notifyFilesystemMutation(at url: URL) {
        invalidateRelatedCaches(for: url)
    }
    
    // MARK: - 缓存清理
    
    /// 清理缓存文件（音频和图片文件）
    public static func clearCacheFiles() -> (audioDeleted: Int, imageDeleted: Int) {
        var audioDeleted = 0
        var imageDeleted = 0
        
        // 清理音频缓存
        let audioFiles = listFiles(for: .audio)
        for file in audioFiles {
            do {
                try deleteFile(at: file.url)
                audioDeleted += 1
            } catch {
                logger.error("Failed to delete audio file: \(error.localizedDescription)")
            }
        }
        
        // 清理图片缓存
        let imageFiles = listFiles(for: .images)
        for file in imageFiles {
            do {
                try deleteFile(at: file.url)
                imageDeleted += 1
            } catch {
                logger.error("Failed to delete image file: \(error.localizedDescription)")
            }
        }
        
        return (audioDeleted, imageDeleted)
    }
    
    // MARK: - 统一清理
    
    /// 清理摘要
    public struct CleanupSummary {
        public let orphanedAudioFilesCleaned: Int
        public let orphanedImageFilesCleaned: Int
        
        public var totalCleaned: Int {
            orphanedAudioFilesCleaned + orphanedImageFilesCleaned
        }
        
        public var description: String {
            var parts: [String] = []
            if orphanedAudioFilesCleaned > 0 {
                parts.append(
                    String(
                        format: NSLocalizedString("%d 个孤立音频", comment: "Cleaned orphaned audio count"),
                        orphanedAudioFilesCleaned
                    )
                )
            }
            if orphanedImageFilesCleaned > 0 {
                parts.append(
                    String(
                        format: NSLocalizedString("%d 个孤立图片", comment: "Cleaned orphaned image count"),
                        orphanedImageFilesCleaned
                    )
                )
            }
            return parts.isEmpty
                ? NSLocalizedString("没有需要清理的内容", comment: "No orphaned data needed cleanup")
                : parts.joined(separator: NSLocalizedString("、", comment: "Localized list separator"))
        }
    }
    
    /// 检测所有孤立数据的数量
    public struct OrphanedDataCount {
        public let orphanedAudioFiles: Int
        public let orphanedImageFiles: Int
        
        public init(orphanedAudioFiles: Int = 0, orphanedImageFiles: Int = 0) {
            self.orphanedAudioFiles = orphanedAudioFiles
            self.orphanedImageFiles = orphanedImageFiles
        }
        
        public var total: Int {
            orphanedAudioFiles + orphanedImageFiles
        }
        
        public var description: String {
            var parts: [String] = []
            if orphanedAudioFiles > 0 {
                parts.append(
                    String(
                        format: NSLocalizedString("%d 个孤立音频", comment: "Orphaned audio count"),
                        orphanedAudioFiles
                    )
                )
            }
            if orphanedImageFiles > 0 {
                parts.append(
                    String(
                        format: NSLocalizedString("%d 个孤立图片", comment: "Orphaned image count"),
                        orphanedImageFiles
                    )
                )
            }
            return parts.isEmpty
                ? NSLocalizedString("无孤立数据", comment: "No orphaned data")
                : parts.joined(separator: NSLocalizedString("、", comment: "Localized list separator"))
        }
    }
    
    // MARK: - JSON 文件预览
    
    /// 读取 JSON 文件内容（用于预览）
    public static func readJSONFile(at url: URL) -> String? {
        do {
            let data = try Data(contentsOf: url)
            let jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if JSONSerialization.isValidJSONObject(jsonObject) {
                let prettyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys])
                return String(data: prettyData, encoding: .utf8)
            }
            return String(data: data, encoding: .utf8)
        } catch {
            logger.warning("Failed to read JSON file: \(error.localizedDescription)")
            return nil
        }
    }

    private static func invalidateRelatedCaches(for url: URL) {
        ETOSSharedWorkspaceFiles.notifyChange()
        let skillDirectory = getDirectory(for: .skills).standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let isSkillPath = targetPath == skillDirectory || targetPath.hasPrefix(skillDirectory + "/")

        if isSkillPath {
            Task { @MainActor in
                #if os(macOS)
                let manager = await SkillManager.prepareSharedInBackground()
                try? await manager.reloadLibraryInBackground()
                #else
                SkillManager.shared.reloadFromDisk()
                #endif
            }
        }
    }
}
