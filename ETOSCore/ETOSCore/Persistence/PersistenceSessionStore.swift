// ============================================================================
// PersistenceSessionStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 的会话、消息、请求日志、用量统计与跨会话摘要存取。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    public static func appendRequestLog(_ entry: RequestLogEntry) {
        if let store = activeGRDBStore() {
            store.appendRequestLog(entry, retentionLimit: effectiveRequestLogRetentionLimit())
            return
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        do {
            var logs = (try loadRequestLogEnvelope()?.logs) ?? []
            logs.append(entry)
            let retentionLimit = effectiveRequestLogRetentionLimit()
            if logs.count > retentionLimit {
                logs.removeFirst(logs.count - retentionLimit)
            }
            try writeRequestLogEnvelope(
                .init(
                    schemaVersion: requestLogSchemaVersion,
                    updatedAt: iso8601Timestamp(),
                    logs: logs
                )
            )
        } catch {
            logger.error("写入请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 清空请求日志文件。
    public static func clearRequestLogs() {
        if let store = activeGRDBStore() {
            store.clearRequestLogs()
            return
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let fileURL = requestLogsFileURL()
        do {
            try removeItemIfExists(at: fileURL)
        } catch {
            logger.error("清空请求日志失败: \(error.localizedDescription)")
        }
    }

    /// 按条件读取请求日志（默认按请求开始时间倒序）。
    public static func loadRequestLogs(query: RequestLogQuery = .init()) -> [RequestLogEntry] {
        if let store = activeGRDBStore() {
            return store.loadRequestLogs(query: query)
        }

        requestLogLock.lock()
        defer { requestLogLock.unlock() }

        let allLogs: [RequestLogEntry]
        do {
            allLogs = try loadRequestLogEnvelope()?.logs ?? []
        } catch {
            logger.error("读取请求日志失败: \(error.localizedDescription)")
            return []
        }

        var filtered = allLogs.filter { entry in
            if let from = query.from, entry.requestedAt < from {
                return false
            }
            if let to = query.to, entry.requestedAt > to {
                return false
            }
            if let providerID = query.providerID, entry.providerID != providerID {
                return false
            }
            if let modelID = query.modelID, entry.modelID != modelID {
                return false
            }
            if let statuses = query.statuses, !statuses.contains(entry.status) {
                return false
            }
            return true
        }
        filtered.sort { $0.requestedAt > $1.requestedAt }
        if let limit = query.limit, limit > 0, filtered.count > limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    /// 汇总请求日志，用于后续统计展示与导出。
    public static func summarizeRequestLogs(query: RequestLogQuery = .init()) -> RequestLogSummary {
        if let store = activeGRDBStore() {
            return store.summarizeRequestLogs(query: query)
        }

        let logs = loadRequestLogs(query: query)
        var summary = RequestLogSummary()

        var providerBuckets: [String: RequestLogSummaryBucket] = [:]
        var modelBuckets: [String: RequestLogSummaryBucket] = [:]

        for entry in logs {
            summary.totalRequests += 1
            switch entry.status {
            case .success:
                summary.successCount += 1
            case .failed:
                summary.failedCount += 1
            case .cancelled:
                summary.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &summary.tokenTotals)

            var providerBucket = providerBuckets[entry.providerName] ?? RequestLogSummaryBucket(key: entry.providerName)
            providerBucket.requestCount += 1
            switch entry.status {
            case .success:
                providerBucket.successCount += 1
            case .failed:
                providerBucket.failedCount += 1
            case .cancelled:
                providerBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &providerBucket.tokenTotals)
            providerBuckets[entry.providerName] = providerBucket

            var modelBucket = modelBuckets[entry.modelID] ?? RequestLogSummaryBucket(key: entry.modelID)
            modelBucket.requestCount += 1
            switch entry.status {
            case .success:
                modelBucket.successCount += 1
            case .failed:
                modelBucket.failedCount += 1
            case .cancelled:
                modelBucket.cancelledCount += 1
            }
            accumulateRequestTokens(entry.tokenUsage, to: &modelBucket.tokenTotals)
            modelBuckets[entry.modelID] = modelBucket
        }

        summary.byProvider = providerBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        summary.byModel = modelBuckets.values.sorted { lhs, rhs in
            if lhs.requestCount == rhs.requestCount {
                return lhs.key < rhs.key
            }
            return lhs.requestCount > rhs.requestCount
        }
        return summary
    }

    // MARK: - 用量统计

    /// 追加一条新的用量事件。
    public static func appendUsageAnalyticsEvent(_ event: UsageAnalyticsEvent) {
        activeGRDBStore()?.appendUsageAnalyticsEvent(event)
    }

    /// 清空新的用量统计数据。
    public static func clearUsageAnalyticsData() {
        activeGRDBStore()?.clearUsageAnalyticsData()
    }

    /// 删除指定日期的用量事件包。
    @discardableResult
    public static func deleteUsageStatsDayBundles(dayKeys: [String]) -> Int {
        activeGRDBStore()?.deleteUsageStatsDayBundles(dayKeys: dayKeys) ?? 0
    }

    /// 读取按天聚合后的用量总览。
    public static func loadUsageDailyTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyTotal] {
        activeGRDBStore()?.loadUsageDailyTotals(fromDayKey: fromDayKey, toDayKey: toDayKey) ?? []
    }

    /// 读取按天、模型和来源聚合后的细分统计。
    public static func loadUsageDailyModelTotals(fromDayKey: String? = nil, toDayKey: String? = nil) -> [UsageDailyModelTotal] {
        activeGRDBStore()?.loadUsageDailyModelTotals(fromDayKey: fromDayKey, toDayKey: toDayKey) ?? []
    }

    /// 只读取指定会话的请求事件，不从消息或分支历史推算用量。
    public static func loadSessionUsageAnalyticsEvents(sessionID: UUID) -> [UsageAnalyticsEvent] {
        activeGRDBStore()?.loadSessionUsageAnalyticsEvents(sessionID: sessionID) ?? []
    }

    /// 读取用于同步的按天事件包。
    public static func loadUsageStatsDayBundles(dayKeys: [String]? = nil) -> [UsageStatsDayBundle] {
        activeGRDBStore()?.loadUsageStatsDayBundles(dayKeys: dayKeys) ?? []
    }

    /// 合并来自其他设备的用量统计事件包。
    @discardableResult
    public static func mergeUsageStatsDayBundles(_ bundles: [UsageStatsDayBundle]) -> UsageStatsMergeResult {
        activeGRDBStore()?.mergeUsageStatsDayBundles(bundles) ?? .init()
    }

    public static func countDistinctUsageSessions(dayKeys: Set<String>? = nil) -> Int {
        activeGRDBStore()?.countDistinctUsageSessions(dayKeys: dayKeys) ?? 0
    }

    public static func countUsageMessages(dayKeys: Set<String>? = nil) -> Int {
        activeGRDBStore()?.countUsageMessages(dayKeys: dayKeys) ?? 0
    }

}
