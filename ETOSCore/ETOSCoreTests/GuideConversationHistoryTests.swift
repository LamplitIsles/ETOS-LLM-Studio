// ============================================================================
// GuideConversationHistoryTests.swift
// ============================================================================
// 验证历史存储的内容隔离及模式分离。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

extension GuideInfrastructureTests {
    @Test("向导存档保留正文与工具状态，不保存秘密参数、源码结果或隐藏思考")
    func historyStoresOnlyConversationAndToolSummaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GuideConversationHistoryStore(directoryURL: directory)
        let user = GuideConversationMessage(role: .user, content: "帮我修改配置")
        let call = InternalToolCall(
            id: "write", toolName: "propose_setting", arguments: "{\"api_key\":\"secret-test-value\"}",
            result: "source-file-private-result", resultDisposition: .completed,
            providerSpecificFields: ["signature": .string("private-signature")]
        )
        await store.save(GuideConversationHistorySnapshot(
            messages: [
                user,
                GuideConversationMessage(role: .assistant, content: "已修改", toolCalls: [call]),
                GuideConversationMessage(role: .tool, content: "source-file-private-result")
            ],
            requestHistory: [
                ChatMessage(role: .user, content: user.content),
                ChatMessage(role: .assistant, content: "", reasoningContent: "private-reasoning", toolCalls: [call]),
                ChatMessage(role: .tool, content: "source-file-private-result", toolCalls: [call]),
                ChatMessage(role: .assistant, content: "已修改", reasoningContent: "private-reasoning")
            ],
            streamingMessageID: nil, streamingContent: "",
            latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
        ))
        let restored = try #require(await store.load())
        #expect(restored.messages.map(\.content) == ["帮我修改配置", "已修改"])
        #expect(restored.messages.last?.toolCalls.first?.resultDisposition == .completed)
        #expect(restored.requestHistory.map(\.content) == ["帮我修改配置", "已修改"])
        #expect(restored.requestHistory.allSatisfy { ($0.toolCalls ?? []).isEmpty && $0.reasoningContent == nil })
        let data = try Data(contentsOf: directory.appendingPathComponent("contextualHelp.json"))
        let raw = try #require(String(data: data, encoding: .utf8))
        for secret in ["secret-test-value", "source-file-private-result", "private-signature", "private-reasoning"] {
            #expect(!raw.contains(secret))
        }
    }

    @Test("后台保存流式片段后只恢复文本，两个向导模式的历史彼此独立")
    func historyStoresPartialAnswersAndSeparatesModes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let help = GuideConversationHistoryStore(mode: .contextualHelp, directoryURL: directory)
        let setup = GuideConversationHistoryStore(mode: .modelSetup, directoryURL: directory)
        let user = GuideConversationMessage(role: .user, content: "解释这个设置")
        let streaming = GuideConversationMessage(role: .assistant, content: "")
        await help.save(GuideConversationHistorySnapshot(
            messages: [user, streaming], requestHistory: [ChatMessage(role: .user, content: user.content)],
            streamingMessageID: streaming.id, streamingContent: "已经生成的片段",
            latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
        ))
        await setup.save(historySnapshot("首次配置"))
        #expect(await help.load()?.messages.last?.content == "已经生成的片段")
        #expect(await help.load()?.requestHistory.last?.content == "已经生成的片段")
        #expect(await setup.load()?.messages.first?.content == "首次配置")
    }
}

private func historySnapshot(_ content: String) -> GuideConversationHistorySnapshot {
    let user = GuideConversationMessage(role: .user, content: content)
    return GuideConversationHistorySnapshot(
        messages: [user], requestHistory: [ChatMessage(role: .user, content: content)],
        streamingMessageID: nil, streamingContent: "", latestUserMessageID: user.id, latestUserMessageAllowsEditing: true
    )
}
