// ============================================================================
// ChatViewSlashCommands.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件把已识别的 iOS 斜杠命令映射到聊天页现有操作。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatView {
    func performSlashCommand(_ command: ChatSlashCommand) {
        draftText = ""
        viewModel.userInput = ""

        switch command {
        case .new:
            composerFocused = false
            viewModel.createNewSession()
        case .model:
            composerFocused = false
            presentModelPickerSheet()
        case .sessions:
            composerFocused = false
            if usesLandscapeSessionSidebar {
                withAnimation(chatPickerAnimation) {
                    isLandscapeSessionSidebarPresented = true
                }
            } else {
                presentSessionPicker()
            }
        case .settings:
            presentSlashCommandDestination(.settings)
        case .tools:
            presentSlashCommandDestination(.toolCenter)
        case .daily:
            presentSlashCommandDestination(.dailyPulse)
        case .usage:
            presentSlashCommandDestination(.usageAnalytics)
        case .skills:
            presentSlashCommandDestination(.agentSkills)
        case .shortcuts:
            presentSlashCommandDestination(.shortcuts)
        case .roleplay:
            presentSlashCommandDestination(.roleplay)
        case .features:
            presentSlashCommandDestination(.extendedFeatures)
        case .temporary:
            performTemporaryChatSlashCommand()
        case .retry:
            guard viewModel.canQuickRetryLatestMessage else {
                showUnavailableSlashCommandNotice(
                    NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
                )
                return
            }
            viewModel.quickRetryLatestMessage()
        case .stop:
            guard viewModel.isSendingMessage || viewModel.isSendDelayPending else {
                showUnavailableSlashCommandNotice(
                    NSLocalizedString("当前没有正在生成的回复。", comment: "No active response to stop")
                )
                return
            }
            viewModel.cancelSending()
        case .clear:
            viewModel.clearAllAttachments()
        }
    }

    private func presentSlashCommandDestination(_ destination: ChatQuickAction) {
        composerFocused = false
        navigationDestination = destination
    }

    private func performTemporaryChatSlashCommand() {
        guard isQuickActionAvailable(.temporaryChat) else {
            showUnavailableSlashCommandNotice(
                NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "Temporary chat slash command unavailable")
            )
            return
        }
        performTemporaryChatTap()
    }

    private func showUnavailableSlashCommandNotice(_ message: String) {
        showChatTransientNotice(
            ChatTransientNotice(
                message: message,
                systemImage: "exclamationmark.circle",
                tint: .orange
            )
        )
    }
}
