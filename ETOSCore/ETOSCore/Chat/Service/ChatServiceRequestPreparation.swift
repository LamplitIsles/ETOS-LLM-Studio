// ============================================================================
// ChatServiceRequestPreparation.swift
// ============================================================================
// ETOS LLM Studio
//
// ============================================================================

import Foundation

extension ChatService {
    struct ResponseAttemptMetadata: Sendable {
        let groupID: UUID
        let attemptID: UUID
        let attemptIndex: Int
    }

    func applyResponseAttemptMetadata(_ metadata: ResponseAttemptMetadata?, to message: inout ChatMessage) {
        guard let metadata else { return }
        message.responseGroupID = metadata.groupID
        message.responseAttemptID = metadata.attemptID
        message.responseAttemptIndex = metadata.attemptIndex
        message.selectedResponseAttemptID = metadata.attemptID
    }
}
