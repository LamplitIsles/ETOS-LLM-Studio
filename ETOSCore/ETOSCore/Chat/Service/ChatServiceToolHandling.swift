// ============================================================================
// ChatServiceToolHandling.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的工具调用执行、工具结果写回与记忆搜索结果序列化。
// ============================================================================

import Foundation
import os.log

extension ChatService {
    struct ToolCallOutcome {
        let message: ChatMessage
        let toolResult: String?
        let resultDisposition: InternalToolCallResultDisposition
        let shouldAwaitUserSupplement: Bool
        var outcomeUnknown = false
    }

    /// 处理单个工具调用
    func handleToolCall(
        _ toolCall: InternalToolCall,
        sessionID: UUID,
        agentRunID: UUID? = nil,
        triggeringMessageID: UUID? = nil,
        sourceMessageID: UUID
    ) async -> ToolCallOutcome? {
        guard let identity = ChatRequestTaskIdentity.current, identity.sessionID == sessionID,
              permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
        let admission: @Sendable () -> Bool = { [weak self] in
            self?.permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID, token: identity.token) ?? false
        }
        logger.info("正在处理工具调用: \(toolCall.toolName)")

        var content = ""
        var displayResult: String?
        var resultDisposition: InternalToolCallResultDisposition = .completed
        var shouldAwaitUserSupplement = false
        var outcomeUnknown = false
        let unknownOutcomeID = UUID()
        let recordUnknown: @Sendable () -> Void = { [weak self] in
            self?.recordUnknownToolOutcome(ChatUnknownToolOutcome(
                id: unknownOutcomeID, sessionID: sessionID, messageID: sourceMessageID,
                toolCallID: toolCall.id, toolName: toolCall.toolName
            ))
        }
        let policyDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 已被策略禁止调用。", comment: "Tool result when policy denies a call"), $0)
        }
        let callFailedText: (String, String) -> String = {
            String(format: NSLocalizedString("%@ 调用失败：%@", comment: "Tool result when a call fails"), $0, $1)
        }
        let userDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 调用已被用户拒绝。", comment: "Tool result when user denies a call"), $0)
        }

        let exemptToolNames: Set<String> = [SkillManager.chatToolName]
        if let agentRunID,
           !(await SkillAllowedToolRuntime.shared.isToolAllowed(
                toolCall.toolName,
                runID: agentRunID,
                exemptToolNames: exemptToolNames
           )) {
            guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
            let denied = String(
                format: NSLocalizedString("%@ 不在当前 Skill 的 allowed-tools 范围内，已拒绝调用。", comment: "Skill allowed tools denied result"),
                toolCall.toolName
            )
            return ToolCallOutcome(
                message: ChatMessage(
                    role: .tool,
                    content: denied,
                    toolCalls: [
                        InternalToolCall(
                            id: toolCall.id,
                            toolName: toolCall.toolName,
                            arguments: toolCall.arguments,
                            result: denied,
                            resultDisposition: .rejected,
                            providerSpecificFields: toolCall.providerSpecificFields
                        )
                    ]
                ),
                toolResult: denied,
                resultDisposition: .rejected,
                shouldAwaitUserSupplement: false
            )
        }

        guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
        switch toolCall.toolName {
        case _ where ShortcutToolManager.isShortcutToolName(toolCall.toolName):
            let toolLabel = await ShortcutToolManager.shared.displayLabel(for: toolCall.toolName) ?? toolCall.toolName
            let shortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
            guard shortcutToolsEnabled else {
                content = NSLocalizedString("快捷指令工具总开关已关闭。", comment: "Shortcut tool disabled result")
                displayResult = content
                logger.info("  - 快捷指令工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
            guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
            let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                toolName: toolCall.toolName,
                displayName: toolLabel,
                arguments: toolCall.arguments,
                sourceSessionID: sessionID,
                toolCallID: toolCall.id
            )
            switch permissionDecision {
            case .deny:
                content = userDeniedText(toolLabel)
                displayResult = content
                resultDisposition = .rejected
                logger.info("  - 快捷指令工具调用被用户拒绝: \(toolCall.toolName)")
            case .supplement:
                content = userDeniedText(toolLabel)
                displayResult = content
                resultDisposition = .rejected
                shouldAwaitUserSupplement = true
                logger.info("  - 快捷指令工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
            case .allowOnce, .allowForTool, .allowAll:
                do {
                    try Task.checkCancellation()
                    guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
                    let result = try await ShortcutToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments,
                        admission: admission,
                        onOutcomeUnknown: recordUnknown
                    )
                    content = result
                    displayResult = result
                    logger.info("  - 快捷指令工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    resultDisposition = .failed
                    if let shortcutError = error as? ShortcutToolError, case .outcomeUnknown = shortcutError {
                        shouldAwaitUserSupplement = true
                        outcomeUnknown = true
                        displayResult = nil
                    }
                    logger.error("  - 快捷指令工具调用失败: \(error.localizedDescription)")
                }
            }

        case _ where SkillManager.isSkillToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                SkillManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let skillsEnabled = await MainActor.run { SkillManager.shared.chatToolsEnabled }
            guard skillsEnabled else {
                content = NSLocalizedString("Agent Skills 总开关已关闭。", comment: "Agent Skills disabled result")
                displayResult = content
                logger.info("  - Agent Skills 调用被总开关拒绝: \(toolCall.toolName)")
                break
            }

            do {
                try Task.checkCancellation()
                guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
                let result = try await SkillManager.shared.executeToolFromChat(
                    toolName: toolCall.toolName,
                    argumentsJSON: toolCall.arguments,
                    sourceSessionID: sessionID,
                    sourceAgentRunID: agentRunID,
                    triggeringMessageID: triggeringMessageID,
                    sourceToolCallID: toolCall.id,
                    admission: admission
                )
                content = result
                displayResult = result
                logger.info("  - Agent Skills 调用成功: \(toolCall.toolName)")
            } catch {
                content = callFailedText(toolLabel, error.localizedDescription)
                displayResult = content
                if let skillError = error as? SkillExecutionError {
                    switch skillError {
                    case .executionDenied, .userDenied:
                        resultDisposition = .rejected
                    case .userSupplementRequested:
                        resultDisposition = .rejected
                        shouldAwaitUserSupplement = true
                    default:
                        break
                    }
                }
                logger.error("  - Agent Skills 调用失败: \(error.localizedDescription)")
            }

        case _ where AppToolManager.isBuiltInToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                AppToolManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let approvalPolicy = await MainActor.run {
                AppToolManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }
            switch approvalPolicy {
            case .alwaysDeny:
                content = policyDeniedText(toolLabel)
                displayResult = content
                resultDisposition = .rejected
                logger.info("  - 拓展工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    try Task.checkCancellation()
                    guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
                    let result = try await AppToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments,
                        sourceSessionID: sessionID,
                        sourceMessageID: triggeringMessageID,
                        admission: admission
                    )
                    content = result
                    displayResult = result
                    logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: toolLabel,
                    arguments: toolCall.arguments,
                    sourceSessionID: sessionID,
                    toolCallID: toolCall.id
                )
                switch permissionDecision {
                case .deny:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    resultDisposition = .rejected
                    logger.info("  - 拓展工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    resultDisposition = .rejected
                    shouldAwaitUserSupplement = true
                    logger.info("  - 拓展工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        try Task.checkCancellation()
                        guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
                        let result = try await AppToolManager.shared.executeToolFromChat(
                            toolName: toolCall.toolName,
                            argumentsJSON: toolCall.arguments,
                            sourceSessionID: sessionID,
                            sourceMessageID: triggeringMessageID,
                            admission: admission
                        )
                        content = result
                        displayResult = result
                        logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                    } catch {
                        content = callFailedText(toolLabel, error.localizedDescription)
                        displayResult = content
                        logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                    }
                }
            }

        default:
            content = String(format: NSLocalizedString("错误：未知的工具名称 %@。", comment: "Unknown tool result"), toolCall.toolName)
            displayResult = content
            logger.error("  - 未知的工具名称: \(toolCall.toolName)")
        }

        // A permission prompt or an executor may have suspended while the
        // source was removed or the request was replaced. Do not continue the
        // model turn using a result for a no-longer-current call.
        guard permitsToolCall(toolCall, messageID: sourceMessageID, sessionID: sessionID) else { return nil }
        let message = ChatMessage(
            role: .tool,
            content: content,
            toolCalls: [
                InternalToolCall(
                    id: toolCall.id,
                    toolName: toolCall.toolName,
                    arguments: toolCall.arguments,
                    result: displayResult,
                    resultDisposition: resultDisposition,
                    providerSpecificFields: toolCall.providerSpecificFields
                )
            ]
        )

        return ToolCallOutcome(
            message: message,
            toolResult: displayResult,
            resultDisposition: resultDisposition,
            shouldAwaitUserSupplement: shouldAwaitUserSupplement,
            outcomeUnknown: outcomeUnknown
        )
    }

    func attachToolResult(
        _ result: String,
        disposition: InternalToolCallResultDisposition,
        to toolCallID: String,
        toolName _: String,
        loadingMessageID: UUID,
        sessionID: UUID
    ) async {
        await updateToolResult(result, disposition: disposition, toolCallID: toolCallID,
                               messageID: loadingMessageID, sessionID: sessionID)
    }

}
