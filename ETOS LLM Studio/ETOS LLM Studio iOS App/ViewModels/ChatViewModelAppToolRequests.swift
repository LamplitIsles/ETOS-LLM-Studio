// ============================================================================
// ChatViewModelAppToolRequests.swift
// ============================================================================
// 按来源会话接收交互类 App Tool 请求，并把用户补充准确送回原会话。
// ============================================================================

import Foundation
import Combine
import ETOSCore

extension ChatViewModel {
    func receiveToolInputDraftRequest(
        _ request: AppToolInputDraftRequest,
        receipt: AppToolUIRequestDeliveryReceipt
    ) {
        guard let sessionID = request.sourceSessionID ?? currentSession?.id else { return }
        if currentSession?.id == sessionID {
            guard receipt.claim(.applied) else { return }
            applyToolInputDraftRequest(request)
        } else {
            guard receipt.claim(.queued) else { return }
            toolInputDraftRequestsBySessionID[sessionID, default: []].append(request)
        }
    }

    func refreshSessionScopedAppToolRequests() {
        guard let sessionID = currentSession?.id else { return }

        let drafts = toolInputDraftRequestsBySessionID.removeValue(forKey: sessionID) ?? []
        for draft in drafts {
            applyToolInputDraftRequest(draft)
        }
    }

}
