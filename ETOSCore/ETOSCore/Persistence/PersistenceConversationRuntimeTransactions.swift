// ============================================================================
// PersistenceConversationRuntimeTransactions.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责跨多个运行时实体的一致性创建事务。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    // MARK: - 运行时组合事务

    func createConversationRuntimeBundle(
        origin: ConversationOrigin?,
        capabilities: [ConversationCapability],
        targetRun: ConversationRun?,
        event: ConversationEvent?,
        delegation: ConversationDelegation?,
        waits: [ConversationWait],
        waitingRunID: UUID?
    ) throws {
        let targetRunConfigurationJSON: Data?
        if let targetRun {
            guard let encoded = encodeJSON(targetRun.requestConfiguration) else {
                throw ConversationRuntimeError.persistenceUnavailable
            }
            targetRunConfigurationJSON = encoded
        } else {
            targetRunConfigurationJSON = nil
        }

        try dbPool.write { db in
            if let origin {
                try upsertConversationOrigin(db, origin: origin)
            }
            for capability in capabilities {
                try upsertConversationCapability(db, capability: capability)
            }
            if let targetRun, let targetRunConfigurationJSON {
                try upsertConversationRun(
                    db,
                    run: targetRun,
                    configurationJSON: targetRunConfigurationJSON
                )
            }
            for wait in waits {
                try upsertConversationWait(db, wait: wait)
            }

            if let waitingRunID {
                try db.execute(
                    sql: """
                    UPDATE conversation_runs
                    SET status = 'waitingConversation', finished_at = NULL, error_message = NULL
                    WHERE id = ?
                    """,
                    arguments: [waitingRunID.uuidString]
                )
            }
            if let event {
                try upsertConversationEvent(db, event: event)
            }
            if let delegation {
                try upsertConversationDelegation(db, delegation: delegation)
            }
        }
    }
}
