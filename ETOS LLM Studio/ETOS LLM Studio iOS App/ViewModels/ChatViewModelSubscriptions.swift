// ============================================================================
// ChatViewModelSubscriptions.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承接 ChatViewModel 的订阅绑定、启动恢复、生命周期监听与全局状态
// 快照同步逻辑。
// ============================================================================

import Combine
import Foundation
import SwiftUI
import ETOSCore
#if canImport(UIKit)
import UIKit
#endif

extension ChatViewModel {
    func applyAppConfigSnapshotToLocalState() {
        let appConfig = AppConfigStore.shared
        enableMarkdown = appConfig.enableMarkdown
        enableAdvancedRenderer = appConfig.enableAdvancedRenderer
        enableExperimentalToolResultDisplay = appConfig.enableExperimentalToolResultDisplay
        enableAutoReasoningPreview = appConfig.enableAutoReasoningPreview
        enableBackground = appConfig.enableBackground
        backgroundBlur = appConfig.backgroundBlur
        backgroundOpacity = appConfig.backgroundOpacity
        backgroundContentMode = appConfig.backgroundContentMode
        aiTemperature = appConfig.aiTemperature
        aiTopP = appConfig.aiTopP
        aiTemperatureEnabled = appConfig.aiTemperatureEnabled
        aiTopPEnabled = appConfig.aiTopPEnabled
        maxChatHistory = appConfig.maxChatHistory
        enableStreaming = appConfig.enableStreaming
        enableResponseSpeedMetrics = appConfig.enableResponseSpeedMetrics
        enableOpenAIStreamIncludeUsage = appConfig.enableOpenAIStreamIncludeUsage
        automaticHistoryLoadingEnabled = appConfig.automaticHistoryLoadingEnabled
        lazyLoadMessageCount = appConfig.lazyLoadMessageCount
        currentBackgroundImage = appConfig.currentBackgroundImage
        enableAutoRotateBackground = appConfig.enableAutoRotateBackground
        enableAutoSessionNaming = appConfig.enableAutoSessionNaming
        enableReasoningSummary = appConfig.enableReasoningSummary
        enableLiquidGlass = appConfig.enableLiquidGlass
        enableChatTopBlurFade = appConfig.enableChatTopBlurFade
        enableNoBubbleUI = appConfig.enableNoBubbleUI
        sendSpeechAsAudio = appConfig.sendSpeechAsAudio
        enableSpeechInput = appConfig.enableSpeechInput
        speechModelIdentifier = appConfig.speechModelIdentifier
        titleGenerationModelIdentifier = appConfig.titleGenerationModelIdentifier
        dailyPulseModelIdentifier = appConfig.dailyPulseModelIdentifier
        reasoningSummaryModelIdentifier = appConfig.reasoningSummaryModelIdentifier
        ocrModelIdentifier = appConfig.ocrModelIdentifier
        includeSystemTimeInPrompt = appConfig.includeSystemTimeInPrompt
        systemTimeInjectionPositionRawValue = appConfig.systemTimeInjectionPosition
        enablePeriodicTimeLandmark = appConfig.enablePeriodicTimeLandmark
        periodicTimeLandmarkIntervalMinutes = appConfig.periodicTimeLandmarkIntervalMinutes
        audioRecordingFormatRaw = appConfig.audioRecordingFormat
        enableBackgroundReplyNotification = appConfig.enableBackgroundReplyNotification
        hasRequestedBackgroundReplyNotificationPermission = appConfig.hasRequestedBackgroundReplyNotificationPermission
    }

    func refreshAfterAppConfigPersistentStoreLoad() {
        applyAppConfigSnapshotToLocalState()
        BackgroundGenerationKeepAliveManager.shared.setGenerationActive(!runningSessionIDs.isEmpty)
        BackgroundGenerationAudioKeepAliveManager.shared.setGenerationActive(!runningSessionIDs.isEmpty)
        providers = chatService.providersSubject.value
        applyActivatedConversationModels(chatService.activatedConversationModels)
        selectedModel = chatService.selectedModelSubject.value
        MessageRegexRuleStore.shared.reload()
        refreshVisualMessagesAfterRegexRulesChange()
        syncSpeechModelSelection()
        syncTitleGenerationModelSelection()
        syncDailyPulseModelSelection()
        syncReasoningSummaryModelSelection()
        syncOCRModelSelection()
        rotateBackgroundImageIfNeeded()
    }

