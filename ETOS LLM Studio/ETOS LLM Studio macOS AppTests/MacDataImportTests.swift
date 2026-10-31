import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacDataImportTests {
    @Test("第三方导入只包含选中的提供商")
    func scopedPackageKeepsSelectedProviders() throws {
        let package = SyncPackage(options: [.providers, .imageFiles], sourcePlatform: "OpenMinis",
            providers: [provider()], imageFiles: [SyncedImage(filename: "photo.png", data: Data([2]))])
        let result = try MacDataImportPreview.scopedPackage(prepared(package), selection: [.providers])
        #expect(result.options == .providers)
        #expect(result.providers.count == 1)
        #expect(result.imageFiles.isEmpty)
        #expect(result.sourcePlatform == "OpenMinis")
    }

    @Test("未导出的类别和空选择不能进入合并")
    func invalidScopesAreRejected() {
        let item = prepared(SyncPackage(options: .imageFiles, providers: [provider()]))
        let selections: [Set<MacDataImportCategory>] = [[], [.providers], [.appStorage]]
        for selection in selections {
            #expect(throws: ThirdPartyImportError.self) { try MacDataImportPreview.scopedPackage(item, selection: selection) }
        }
    }

    @Test("ETOS 数据包保留完整导出范围和设置")
    func etosPackagePreservesExportedOptions() throws {
        let package = SyncPackage(options: .fullSync, sourcePlatform: "iOS", appStorageSnapshot: Data([7]))
        let prepared = ThirdPartyImportPreparedResult(source: .etosBackup, package: package)
        let result = try MacDataImportPreview.scopedPackage(prepared, selection: [])
        #expect(result.options == .fullSync)
        #expect(result.appStorageSnapshot == package.appStorageSnapshot)
        #expect(MacDataImportPreview(prepared: prepared).requiresCredentialAcknowledgement(selection: []))
    }

    @Test("提供商凭据和自定义头需要确认")
    func credentialsGateTracksSelectedScope() {
        let package = SyncPackage(options: .providers, providers: [provider()])
        let preview = MacDataImportPreview(prepared: prepared(package))
        #expect(preview.requiresCredentialAcknowledgement(selection: [.providers]))
        #expect(!preview.requiresCredentialAcknowledgement(selection: []))
        var headersOnly = provider()
        headersOnly.apiKeys = []
        headersOnly.headerOverrides = ["Authorization": "private"]
        let headerPreview = MacDataImportPreview(prepared: prepared(SyncPackage(options: .providers, providers: [headersOnly])))
        #expect(headerPreview.requiresCredentialAcknowledgement(selection: [.providers]))
    }

    @Test("导入摘要只展示数量，不包含配置内容")
    func previewGuideContainsCountsOnly() {
        let item = ThirdPartyImportPreparedResult(source: .openMinis,
            package: SyncPackage(options: .providers, providers: [provider()]),
            warnings: ["private-warning"], recognizedSkillNames: ["private-skill"], containsSensitiveCredentials: true)
        let state = MacDataImportPreview(prepared: item, conflicts: MacDataImportConflicts(providers: 1))
        #expect(state.rows.first(where: { $0.id == "provider_adds" })?.value == "0")
        #expect(state.warnings.first?.title == "private-warning")
        guard case .dictionary(let fields) = state.guideCounts else { Issue.record("缺少计数快照"); return }
        #expect(fields["warnings"] == .int(1))
        for value in fields.values {
            guard case .int = value else { Issue.record("计数快照包含非数值内容"); continue }
        }
        #expect(state.scopeRows == [.providers])
    }

    @Test("合并报告包含已导入类别和字体配置")
    func reportUsesCompleteCoreSummary() {
        let summary = SyncMergeSummary(importedProviders: 1, importedImageFiles: 3,
            importedFontFiles: 4, importedFontRouteConfigurations: 2, importedAppStorageValues: 5)
        let report = MacDataImportReport(summary: summary, options: .fullSync, warnings: ["保留提示"])
        #expect(Set(report.rows.map(\.id)) == Set(MacDataImportCategory.allCases.map(\.rawValue)))
        guard case .dictionary(let fields) = report.guideSummary else { Issue.record("缺少报告快照"); return }
        #expect(fields["fontFiles"] == .dictionary(["imported": .int(6), "skipped": .int(0)]))
        #expect(report.warnings.first?.title == "保留提示")
    }

    @Test("已确认写入不随调用者取消，并阻止重入")
    @MainActor
    func acceptedWriteOutlivesCallerCancellation() async throws {
        let operations = MacDataImportOperations()
        let started = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        let caller = Task {
            try await operations.perform {
                started.continuation.yield(())
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                #expect(!Task.isCancelled)
                return SyncMergeSummary(importedProviders: 1)
            }
        }
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        caller.cancel()
        do {
            _ = try await operations.perform { SyncMergeSummary.empty }
            Issue.record("并发导入没有被拒绝")
        } catch {
            if let failure = error as? MacWorkspaceWriteError, case .busy = failure {} else {
                Issue.record("并发导入应报告工作区繁忙")
            }
        }
        release.continuation.yield(())
        await operations.waitForCompletion()
        let summary = try await caller.value
        #expect(summary.importedProviders == 1)
    }

    @Test("数据库恢复排空仍在读取的预览，取消结果不会继续成为新预览")
    @MainActor
    func databaseBarrierCancelsAndDrainsPreview() async {
        let operations = MacDataImportOperations(), started = AsyncStream<Void>.makeStream()
        let worker = Task.detached {
            started.continuation.yield(())
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        let id = operations.trackPreview(worker)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        await operations.cancelAndWaitForPreviews()
        switch await worker.result {
        case .success: Issue.record("数据替换前的旧预览仍然成功")
        case .failure(let error): #expect(error is CancellationError)
        }
        operations.finishPreview(id)
    }

    private func prepared(_ package: SyncPackage) -> ThirdPartyImportPreparedResult {
        ThirdPartyImportPreparedResult(source: .openMinis, package: package, warnings: [])
    }

    private func provider() -> Provider {
        Provider(name: "private-provider", baseURL: "https://example.invalid/private", apiKeys: ["private-key"], apiFormat: "openai")
    }

}
