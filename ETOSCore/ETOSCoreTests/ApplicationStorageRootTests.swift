// ============================================================================
// ApplicationStorageRootTests.swift
// ============================================================================
// 数据库、浏览器文件、本地权重和调试传输必须共享应用根目录，保证跨端备份
// 中的相对路径在 macOS Application Support 下仍可解析。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("跨平台应用存储目录")
struct ApplicationStorageRootTests {
    @Test("本地权重与会话存储位于同一个应用数据根目录")
    func localModelsShareChatRoot() {
        let root = StorageUtility.documentsDirectory.standardizedFileURL
        #expect(LocalModelStore.localModelsDirectoryURL().deletingLastPathComponent().standardizedFileURL == root)
        #expect(Persistence.getChatsDirectory().deletingLastPathComponent().standardizedFileURL == root)
    }

}
