import Foundation
import Testing
import GRDB
@testable import ETOSCore

@Suite("批量请求、状态与结果回归")
struct BatchSupportTests {
    private func job() -> BatchJob {
        BatchJob(id: UUID(), title: "测试", providerID: UUID(), modelID: UUID(),
                 providerName: "Batch Test", modelName: "batch-test", baseURL: "https://example.invalid/v1",
                 credentialDigest: "credential", headersDigest: "headers", endpoint: "/v1/chat/completions",
                 requests: [BatchRequestItem(id: "one", input: "第一条", body: .dictionary([:])),
                            BatchRequestItem(id: "two", input: "第二条", body: .dictionary([:]))])
    }

    @Test("准备结果状态不会被误判失败，时间沿用服务端")
    func remoteStatusAndDates() throws {
        let response = try JSONDecoder().decode(OpenAIBatchResponse.self, from: Data("""
        {"id":"batch_one","status":"finalizing","created_at":1000,"completed_at":null}
        """.utf8))
        let updated = response.applying(to: job())
        #expect(updated.status == .finalizing)
        #expect(updated.needsRefresh)
        #expect(updated.remoteCreatedAt == Date(timeIntervalSince1970: 1000))
        #expect(updated.finishedAt == nil)
    }

    @Test("终态任务在结果未保存时仍需刷新", arguments: [BatchJobStatus.completed, .expired, .cancelled, .failed])
    func resumesIncompleteDownloads(status: BatchJobStatus) throws {
        var job = job()
        job.remoteID = "batch"
        job.status = status
        #expect(job.needsRefresh)
        job.resultsDownloaded = true
        #expect(job.needsRefresh)
        job.notified = true
        #expect(!job.needsRefresh)
    }

    @Test("数据库往返保存完整请求和结果且拒绝迟到覆盖")
    func persistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory, configuration: Configuration(), schedulesMaintenance: false)
        var original = job()
        original.results = [BatchResult(id: original.requests[0].id, text: "saved")]
        try BatchJobStore.save(original, in: store)
        let restored = try BatchJobStore.load(original.id, in: store)
        #expect(restored.requests.map(\.input) == original.requests.map(\.input))
        #expect(restored.results[0].text == "saved")
        #expect(try BatchJobStore.loadAll(in: store).count == 1)
        var newer = original
        newer.updatedAt = original.updatedAt.addingTimeInterval(10)
        newer.status = .completed
        try BatchJobStore.save(newer, expecting: original.updatedAt, in: store)
        #expect(throws: BatchError.self) { try BatchJobStore.save(original, expecting: original.updatedAt, in: store) }
        #expect(try BatchJobStore.load(original.id, in: store).status == .completed)
        try BatchJobStore.remove(original.id, in: store)
        #expect(try BatchJobStore.loadAll(in: store).isEmpty)
    }

}
