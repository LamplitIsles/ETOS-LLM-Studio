// ============================================================================
// SystemEntryInfrastructureTests.swift
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("系统入口基础设施测试", .serialized)
struct SystemEntryInfrastructureTests {
    @Test("普通通知遵守前台静默设置")
    func nonReplyForegroundPolicyIsPreserved() {
        #expect(AppLocalNotificationCenter.notificationShouldPresentWhileForeground(userInfo: [:]))
        #expect(!AppLocalNotificationCenter.notificationShouldPresentWhileForeground(
            userInfo: ["suppress_when_foreground": true]
        ))
    }

    @Test("分享文件名拒绝越界")
    func workspacePathBoundary() throws {
        #expect(throws: Error.self) {
            _ = try ETOSSharedWorkspacePathValidator.fileName("../secret.txt")
        }
    }

    @Test("分享收件箱整包发布并对重复请求保持幂等")
    func shareInboxCommitIsAtomicAndIdempotent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ETOSSharedStorageLayout(container: root)
        let requestID = UUID()
        let payloads = [
            ETOSInboxPayloadItem(
                item: ETOSInboxItem(kind: .text, displayName: "说明", text: "请整理附件", byteCount: 18),
                data: nil
            ),
            ETOSInboxPayloadItem(
                item: ETOSInboxItem(kind: .file, displayName: "../资料.txt", byteCount: 4),
                data: Data("data".utf8)
            )
        ]

        let first = try ETOSInboxStore.persist(
            payloads: payloads,
            mode: .agent,
            preferredSessionID: nil,
            requestID: requestID,
            layout: layout
        )
        let duplicate = try ETOSInboxStore.persist(
            payloads: payloads,
            mode: .agent,
            preferredSessionID: nil,
            requestID: requestID,
            layout: layout
        )
        let restored = try ETOSInboxStore.load(requestID: requestID, layout: layout)
        let relativePath = try #require(restored.items.last?.relativeFilePath)

        #expect(first == duplicate)
        #expect(restored == first)
        #expect(relativePath == "\(requestID.uuidString)/2-资料.txt")
        #expect(FileManager.default.fileExists(
            atPath: layout.inbox.appendingPathComponent(relativePath).path
        ))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: layout.staging.path))?.isEmpty == true)
    }

    @Test("外部请求回执只能领取一次并保留首次会话")
    func systemEntryReceiptIsIdempotent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try PersistenceGRDBStore(chatsDirectory: root)
        let requestID = UUID()
        let firstSessionID = UUID()

        #expect(try store.claimSystemEntryRequest(id: requestID, kind: .appIntent))
        #expect(try !store.claimSystemEntryRequest(id: requestID, kind: .appIntent))
        try store.saveSystemEntryReceipt(
            ETOSSystemEntryReceipt(id: requestID, kind: .appIntent, sessionID: firstSessionID)
        )
        try store.saveSystemEntryReceipt(
            ETOSSystemEntryReceipt(id: requestID, kind: .appIntent, sessionID: UUID())
        )

        let loadedReceipt = try store.loadSystemEntryReceipt(id: requestID)
        let receipt = try #require(loadedReceipt)
        #expect(receipt.sessionID == firstSessionID)
        #expect(receipt.kind == .appIntent)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-system-entry-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
