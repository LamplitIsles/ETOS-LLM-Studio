// ============================================================================
// PersistenceFilePayloads.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 Persistence 相关的请求日志文件格式定义。
// ============================================================================

import Foundation

struct RequestLogFileEnvelope: Codable {
    let schemaVersion: Int
    let updatedAt: String
    let logs: [RequestLogEntry]
}
