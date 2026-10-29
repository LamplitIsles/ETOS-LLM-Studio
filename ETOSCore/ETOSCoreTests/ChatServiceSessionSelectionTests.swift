import Combine
import Foundation
import Testing
@testable import ETOSCore

extension ChatServiceTests {
    @Test("切入后台生成会话保留运行期消息")
    @MainActor
    func selectionUsesLiveSnapshot() async throws {
        let service = try #require(chatService)
        let first = service.createSavedSession(name: "当前会话")
        let running = service.createSavedSession(name: "后台生成")
        let live = ChatMessage(role: .assistant, content: "尚未保存的片段")
        let token = UUID()
        service.setRequestContext(.init(
            token: token, task: nil, loadingMessageID: live.id, imageGenerationContext: nil
        ), for: running.id)
        service.storeRuntimeMessagesSnapshot([live], for: running.id)
        defer { service.clearRequestContextIfNeeded(for: running.id, token: token) }

        await service.selectSession(first)
        await service.selectSession(running)
        #expect(service.messagesForSessionSubject.value == [live])
    }
}
