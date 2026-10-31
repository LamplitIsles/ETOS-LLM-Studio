// ============================================================================
// ChatServiceResponsePipeline.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的流式响应接收、已解析消息收敛与工具调用编排。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    func finishSessionRequestAndCleanupFileHistory(sessionID: UUID) async {
        guard !Task.isCancelled else { return }
        let runID = conversationRunIDs(for: sessionID)?.runID
        if let runID, !containsActiveToolRun(sessionID: sessionID, runID: runID) { return }
        emitSessionRequestStatus(.finished, sessionID: sessionID)
        guard let runID else { return }
        guard claimCompletedToolRunCleanup(sessionID: sessionID, runID: runID) else { return }
        await finishToolRunResources(runID: runID, state: .completed)
    }

    func finishToolRunResources(runID: UUID, state: LocalAgentRunState) async {
        defer { toolRunCleanupDidFinish(runID: runID) }
        let effectiveState = commitToolRunCleanupState(runID: runID, fallback: state)
        if effectiveState != .completed || Persistence.loadLocalAgentRun(id: runID)?.state == .running {
            await LocalAgentRuntimeContextManager.shared.finishRun(id: runID, state: effectiveState)
        } else {
            await SkillAllowedToolRuntime.shared.finishRun(id: runID)
            await LocalAgentFileToolExecutor.shared.finishRun(id: runID)
        }
    }

}
