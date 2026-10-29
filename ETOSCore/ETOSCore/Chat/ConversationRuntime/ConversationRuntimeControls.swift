// ============================================================================
// ConversationRuntimeControls.swift
// ============================================================================
// ETOS LLM Studio
//
// Stop the current request and native jobs belonging to a specific run.
// ============================================================================

import Foundation

extension ChatService {
    public func stopConversationRun(_ runID: UUID) async {
        if let sessionID = activeRequestSessionIDs().first(where: {
            conversationRunIDs(for: $0)?.runID == runID
        }) {
            await cancelRequest(for: sessionID)
        }
        await LocalLinuxJobScheduler.shared.cancel(runID: runID)
    }
}