    func reloadAfterSnapshotRestore() {
        AppConfigStore.shared.reloadFromPersistentStore()
        chatService.reloadProviders()
        DailyPulseManager.shared.reloadPersistedRuns()
        DailyPulseDeliveryCoordinator.shared.reloadFromStorage()
    }

    func registerLifecycleObservers() {
#if canImport(UIKit)
        isApplicationActive = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }

    @objc func handleWillResignActive() {
        isApplicationActive = false
    }

    @objc func handleDidEnterBackground() {
        isApplicationActive = false
    }

    @objc func handleWillEnterForeground() {
        isApplicationActive = false
    }

    @objc func handleDidBecomeActive() {
        isApplicationActive = true
        BackgroundGenerationKeepAliveManager.shared.refreshStatus()
        clearCurrentSessionReplyNotifications()
    }

    private func clearCurrentSessionReplyNotifications() {
        guard let sessionID = currentSession?.id else { return }
        Task {
            await AppLocalNotificationCenter.shared.removeChatReplyNotifications(sessionID: sessionID)
        }
    }

    func observeUserMessagePreviewCharacterLimit() {
        AppConfigStore.shared.$userMessagePreviewCharacterLimit
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // 包含暂时离开历史窗口的缓存，返回聊天时不会继续显示旧阈值的预览。
                for state in self.messageStateByID.values where state.message.role == .user {
                    self.scheduleVisualMessagePreparationIfNeeded(for: state, source: state.message)
                }
                self.messageRenderingRefreshSubject.send(())
            }
            .store(in: &cancellables)
    }

    func setupSubscriptions() {
        observeUserMessagePreviewCharacterLimit()
        Publishers.CombineLatest(chatService.unknownToolOutcomesSubject, chatService.currentSessionSubject)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes, session in
                self?.unknownToolOutcome = session.flatMap { outcomes[$0.id]?.first }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AppConfigStore.persistentStoreDidLoadNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshAfterAppConfigPersistentStoreLoad()
            }
            .store(in: &cancellables)
        if AppConfigStore.shared.didLoadPersistentStore {
            refreshAfterAppConfigPersistentStoreLoad()
        }

        NotificationCenter.default.publisher(for: .snapshotRestoreDidFinish)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadAfterSnapshotRestore()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: MessageRegexRuleStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisualMessagesAfterRegexRulesChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String
                        == RoleplayStore.libraryChangeKind else { return }
                self?.refreshVisualMessagesAfterRegexRulesChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RoleplayDisplayedMessageBridge.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID == self.currentSession?.id else { return }
                self.refreshVisualMessagesAfterRegexRulesChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: RoleplayBridgeNotification.requestedAction)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleRoleplayBridgeAction(notification)
            }
            .store(in: &cancellables)

        chatService.chatSessionsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.applyChatSessions(sessions)
            }
            .store(in: &cancellables)

        chatService.sessionFoldersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] folders in
                self?.applySessionFolders(folders)
            }
            .store(in: &cancellables)

        chatService.sessionTagsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tags in
                self?.applySessionTags(tags)
            }
            .store(in: &cancellables)

        chatService.currentSessionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                beginHistorySession(session?.id)
                currentSession = session
                refreshSessionScopedAppToolRequests()
                imageGenerationFeedback = .idle
                refreshCurrentSessionSendingState()
#if canImport(UIKit)
                if UIApplication.shared.applicationState == .active {
                    clearCurrentSessionReplyNotifications()
                }
