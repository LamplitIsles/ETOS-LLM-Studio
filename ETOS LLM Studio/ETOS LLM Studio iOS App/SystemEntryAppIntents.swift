// ============================================================================
// SystemEntryAppIntents.swift
// ETOS LLM Studio iOS App
// ============================================================================

import AppIntents
import ETOSCore
import Foundation

struct StartETOSAgentTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "新建 Agent 任务"
    static var description = IntentDescription("在新会话中交给 ETOS Agent 处理。")

    @Parameter(title: "任务") var prompt: String
    @Parameter(title: "标题") var taskTitle: String?
    @Parameter(title: "请求 ID") var requestID: String?

    init() {
        requestID = UUID().uuidString
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let result = try await SystemEntryCoordinator.shared.startTask(
            prompt: prompt,
            mode: .agent,
            title: taskTitle,
            requestID: UUID(uuidString: requestID ?? "") ?? UUID()
        )
        let message: String
        switch result.outcome {
        case .locallyAccepted:
            message = NSLocalizedString("内容已添加到当前会话，发送结果请在应用中查看。", comment: "Locally accepted Agent task")
        case .alreadyRecorded:
            message = NSLocalizedString("该请求已有记录，发送结果尚未确认。请先查看会话，再决定下一步。", comment: "Previously recorded Agent task")
        }
        return .result(value: result.sessionID.uuidString, dialog: IntentDialog(stringLiteral: message))
    }
}

struct OpenETOSBrowserIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 Browser Agent"
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .requestSystemEntryRoute, object: SystemEntryRoute.browser)
        return .result()
    }
}

struct ETOSAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartETOSAgentTaskIntent(),
            phrases: ["用 \(.applicationName) 新建 Agent 任务"],
            shortTitle: "新建 Agent 任务",
            systemImageName: "sparkles"
        )
    }
}
