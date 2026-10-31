// ============================================================================
// DailyPulseContextAndDeliveryTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 每日脉冲同步数据的合并测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("每日脉冲同步数据合并测试")
struct DailyPulseContextAndDeliveryTests {

    @Test("外部信号历史会按主题去重并保留最新记录")
    func appendingExternalSignalDeduplicatesByTopic() {
        let older = DailyPulseExternalSignal(
            source: .shortcutResult,
            title: "今日摘要",
            preview: "今天有 2 个提醒。",
            capturedAt: Date(timeIntervalSince1970: 100),
            isFailure: false
        )
        let newer = DailyPulseExternalSignal(
            source: .shortcutResult,
            title: "今日摘要",
            preview: "今天有 3 个提醒。",
            capturedAt: Date(timeIntervalSince1970: 200),
            isFailure: false
        )

        let merged = SyncEngine.appendingExternalSignal(newer, to: [older], limit: 10)

        #expect(merged.count == 1)
        #expect(merged.first?.preview == "今天有 3 个提醒。")
    }

    @Test("Pulse 任务合并会保留较新的状态与完成标记")
    func mergeTaskKeepsLatestCompletionState() {
        let local = DailyPulseTask(
            id: UUID(uuidString: "12121212-3434-5656-7878-909090909090")!,
            sourceDayKey: "2026-03-22",
            sourceCardID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            title: "继续推进项目",
            details: "先处理阻塞点",
            suggestedPrompt: "帮我继续拆项目阻塞点",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            completedAt: nil
        )
        let incoming = DailyPulseTask(
            id: local.id,
            sourceDayKey: "2026-03-22",
            sourceCardID: local.sourceCardID,
            title: "继续推进项目",
            details: "先处理阻塞点并同步 reviewer",
            suggestedPrompt: "帮我继续拆项目阻塞点",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 300),
            completedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = SyncEngine.mergeTask(local: local, incoming: incoming)

        #expect(merged.isCompleted)
        #expect(merged.details.contains("reviewer"))
        #expect(merged.updatedAt == incoming.updatedAt)
    }

    @Test("相同主题与动作的反馈历史会被去重覆盖")
    func appendingFeedbackEventDeduplicatesSameTopicAction() {
        let older = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
            createdAt: Date(timeIntervalSince1970: 100),
            dayKey: "2026-03-22",
            topicHint: "继续推进项目",
            cardTitle: "继续推进项目",
            action: .liked
        )
        let newer = DailyPulseFeedbackEvent(
            id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
            createdAt: Date(timeIntervalSince1970: 200),
            dayKey: "2026-03-22",
            topicHint: "继续推进项目 下一步",
            cardTitle: "继续推进项目",
            action: .liked
        )

        let history = SyncEngine.appendingFeedbackEvent(newer, to: [older], limit: 10)

        #expect(history.count == 1)
        #expect(history.first?.id == newer.id)
    }
}
