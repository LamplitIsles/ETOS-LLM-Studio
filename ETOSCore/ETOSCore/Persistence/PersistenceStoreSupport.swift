// ============================================================================
// PersistenceStoreSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的目录、路径、时间戳、迁移与文件读写辅助逻辑。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    static func inferToolCallsPlacement(from content: String) -> ToolCallsPlacement {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .afterReasoning
        }
        let lowered = trimmed.lowercased()
        let startsWithThought = lowered.hasPrefix("<thought") || lowered.hasPrefix("<thinking") || lowered.hasPrefix("<think")
        if startsWithThought {
            let hasClosing = lowered.contains("</thought>") || lowered.contains("</thinking>") || lowered.contains("</think>")
            if !hasClosing {
                return .afterReasoning
            }
        }
        let contentWithoutThought = stripThoughtTags(from: content)
        if !contentWithoutThought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .afterContent
        }
        if lowered.contains("<thought") || lowered.contains("<thinking") || lowered.contains("<think") {
            return .afterReasoning
        }
        return .afterContent
    }

    static func stripThoughtTags(from text: String) -> String {
        let pattern = "<(thought|thinking|think)>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func normalizeToolCallsPlacement(in messages: [ChatMessage], sessionID: UUID) -> (messages: [ChatMessage], didMigratePlacement: Bool) {
        var normalizedMessages = messages
        var didMigratePlacement = false

        for index in normalizedMessages.indices {
            guard normalizedMessages[index].toolCallsPlacement == nil,
                  let toolCalls = normalizedMessages[index].toolCalls,
                  !toolCalls.isEmpty else { continue }
            normalizedMessages[index].toolCallsPlacement = inferToolCallsPlacement(from: normalizedMessages[index].content)
            didMigratePlacement = true
        }

        if didMigratePlacement {
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 的 toolCallsPlacement 已自动补齐。")
        }
        return (normalizedMessages, didMigratePlacement)
    }

    static func accumulateRequestTokens(_ usage: MessageTokenUsage?, to totals: inout RequestLogTokenTotals) {
        guard let usage else { return }
        if totals.uncachedInputTokens != nil || usage.uncachedInputTokens != nil {
            totals.uncachedInputTokens = (totals.uncachedInputTokens ?? max(0, totals.sentTokens - totals.cacheReadTokens))
                + ModelCostCalculator.billableInputTokens(for: usage)
        }
        if totals.cacheWriteFiveMinuteTokens != nil || usage.cacheWriteFiveMinuteTokens != nil {
            totals.cacheWriteFiveMinuteTokens = (totals.cacheWriteFiveMinuteTokens ?? 0) + (usage.cacheWriteFiveMinuteTokens ?? 0)
        }
        if totals.cacheWriteOneHourTokens != nil || usage.cacheWriteOneHourTokens != nil {
            totals.cacheWriteOneHourTokens = (totals.cacheWriteOneHourTokens ?? 0) + (usage.cacheWriteOneHourTokens ?? 0)
        }
        totals.sentTokens += usage.promptTokens ?? 0
        totals.receivedTokens += usage.completionTokens ?? 0
        totals.thinkingTokens += usage.thinkingTokens ?? 0
        totals.cacheWriteTokens += usage.cacheWriteTokens ?? 0
        totals.cacheReadTokens += usage.cacheReadTokens ?? 0
        totals.totalTokens += usage.totalTokens ?? 0
    }
}
