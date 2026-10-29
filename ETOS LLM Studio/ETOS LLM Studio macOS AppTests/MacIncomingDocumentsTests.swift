import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacIncomingDocumentsTests {
    @Test("恢复前清空排队文件，取消后仍等待读取收尾")
    @MainActor
    func suspensionDiscardsPendingAndLateAttachments() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let gate = MacPausedAttachmentRead()
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(loadAttachments: { try gate.read($0) },
                                                 applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        incoming.resume(sessionID: UUID())
        #expect(incoming.enqueue([fixture.text]))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        #expect(incoming.enqueue([fixture.text]))
        incoming.suspend()
        #expect(!incoming.enqueue([fixture.text]))
        var finished = false
        let waiter = Task { await incoming.waitForPendingOperations(); finished = true }
        await Task.yield()
        #expect(!finished)
        gate.resume.signal()
        await waiter.value
        #expect(finished)
        #expect(!incoming.isWorking)
        #expect(attachments.isEmpty)
        #expect(errors.isEmpty)
        incoming.resume(sessionID: UUID())
        await incoming.waitForPendingOperations()
        incoming.suspend()
    }

    @Test("切换后再返回同一会话，旧附件结果仍然失效")
    @MainActor
    func roundTripSessionSwitchInvalidatesAttachmentRead() async throws {
        let fixture = try MacIncomingFixture()
        defer { fixture.remove() }
        let gate = MacPausedAttachmentRead()
        var attachments: [MacComposerAttachment] = [], errors: [String] = []
        let incoming = MacIncomingDocumentsModel(loadAttachments: { try gate.read($0) },
                                                 applyAttachments: { attachments += $0 }, reportError: { errors.append($0) })
        let session = UUID()
        incoming.resume(sessionID: session)
        let oldContext = incoming.contextID
        #expect(incoming.enqueue([fixture.text]))
        let entered = await Task.detached { gate.entered.wait(timeout: .now() + 5) == .success }.value
        #expect(entered)
        incoming.updateSession(UUID()); incoming.updateSession(session)
        #expect(incoming.contextID != oldContext)
        gate.resume.signal()
        await incoming.waitForPendingOperations()
        #expect(attachments.isEmpty)
        #expect(errors.count == 1)
        incoming.suspend()
    }


}

private final class MacPausedAttachmentRead: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func read(_ urls: [URL]) throws -> [MacComposerAttachment] {
        entered.signal()
        guard resume.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileReadUnknown) }
        // 故意忽略任务取消，验证工作区对迟到结果的隔离，而非只依赖加载器配合。
        return [MacComposerAttachment(data: Data("late".utf8), type: .plainText, fileName: urls[0].lastPathComponent)]
    }
}

private struct MacIncomingFixture {
    let root: URL
    let text: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacIncoming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        text = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: text)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
