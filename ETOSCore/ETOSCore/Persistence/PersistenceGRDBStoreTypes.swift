// ============================================================================
// PersistenceGRDBStoreTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 拆分后共享的内部数据结构与迁移错误定义。
// ============================================================================

import Foundation
import GRDB

struct UsageDayKeyFilter {
    let sql: String
    let arguments: StatementArguments
    let shouldQuery: Bool
}
