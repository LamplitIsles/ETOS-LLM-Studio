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
        guard !suspended else { return }
        workspace.errorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
    }
}
