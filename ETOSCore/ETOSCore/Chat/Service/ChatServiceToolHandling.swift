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
        let shouldPauseForConversation: Bool
    }

    static func mcpResultDisposition(for rawResult: String) -> InternalToolCallResultDisposition {
        MCPToolResultFormatter.isErrorResult(rawResult) ? .failed : .completed
    }
    
    /// 处理单个工具调用
    func handleToolCall(
        _ toolCall: InternalToolCall,
        sessionID: UUID? = nil,
        agentRunID: UUID? = nil,
        triggeringMessageID: UUID? = nil
    ) async -> ToolCallOutcome {
        logger.info("正在处理工具调用: \(toolCall.toolName)")

        var content = ""
        var displayResult: String?
        var resultDisposition: InternalToolCallResultDisposition = .completed
        var shouldAwaitUserSupplement = false
        var shouldPauseForConversation = false
        let policyDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 已被策略禁止调用。", comment: "Tool result when policy denies a call"), $0)
        }
        let callFailedText: (String, String) -> String = {
            String(format: NSLocalizedString("%@ 调用失败：%@", comment: "Tool result when a call fails"), $0, $1)
        }
        let userDeniedText: (String) -> String = {
            String(format: NSLocalizedString("%@ 调用已被用户拒绝。", comment: "Tool result when user denies a call"), $0)
        }

        if let agentRunID,
           !(await SkillAllowedToolRuntime.shared.isToolAllowed(
                toolCall.toolName,
                runID: agentRunID,
                exemptToolNames: [SkillManager.chatToolName, OpenAIResponsesLocalShellProtocol.toolName]
           )) {
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
                shouldAwaitUserSupplement: false,
                shouldPauseForConversation: false
            )
        }

        switch toolCall.toolName {
        case OpenAIResponsesLocalShellProtocol.toolName:
            guard let sessionID, let agentRunID else {
                content = callFailedText(
                    NSLocalizedString("Responses 本地 Shell", comment: "Responses local shell tool label"),
                    NSLocalizedString("缺少可信的 Agent Run 归属。", comment: "Responses local shell missing Agent run")
                )
                displayResult = content
                break
            }
            let execution = await executeResponsesLocalShellCall(
                toolCall,
                sessionID: sessionID,
                runID: agentRunID,
                triggeringMessageID: triggeringMessageID
            )
            content = execution.content
            displayResult = execution.content
            resultDisposition = execution.resultDisposition
            shouldAwaitUserSupplement = execution.shouldAwaitUserSupplement

        case _ where MCPManager.isMCPToolName(toolCall.toolName):
            let presentedArguments = MCPToolCallTitleMetadata.parse(argumentsJSON: toolCall.arguments)
            let executableArguments = presentedArguments.argumentsJSON
            let toolLabel = await MainActor.run {
                MCPManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let approvalPolicy = await MainActor.run {
                MCPManager.shared.approvalPolicy(for: toolCall.toolName) ?? .askEveryTime
            }
            let isConversationTool = await MainActor.run {
                MCPManager.shared.isConversationTool(toolCall.toolName)
            }
            let localLinuxToolID = await MainActor.run {
                MCPManager.shared.localLinuxToolID(for: toolCall.toolName)
            }
            let commandRuleMatch: LocalLinuxCommandRuleMatch?
            if let localLinuxToolID {
                commandRuleMatch = try? await LocalLinuxToolExecutor.shared.commandRuleMatch(
                    toolName: localLinuxToolID,
                    argumentsJSON: executableArguments
                )
            } else {
                commandRuleMatch = nil
            }
            let needsCommandRuleConfirmation = commandRuleMatch?.action == .confirm
            let effectiveApprovalPolicy: MCPToolApprovalPolicy =
                needsCommandRuleConfirmation && approvalPolicy == .alwaysAllow
                ? .askEveryTime
                : approvalPolicy
            let approvalDisplayName: String
            if let commandRuleMatch, needsCommandRuleConfirmation {
                approvalDisplayName = String(
                    format: NSLocalizedString("%@（命中命令规则：%@）", comment: "Linux tool approval label with matching command rule"),
                    toolLabel,
                    commandRuleMatch.ruleName
                )
            } else {
                approvalDisplayName = toolLabel
            }
            let approvedCommandRuleIDs: Set<UUID>
            if let commandRuleMatch, commandRuleMatch.action == .confirm {
                approvedCommandRuleIDs = [commandRuleMatch.ruleID]
            } else {
                approvedCommandRuleIDs = []
            }

            switch effectiveApprovalPolicy {
            case .alwaysDeny:
                content = policyDeniedText(toolLabel)
                displayResult = content
                resultDisposition = .rejected
                logger.info("  - MCP 工具调用被策略拒绝: \(toolCall.toolName)")
            case .alwaysAllow:
                do {
                    let result = try await MCPManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: executableArguments,
                        sourceSessionID: sessionID,
                        sourceToolCallID: toolCall.id,
                        sourceAgentRunID: agentRunID,
                        triggeringMessageID: triggeringMessageID,
                        approvedLocalLinuxCommandRuleIDs: []
                    )
                    content = result
                    shouldPauseForConversation = isConversationTool
                        && sessionID.flatMap(Persistence.loadLatestConversationRun)?.status == .waitingConversation
                    displayResult = shouldPauseForConversation ? nil : result
                    resultDisposition = Self.mcpResultDisposition(for: result)
                    if resultDisposition == .failed {
                        logger.error("  - MCP 工具返回执行错误: \(toolCall.toolName)")
                    } else {
                        logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                    }
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    resultDisposition = .failed
                    logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
                let permissionDecision = await ToolPermissionCenter.shared.requestPermission(
                    toolName: toolCall.toolName,
                    displayName: approvalDisplayName,
                    arguments: executableArguments,
                    sourceSessionID: sessionID,
                    toolCallID: toolCall.id
                )
                switch permissionDecision {
                case .deny:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    resultDisposition = .rejected
                    logger.info("  - MCP 工具调用被用户拒绝: \(toolCall.toolName)")
                case .supplement:
                    content = userDeniedText(toolLabel)
                    displayResult = content
                    resultDisposition = .rejected
                    shouldAwaitUserSupplement = true
                    logger.info("  - MCP 工具调用被用户拒绝并等待补充: \(toolCall.toolName)")
                case .allowOnce, .allowForTool, .allowAll:
                    do {
                        let result = try await MCPManager.shared.executeToolFromChat(
                            toolName: toolCall.toolName,
                            argumentsJSON: executableArguments,
                            sourceSessionID: sessionID,
                            sourceToolCallID: toolCall.id,
                            sourceAgentRunID: agentRunID,
                            triggeringMessageID: triggeringMessageID,
                            approvedLocalLinuxCommandRuleIDs: approvedCommandRuleIDs
                        )
                        content = result
                        shouldPauseForConversation = isConversationTool
                            && sessionID.flatMap(Persistence.loadLatestConversationRun)?.status == .waitingConversation
                        displayResult = shouldPauseForConversation ? nil : result
                        resultDisposition = Self.mcpResultDisposition(for: result)
                        if resultDisposition == .failed {
                            logger.error("  - MCP 工具返回执行错误: \(toolCall.toolName)")
                        } else {
                            logger.info("  - MCP 工具调用成功: \(toolCall.toolName)")
                        }
                    } catch {
                        content = callFailedText(toolLabel, error.localizedDescription)
                        displayResult = content
                        resultDisposition = .failed
                        logger.error("  - MCP 工具调用失败: \(error.localizedDescription)")
                    }
                }
            }

        case _ where ShortcutToolManager.isShortcutToolName(toolCall.toolName):
            let toolLabel = await ShortcutToolManager.shared.displayLabel(for: toolCall.toolName) ?? toolCall.toolName
            let shortcutToolsEnabled = await MainActor.run { ShortcutToolManager.shared.chatToolsEnabled }
            guard shortcutToolsEnabled else {
                content = NSLocalizedString("快捷指令工具总开关已关闭。", comment: "Shortcut tool disabled result")
                displayResult = content
                logger.info("  - 快捷指令工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
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
                    let result = try await ShortcutToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments
                    )
                    content = result
                    displayResult = result
                    logger.info("  - 快捷指令工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
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
                let result = try await SkillManager.shared.executeToolFromChat(
                    toolName: toolCall.toolName,
                    argumentsJSON: toolCall.arguments,
                    sourceSessionID: sessionID,
                    sourceAgentRunID: agentRunID,
                    triggeringMessageID: triggeringMessageID,
                    sourceToolCallID: toolCall.id
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

        case _ where AppToolManager.isAppToolName(toolCall.toolName):
            let toolLabel = await MainActor.run {
                AppToolManager.shared.displayLabel(for: toolCall.toolName)
            } ?? toolCall.toolName
            let isBuiltInAppTool = AppToolManager.isBuiltInToolName(toolCall.toolName)
            let appToolsEnabled = await MainActor.run { AppToolManager.shared.chatToolsEnabled }
            guard appToolsEnabled || isBuiltInAppTool else {
                content = NSLocalizedString("拓展工具总开关已关闭。", comment: "App tool disabled result")
                displayResult = content
                logger.info("  - 拓展工具调用被总开关拒绝: \(toolCall.toolName)")
                break
            }
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
                    let result = try await AppToolManager.shared.executeToolFromChat(
                        toolName: toolCall.toolName,
                        argumentsJSON: toolCall.arguments,
                        sourceSessionID: sessionID,
                        sourceMessageID: triggeringMessageID
                    )
                    content = result
                    displayResult = result
                    if toolCall.toolName == AppToolKind.askUserInput.toolName {
                        shouldAwaitUserSupplement = true
                    }
                    logger.info("  - 拓展工具调用成功: \(toolCall.toolName)")
                } catch {
                    content = callFailedText(toolLabel, error.localizedDescription)
                    displayResult = content
                    logger.error("  - 拓展工具调用失败: \(error.localizedDescription)")
                }
            case .askEveryTime:
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
                        let result = try await AppToolManager.shared.executeToolFromChat(
                            toolName: toolCall.toolName,
                            argumentsJSON: toolCall.arguments,
                            sourceSessionID: sessionID,
                            sourceMessageID: triggeringMessageID
                        )
                        content = result
                        displayResult = result
                        if toolCall.toolName == AppToolKind.askUserInput.toolName {
                            shouldAwaitUserSupplement = true
                        }
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
            shouldPauseForConversation: shouldPauseForConversation
        )
    }

    func attachToolResult(
        _ result: String,
        disposition: InternalToolCallResultDisposition,
        to toolCallID: String,
        toolName: String,
        loadingMessageID: UUID,
        sessionID: UUID
    ) async {
        let messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        guard var toolCalls = message.toolCalls else { return }
        var callIndex = toolCalls.firstIndex(where: { $0.id == toolCallID })
        if callIndex == nil {
            let matchedByName = toolCalls.enumerated().filter { $0.element.toolName == toolName }
            if matchedByName.count == 1 {
                callIndex = matchedByName.first?.offset
                logger.warning("未找到匹配的工具调用 ID，已按名称 '\(toolName)' 回退匹配结果。")
            }
        }
        guard let resolvedIndex = callIndex else { return }
        toolCalls[resolvedIndex].result = result
        toolCalls[resolvedIndex].resultDisposition = disposition
        message.toolCalls = toolCalls
        do {
            _ = try await upsertConversationMessage(message, to: sessionID)
        } catch {
            logger.error("原子保存工具结果失败：\(error.localizedDescription)")
        }
    }

    func ensureToolCallsVisible(_ toolCalls: [InternalToolCall], in loadingMessageID: UUID, sessionID: UUID) async {
        guard !toolCalls.isEmpty else { return }
        let messages = messagesSnapshot(for: sessionID)
        guard let messageIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) else { return }
        var message = messages[messageIndex]
        var existingCalls = message.toolCalls ?? []
        var didChange = false

        for call in toolCalls {
            if let existingIndex = existingCalls.firstIndex(where: { $0.id == call.id }) {
                let existingResult = existingCalls[existingIndex].result
                let existingResultDisposition = existingCalls[existingIndex].resultDisposition
                if existingCalls[existingIndex].toolName != call.toolName
                    || existingCalls[existingIndex].arguments != call.arguments
                    || existingCalls[existingIndex].providerSpecificFields != call.providerSpecificFields {
                    existingCalls[existingIndex] = InternalToolCall(
                        id: call.id,
                        toolName: call.toolName,
                        arguments: call.arguments,
                        result: existingResult,
                        resultDisposition: existingResultDisposition,
                        providerSpecificFields: call.providerSpecificFields
                    )
                    didChange = true
                }
            } else {
                existingCalls.append(call)
                didChange = true
            }
        }

        guard didChange else { return }
        message.toolCalls = existingCalls
        do {
            _ = try await upsertConversationMessage(message, to: sessionID)
        } catch {
            logger.error("原子保存工具调用失败：\(error.localizedDescription)")
        }
    }
}
