// ============================================================================
// ChatViewInputBar.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 底部输入栏在普通聊天与工具问答输入之间的切换。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatView {
    @MainActor
    func reloadCurrentLocalAgentMode() async {
        guard let sessionID = viewModel.currentSession?.id else {
            currentLocalAgentMode = .chat
            return
        }

        let selectionRevision = localAgentModeSelectionRevision
        guard !Task.isCancelled,
              viewModel.currentSession?.id == sessionID,
              localAgentModeSelectionRevision == selectionRevision else { return }

        let storedMode = await Task.detached(priority: .userInitiated) {
            Persistence.localAgentMode(sessionID: sessionID)
        }.value
        // 用户在异步读取期间做出的选择优先，旧快照不能把 Agent 悄悄改回 Chat。
        guard !Task.isCancelled,
              viewModel.currentSession?.id == sessionID,
              localAgentModeSelectionRevision == selectionRevision else { return }
        currentLocalAgentMode = storedMode
    }

    /// Telegram 风格输入栏
    @ViewBuilder
    func telegramInputBar(availableHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            if viewModel.isSendingMessage || viewModel.isSendDelayPending || viewModel.isSendSubmissionPending {
                Text(NSLocalizedString("当前会话正在处理，请稍后再发送。", comment: "Session busy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TelegramMessageComposer(
                submissionState: viewModel.sendSubmissionState,
                sendFlightController: sendFlightController,
                text: Binding(
                    get: { draftText },
                    set: { newValue in
                        draftText = newValue
                    }
                ),
                isRequestControlsExpanded: $isComposerRequestControlsExpanded,
                localAgentMode: Binding(
                    get: { currentLocalAgentMode },
                    set: { mode in
                        guard currentLocalAgentMode != mode else { return }
                        localAgentModeSelectionRevision &+= 1
                        currentLocalAgentMode = mode
                    }
                ),
                sendAction: {
                    guard viewModel.canSendMessage else { return false }
                    scrollCoordinator.shouldKeepBottomPinned = true
                    scrollCoordinator.showScrollToBottom = false
                    let outgoingText = draftText
                    if AppConfigStore.shared.chatSendAnimationEnabled,
                       AppConfigStore.shared.chatSendDelaySeconds <= 0 {
                        // 启动「输入框 → 气泡」Overlay 飞行（内部已调用 viewModel.sendMessage()）
                        return beginSendFlight(
                            text: outgoingText,
                            localAgentMode: currentLocalAgentMode
                        )
                    } else {
                        return viewModel.sendMessage(localAgentMode: currentLocalAgentMode)
                    }
                },
                stopAction: {
                    cancelSendFlight()
                    viewModel.cancelSending()
                },
                slashCommandAction: performSlashCommand,
                focus: $composerFocused,
                availableHeight: availableHeight
            )
            .padding(.bottom, -tabBarCompensation)
        }
    }

    /// 收起键盘和输入栏临时面板；外部点击只改变输入状态，不触发消息内容。
    func dismissComposerInput() {
        composerFocused = false
        guard isComposerRequestControlsExpanded else { return }
        let animation: Animation = accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.94)
        withAnimation(animation) {
            isComposerRequestControlsExpanded = false
        }
    }
}
