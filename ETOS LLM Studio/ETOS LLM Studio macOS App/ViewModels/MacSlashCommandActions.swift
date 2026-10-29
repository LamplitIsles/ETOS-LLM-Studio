import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSlashCommandActions: ObservableObject {
    @Published private(set) var isWorking = false
    private var task: Task<Void, Never>?
    private var suspended = true
    private var epoch = UUID()

    func resume() { suspended = false; epoch = UUID() }
    func suspend() { suspended = true; epoch = UUID() }
    func waitForCompletion() async { await task?.value }

    func temporary(workspace: MacWorkspaceModel) {
        guard !suspended, !isWorking else { return }
        workspace.enableTemporaryChat()
    }

    func retry(workspace: MacWorkspaceModel) {
        guard !suspended, workspace.canManageLocalModels,
              let service = workspace.service, let sessionID = workspace.currentSession?.id else { return }
        guard !isWorking, workspace.canModifyCurrentHistory else {
            workspace.errorMessage = MacWorkspaceWriteError.busy.localizedDescription; return
        }
        guard workspace.effectiveModelName != nil else {
            workspace.errorMessage = NSLocalizedString("请先激活一个聊天模型。", comment: ""); return
        }
        let expected = epoch
        isWorking = true
        task = Task { [weak self, weak workspace] in
            let latest = await Task.detached(priority: .userInitiated) { () -> ChatMessage? in
                let messages = service.messagesSnapshot(for: sessionID)
                guard ChatQuickRetrySupport.canRetryLatestMessage(in: messages, isSending: service.runningSessionIDsSubject.value.contains(sessionID)) else { return nil }
                return ChatResponseAttemptSupport.visibleMessages(from: messages).last
            }.value
            guard let self else { return }
            isWorking = false; task = nil
            guard !suspended, epoch == expected, let workspace, workspace.canManageLocalModels,
                  workspace.currentSession?.id == sessionID, service.currentSessionSubject.value?.id == sessionID else { return }
            guard let latest else {
                workspace.errorMessage = NSLocalizedString("当前没有可重试的回复。", comment: ""); return
            }
            workspace.retryMessage(latest)
        }
    }
}