#endif
            }
            .store(in: &cancellables)

        chatService.messagesForSessionSubject
            .map { [chatService] messages in
                (
                    sessionID: chatService.currentSessionSubject.value?.id,
                    messages: messages,
                    forceRendering: false
                )
            }
            .merge(with: messageRenderingRefreshSubject.map { [chatService] _ in
                (
                    sessionID: chatService.currentSessionSubject.value?.id,
                    messages: chatService.messagesForSessionSubject.value,
                    forceRendering: true
                )
            })
            .receive(on: messagePreparationQueue)
            .scan(Optional<ChatMessageListSnapshot>.none) { @Sendable previous, update in
                ChatMessageListSnapshot(
                    messages: update.messages, sessionID: update.sessionID, previous: previous,
                    renderConfiguration: .load(sessionID: update.sessionID), forceRendering: update.forceRendering,
                    previewCharacterLimit: ChatUserMessagePreview.configuredCharacterLimit,
                    visualRules: MessageRegexRuleStore.currentRules()
                )
            }
            .compactMap { @Sendable snapshot in snapshot }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self else { return }
                guard update.sessionID == chatService.currentSessionSubject.value?.id else { return }
                applyMessagesUpdate(update)
            }
            .store(in: &cancellables)

        chatService.providersSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] providers in
                guard let self else { return }
                self.providers = providers
                self.applyConfiguredModels(chatService.configuredRunnableModels)
                self.applyActivatedModels(chatService.activatedRunnableModels)
                self.applyActivatedConversationModels(chatService.activatedConversationModels)
                self.applyActivatedChatModels(chatService.activatedChatModels)
                self.speechModels = chatService.activatedSpeechModels
                self.syncSpeechModelSelection()
                self.syncTitleGenerationModelSelection()
                self.syncDailyPulseModelSelection()
                self.syncReasoningSummaryModelSelection()
                self.syncOCRModelSelection()
            }
            .store(in: &cancellables)

        AppConfigStore.shared.$modelPickerFolderPathsByProvider
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyConfiguredModels(self.configuredModels)
            }
            .store(in: &cancellables)

        chatService.selectedModelSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] model in
                guard let self else { return }
                selectedModel = model
            }
            .store(in: &cancellables)

        chatService.runningSessionIDsSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runningSessionIDs in
                guard let self else { return }
                self.runningSessionIDs = runningSessionIDs
                refreshCurrentSessionSendingState()
                refreshBackgroundGenerationState()
                updateAutoReasoningPreviewState()
            }
            .store(in: &cancellables)

        chatService.conversationRuntimeStatesSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                self?.conversationRuntimeStates = states
            }
            .store(in: &cancellables)

        chatService.sessionRequestStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event.status {
                case .started:
                    prepareBackgroundReplyNotificationContext(for: event.sessionID, messages: event.messages)
                case .finished:
                    if event.sessionID == currentSession?.id {
                        notifyIfAssistantReplyFinishedInBackground(for: event.sessionID, messages: event.messages)
                        autoPlayLatestAssistantMessageIfNeeded()
                    } else {
                        notifyIfAssistantReplyFinishedFromOffscreenSession(event.sessionID, messages: event.messages)
                    }
                case .error, .cancelled:
                    pendingReplyNotificationContextBySessionID.removeValue(forKey: event.sessionID)
                @unknown default:
                    pendingReplyNotificationContextBySessionID.removeValue(forKey: event.sessionID)
                }
                refreshBackgroundGenerationState()
            }
            .store(in: &cancellables)

        chatService.imageGenerationStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyImageGenerationStatus(status)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncBackgroundsUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshBackgroundImages()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appToolFillUserInputRequested)
            .sink { [weak self] notification in
                guard let self,
                      let request = AppToolInputDraftRequest.decode(from: notification.userInfo),
                      let receipt = AppToolUIRequestDeliveryReceipt.decode(from: notification.userInfo) else { return }
                receiveToolInputDraftRequest(request, receipt: receipt)
            }
            .store(in: &cancellables)

        syncSpeechModelSelection()
        syncTitleGenerationModelSelection()
        syncDailyPulseModelSelection()
        syncReasoningSummaryModelSelection()
        syncOCRModelSelection()
    }

    private func handleRoleplayBridgeAction(_ notification: Notification) {
        guard let sessionID = notification.userInfo?[RoleplayBridgeNotification.sessionIDKey] as? UUID,
              sessionID == currentSession?.id,
              let action = notification.userInfo?[RoleplayBridgeNotification.actionKey] as? String else { return }
        let text = notification.userInfo?[RoleplayBridgeNotification.textKey] as? String ?? ""
        switch action {
        case "set_input":
            userInput = text
        case "send_message":
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let lease: ChatRequestLease
            switch chatService.beginRequest(sessionID: sessionID) {
            case .success(let acquired): lease = acquired
            case .failure(.busy):
                messageEditErrorMessage = NSLocalizedString("当前会话正在处理，请稍后再发送。", comment: "Session busy")
                return
            case .failure(.sessionMissing):
                messageEditErrorMessage = NSLocalizedString("会话已不存在，内容未发送。", comment: "Missing send session")
                return
            }
            Task { [weak self] in
                guard let self else { lease.release(); return }
                await chatService.sendAndProcessMessage(
                    content: text, aiTemperature: aiTemperature, aiTopP: aiTopP,
                    maxChatHistory: maxChatHistory, enableStreaming: enableStreaming,
                    includeSystemTime: includeSystemTimeInPrompt,
                    systemTimeInjectionPosition: systemTimeInjectionPosition,
                    enablePeriodicTimeLandmark: enablePeriodicTimeLandmark,
                    periodicTimeLandmarkIntervalMinutes: periodicTimeLandmarkIntervalMinutes,
                    enableResponseSpeedMetrics: enableResponseSpeedMetrics,
                    targetSessionID: sessionID, requestLease: lease
                )
            }
        case "generate":
            messageEditErrorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
        default:
            return
        }
    }

    func applyChatSessions(_ sessions: [ChatSession]) {
        guard chatSessions != sessions else { return }
        chatSessions = sessions
        chatSessionListVersion &+= 1
    }

    func applySessionFolders(_ folders: [SessionFolder]) {
        guard sessionFolders != folders else { return }
        sessionFolders = folders
        sessionFolderListVersion &+= 1
    }

    func applySessionTags(_ tags: [SessionTag]) {
        guard sessionTags != tags else { return }
        sessionTags = tags
        chatSessionListVersion &+= 1
    }

    func applyActivatedModels(_ models: [RunnableModel]) {
        let ids = models.map(\.id)
        let identityChanged = activatedModelIDs != ids
        activatedModels = models
        if identityChanged {
            activatedModelIDs = ids
            activatedModelListVersion &+= 1
        }
    }

    func applyConfiguredModels(_ models: [RunnableModel]) {
        configuredModels = models
        let groups = RunnableModelGrouping.groups(models: models, providerOrder: providers)
        configuredModelsByProviderID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.models) })
        configuredModelsByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        configuredModelOrganizationsByProviderID = Dictionary(
            uniqueKeysWithValues: groups.map {
                (
                    $0.id,
                    RunnableModelPickerOrganization(
                        models: $0.models,
                        groupPaths: AppConfigStore.shared.modelPickerFolderPaths(for: $0.id),
                        itemOrderIDs: AppConfigStore.shared.modelPickerItemOrderIDs(for: $0.id)
                    )
                )
            }
        )
    }

    func applyActivatedConversationModels(_ models: [RunnableModel]) {
        activatedConversationModels = models
        let groups = RunnableModelGrouping.groups(models: models, providerOrder: providers)
        activatedConversationModelGroups = groups
        activatedConversationModelsByProviderID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.models) })
        activatedConversationModelLayoutsByProviderID = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, $0.pickerLayout) }
        )
    }

    func applyActivatedChatModels(_ models: [RunnableModel]) {
        activatedChatModels = models
    }

    func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard AppConfigStore.shared.didLoadPersistentStore else { return }
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let available = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = available.randomElement() ?? backgroundImages.randomElement() ?? ""
    }

    func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        guard AppConfigStore.shared.didLoadPersistentStore else {
            refreshBlurredBackgroundImage()
            return
        }
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
        refreshBlurredBackgroundImage()
    }
}
