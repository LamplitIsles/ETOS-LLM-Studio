// ============================================================================
// ThirdPartyImportETOSTests.swift
// ============================================================================
// ThirdPartyImportService ETOS 数据包导入测试
// - 验证 ETOS 导出信封可解析并保留完整 options
// - 验证兼容旧版纯 SyncPackage JSON
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("导入数据 ETOS 兼容测试")
struct ThirdPartyImportETOSTests {

    @Test("ETOS 导出信封可解析为全量同步包")
    func testPrepareETOSImportFromEnvelope() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let provider = Provider(
            id: UUID(),
            name: "ETOS Provider",
            baseURL: "https://api.etos.dev",
            apiKeys: ["etos-key"],
            apiFormat: "openai-compatible",
            models: [Model(modelName: "etos-model", displayName: "ETOS Model", isActivated: true)]
        )
        let snapshot = Data([0x10, 0x20, 0x30])
        let package = SyncPackage(
            options: [.providers, .appStorage],
            providers: [provider],
            appStorageSnapshot: snapshot
        )

        let exported = try SyncPackageTransferService.exportPackage(package)
        let fileURL = sandbox.appendingPathComponent(exported.suggestedFileName)
        try exported.data.write(to: fileURL)

        let prepared = try ThirdPartyImportService.prepareImport(
            source: .etosBackup,
            fileURL: fileURL
        )

        #expect(prepared.package.options.contains(.providers))
        #expect(prepared.package.options.contains(.appStorage))
        #expect(prepared.package.providers.count == 1)
        #expect(prepared.package.providers[0].name == "ETOS Provider")
        #expect(prepared.package.appStorageSnapshot == snapshot)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("ETOS 导入拒绝快照并只建议 JSON 文件")
    func snapshotsAreRejectedBeforeReading() {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("backup.ELSBACKUP")
        #expect(ThirdPartyImportSource.etosBackup.suggestedFileExtensions == ["json"])
        do {
            _ = try ThirdPartyImportService.prepareImport(source: .etosBackup, fileURL: file)
            Issue.record("快照不应被导入")
        } catch ThirdPartyImportError.invalidJSON {
        } catch {
            Issue.record("快照应在尝试读取前被拒绝")
        }
    }

    @Test("目录导入忽略快照并选择 JSON 数据包")
    func directoryImportIgnoresSnapshots() throws {
        let sandbox = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let snapshot = sandbox.appendingPathComponent("ETOS-Snapshot-directory.elsbackup")
        let content = Data("目录中的快照".utf8)
        try content.write(to: snapshot)
        #expect(throws: ThirdPartyImportError.self) {
            try ThirdPartyImportService.prepareImport(source: .etosBackup, fileURL: sandbox)
        }
        let package = SyncPackage(options: [.providers], providers: [
            Provider(name: "Directory Provider", baseURL: "https://example.invalid", apiKeys: [], apiFormat: "openai-compatible")
        ])
        let exported = try SyncPackageTransferService.exportPackage(package)
        try exported.data.write(to: sandbox.appendingPathComponent(exported.suggestedFileName))

        let prepared = try ThirdPartyImportService.prepareImport(source: .etosBackup, fileURL: sandbox)
        #expect(prepared.package.providers.first?.name == "Directory Provider")
        #expect(try Data(contentsOf: snapshot) == content)
    }
}
