// ============================================================================
// MacWorkspaceModel.swift
// ============================================================================
// 桌面窗口只持有展示状态；会话、模型、请求与数据库仍由 ETOSCore 管理。
// 先完成解锁及启动恢复，再创建 ChatService，避免锁定期间误初始化空配置。
// ============================================================================

import Combine
import ETOSCore
import Foundation

@MainActor
final class MacWorkspaceModel: ObservableObject {
    enum Phase { case loading, locked, recovery, ready }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var currentSession: ChatSession?
    @Published private(set) var isTemporaryChat = false
    @Published private(set) var providers: [Provider] = []
    @Published private(set) var models: [RunnableModel] = []
    @Published private(set) var sessionModelCatalog = MacSessionModelCatalog(models: [])
    @Published private(set) var effectiveModelName: String?
    @Published private(set) var selectedModelID: String?
    @Published private(set) var selectedModelSupportsPrefill = false
    @Published private(set) var selectedModelSupportsRewrite = false
    @Published private(set) var messages: [MacMessagePresentation] = []
    @Published private(set) var runningSessionIDs: Set<UUID> = []
    @Published private var sendingSessionIDs: Set<UUID> = []
    @Published private(set) var isRestoringData = false
    @Published private(set) var isExportingSnapshot = false
    @Published private var isEditingHistory = false
    var isMutatingHistory: Bool {
        get { isEditingHistory || slashCommands.actions.isWorking }
        set { isEditingHistory = newValue }
    }
    @Published private(set) var attachments: [MacComposerAttachment] = []
    @Published private(set) var audioAttachment: AudioAttachment?
    @Published private(set) var recoveryRequest: Persistence.LaunchRecoveryRequest?
    @Published var errorMessage: String?
    @Published private(set) var unknownToolOutcome: ChatUnknownToolOutcome?
    @Published var draft = "" {
        didSet {
            guard phase == .ready else { return }
            AppConfigStore.shared.chatComposerDraft = draft
        }
    }

    private(set) var service: ChatService?
    private var isStarting = false
    private var subscriptions = Set<AnyCancellable>()
    private var sourceMessages: [ChatMessage] = []
    private var presentationTask: Task<Void, Never>?
    private var modelListTask: Task<Void, Never>?
    private var presentationRevision = UUID()
    private let presentationStore = MacMessagePresentationStore()
    let sessionLibrary = MacSessionLibraryModel()
    let roleplayModel = MacRoleplayModel()
    let roleplayRuntime = MacRoleplayRuntime()
    let requestControls = MacRequestRuntimeModel()
    let modelTests = MacModelConnectivityTasks()
    let shortcutTools = MacShortcutToolsModel()
    let builtInTools = MacBuiltInToolsModel()
    let toolApproval = MacToolApprovalModel()
    let skills = MacSkillsModel()
    let globalProxy = MacGlobalProxyModel()
    let speechInput = MacSpeechInputModel()
    let tts = MacTTSModel()
    let backgrounds = MacBackgroundModel()
    let appearance = MacAppearanceModel()
    let fonts = MacFontModel()
    let linux = MacLinuxModel()
    let slashCommands = MacSlashCommandsModel()
    let dataImportOperations = MacDataImportOperations()
    let connectionSecurity = MacConnectionSecurityModel()
    private(set) var externalOpenRevision = UUID()
    lazy var incomingDocuments = MacIncomingDocumentsModel(
        applyAttachments: { [weak self] attachments in
            guard let self, canManageLocalModels, currentSession?.id == service?.currentSessionSubject.value?.id else { return }
            self.attachments.append(contentsOf: attachments)
        },
        reportError: { [weak self] in self?.errorMessage = $0 }
    )
    private var roleplayHostVisible = false
    private var roleplayLifecycleRevision = UUID()
    @Published private var isClosingRoleplay = false
    private var toolDrafts: [UUID: [AppToolInputDraftRequest]] = [:]
    private var sendTasks: [UUID: Task<Void, Never>] = [:]
    private var effectiveModel: RunnableModel?

    var isPreparingSend: Bool {
        currentSession.map { sendingSessionIDs.contains($0.id) } ?? false
    }

    var isGenerating: Bool {
        currentSession.map { runningSessionIDs.contains($0.id) } ?? false
    }

    var canSend: Bool {
        phase == .ready && !isRestoringData && !isMutatingHistory && !roleplayRuntime.isBusy && !sessionLibrary.isWorking && currentSession != nil && effectiveModel != nil && !isGenerating && !isPreparingSend
            && !requestControls.isWorking && !requestControls.isSuspended
            && !isImportingAttachments && !speechInput.isActive && (!draft.isEmpty || !attachments.isEmpty || audioAttachment != nil)
    }

    var canEditRequestControls: Bool {
        phase == .ready && !isRestoringData && !isExportingSnapshot && !isClosingRoleplay && !isPreparingSend
            && !requestControls.isSuspended && AppLockManager.shared.state != .locked
    }

    var canRunModelTests: Bool {
        phase == .ready && !isRestoringData && !isExportingSnapshot && !isClosingRoleplay
            && AppLockManager.shared.state != .locked
    }

    var canManageLocalModels: Bool {
        phase == .ready && !isRestoringData && !isExportingSnapshot && !isClosingRoleplay
            && AppLockManager.shared.state != .locked
    }

    var isImportingAttachments: Bool { incomingDocuments.isWorking }

    var canModifyCurrentHistory: Bool {
        !isRestoringData && !isMutatingHistory && !roleplayRuntime.isBusy && !sessionLibrary.isWorking && !isGenerating && !isPreparingSend
            && currentSession != nil && AppLockManager.shared.state != .locked
    }

    func start() async {
        guard !isStarting, phase != .ready else { return }
        isStarting = true
        defer { isStarting = false }
        phase = .loading
        let requiresUnlock = await Task.detached {
            DatabaseEncryptionManager.shared.requiresManualUnlock
        }.value
        if requiresUnlock { phase = .locked; return }
        let recovery = await Task.detached(priority: .userInitiated) {
            Persistence.bootstrapGRDBStoreOnLaunch()
            return Persistence.currentLaunchRecoveryRequest()
        }.value
        if let recovery { recoveryRequest = recovery; phase = .recovery; return }

        let configuration = AppConfigStore.shared
        await configuration.waitForPersistentStoreLoaded()
        AppLanguageRuntime.apply(rawValue: configuration.appLanguage)
        await builtInTools.start()
        await toolApproval.start()
        await skills.start()
        await shortcutTools.start()
        let service = await Task.detached(priority: .userInitiated) { ChatService.shared }.value
        self.service = service
        speechInput.start(service: service)
        tts.start()
        backgrounds.start()
        appearance.start()
        fonts.start()
        bind(service)
        sessionLibrary.start(service: service, workspace: self)
        roleplayModel.start(service: service, workspace: self)
        roleplayRuntime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        requestControls.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        linux.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        slashCommands.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        incomingDocuments.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        speechInput.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        tts.$isExportPanelOpen.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        fonts.$isImportPanelOpen.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        backgrounds.$isImportPanelOpen.combineLatest(backgrounds.$isPhotoPickerOpen, backgrounds.$cropDraft.map { $0 != nil })
            .map { $0.0 || $0.1 || $0.2 }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        configuration.$appLanguage.dropFirst().sink { [weak self] _ in self?.requestControls.reload() }.store(in: &subscriptions)
        configuration.$enableMarkdown.combineLatest(configuration.$userMessagePreviewCharacterLimit, configuration.$appLanguage)
            .dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        configuration.$enableAdvancedRenderer.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        appearance.$renderRevision.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        fonts.$renderRevision.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        sessionLibrary.$isWorking.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        draft = configuration.chatComposerDraft
        phase = .ready
        AppLockManager.shared.refreshState()
        resumeRequestControls()
        Task.detached(priority: .utility) {
            _ = Persistence.scheduleLaunchBackupPointAfterStartupIfEnabled()
        }
    }

    func restoreStartupBackup() async {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try Persistence.restorePendingLaunchBackupRequest()
            }.value
            recoveryRequest = nil
            await start()
        } catch { errorMessage = error.localizedDescription }
    }

    private func bind(_ service: ChatService) {
        Publishers.CombineLatest(service.unknownToolOutcomesSubject, service.currentSessionSubject)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes, session in
                self?.unknownToolOutcome = session.flatMap { outcomes[$0.id]?.first }
            }.store(in: &subscriptions)
        service.chatSessionsSubject.receive(on: DispatchQueue.main).sink { [weak self] sessions in
            self?.sessions = sessions
            self?.pruneToolInteractions()
        }.store(in: &subscriptions)
        service.currentSessionSubject.receive(on: DispatchQueue.main).sink { [weak self] session in
            if self?.currentSession?.id != session?.id {
                self?.speechInput.cancel()
                self?.tts.showSession(session?.id)
                self?.presentationTask?.cancel()
                self?.presentationRevision = UUID()
                self?.sourceMessages = []
                self?.messages = []
                self?.roleplayRuntime.showSession(session?.id, running: service.runningSessionIDsSubject.value)
            }
            self?.currentSession = session
            self?.incomingDocuments.updateSession(session?.id)
            self?.refreshEffectiveModel()
            self?.isTemporaryChat = service.isTemporaryChatEnabled(for: session?.id)
            self?.refreshToolInteractions()
        }.store(in: &subscriptions)
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] providers in
            self?.providers = providers
            self?.refreshModels()
            self?.refreshMessagePresentation()
        }.store(in: &subscriptions)
        AppConfigStore.shared.$messageActionBarSettings.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        service.selectedModelSubject.receive(on: DispatchQueue.main).sink { [weak self] model in
            self?.selectedModelID = model?.id
            self?.refreshEffectiveModel()
        }.store(in: &subscriptions)
        service.runningSessionIDsSubject.receive(on: DispatchQueue.main).sink { [weak self] ids in
            self?.runningSessionIDs = ids
            self?.refreshMessagePresentation()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .temporaryChatStateDidChange, object: service)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                isTemporaryChat = service.isTemporaryChatEnabled(for: currentSession?.id)
            }.store(in: &subscriptions)
        AppConfigStore.shared.$chatStreamingDisplayMode.removeDuplicates()
            .map { [weak service] mode -> AnyPublisher<(sessionID: UUID?, messages: [ChatMessage]), Never> in
                guard let service else { return Empty().eraseToAnyPublisher() }
                return service.messagesForSessionSubject
                    .map { [weak service] in (sessionID: service?.currentSessionSubject.value?.id, messages: $0) }
                    .throttle(for: .seconds(ChatStreamingDisplayMode.normalized(mode).uiPublishInterval),
                              scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self, currentSession?.id == event.sessionID else { return }
                sourceMessages = event.messages
                refreshMessagePresentation()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .appToolFillUserInputRequested).sink { [weak self] notification in
            guard let self, !isRestoringData,
                  let request = AppToolInputDraftRequest.decode(from: notification.userInfo),
                  let sessionID = request.sourceSessionID ?? currentSession?.id,
                  service.chatSessionsSubject.value.contains(where: { $0.id == sessionID && !$0.isEmbeddedSubagent }),
                  let receipt = AppToolUIRequestDeliveryReceipt.decode(from: notification.userInfo),
                  receipt.claim(currentSession?.id == sessionID ? .applied : .queued) else { return }
            toolDrafts[sessionID, default: []].append(request)
            refreshToolInteractions()
        }.store(in: &subscriptions)
        AppLockManager.shared.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if state == .locked {
                guard let self else { return }
                suspendRoleplayPresentation(); requestControls.suspend(); modelTests.cancelAll()
                shortcutTools.suspend()
                builtInTools.suspend(); toolApproval.suspend(); skills.suspend()
                globalProxy.suspend(); speechInput.suspend(); tts.suspend(); backgrounds.suspend(); appearance.suspend(); fonts.suspend(); linux.suspend()
                incomingDocuments.suspend(acceptNewFiles: !isRestoringData && !isExportingSnapshot && !isClosingRoleplay)
                slashCommands.suspend(); connectionSecurity.suspend(); dataImportOperations.cancelPreviews()
            }
            else { self?.resumeRoleplayPresentation(); self?.resumeRequestControls() }
        }.store(in: &subscriptions)
        for name in [RoleplayStore.didChangeNotification, RoleplayDisplayedMessageBridge.didChangeNotification,
                     MessageRegexRuleStore.didChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshMessagePresentation() }.store(in: &subscriptions)
        }
    }

    func acknowledgeUnknownToolOutcome() {
        guard let outcome = unknownToolOutcome else { return }
        _ = service?.acknowledgeUnknownToolOutcome(id: outcome.id, sessionID: outcome.sessionID)
        unknownToolOutcome = nil
    }

    func refreshMessagePresentation() {
        guard roleplayHostVisible, !isRestoringData, !isExportingSnapshot, !isClosingRoleplay, AppLockManager.shared.state != .locked, let service else { return }
        presentationTask?.cancel()
        let revision = UUID()
        presentationRevision = revision
        let snapshot = sourceMessages
        let sessionID = currentSession?.id
        let markdown = AppConfigStore.shared.enableMarkdown
        let advanced = AppConfigStore.shared.enableAdvancedRenderer
        let language = AppConfigStore.shared.appLanguage
        let userPreviewLimit = AppConfigStore.shared.userMessagePreviewCharacterLimit
        let appearance = appearance.activeProfile
        let lineSpacing = AppConfigStore.shared.fontLineSpacingEmIOS
        let actionBar = AppConfigStore.shared.messageActionBarSettings, providers = providers
        let fontModel = fonts
        let store = presentationStore
        var scriptSessionIDs = runningSessionIDs
        if let sessionID { scriptSessionIDs.insert(sessionID) }
        presentationTask = Task { [weak self] in
            await fontModel.waitForPendingOperations()
            guard !Task.isCancelled else { return }
            guard let prepared = try? await store.prepareWorkspace(snapshot, markdown: markdown, language: language, sessionID: sessionID,
                                                                 scriptSessionIDs: scriptSessionIDs, service: service, userPreviewLimit: userPreviewLimit,
                                                                 appearance: appearance, lineSpacing: lineSpacing, advanced: advanced,
                                                                 actionBar: actionBar, providers: providers) else { return }
            guard let self, !Task.isCancelled, presentationRevision == revision else { return }
            roleplayRuntime.apply(prepared, workspace: self)
            messages = prepared.rows
        }
    }

    func setRoleplayHostVisible(_ visible: Bool) {
        roleplayHostVisible = visible
        if visible { resumeRoleplayPresentation() } else { suspendRoleplayPresentation() }
    }

    private func suspendRoleplayPresentation() {
        roleplayLifecycleRevision = UUID()
        presentationTask?.cancel()
        roleplayRuntime.suspend()
    }

    private func resumeRoleplayPresentation() {
        guard roleplayHostVisible, !isRestoringData, !isExportingSnapshot, !isClosingRoleplay, AppLockManager.shared.state != .locked else { return }
        let revision = UUID()
        roleplayLifecycleRevision = revision
        Task { [weak self] in
            guard let self else { return }
            await roleplayRuntime.waitForPendingActions()
            guard revision == roleplayLifecycleRevision else { return }
            roleplayRuntime.resume()
            refreshMessagePresentation()
        }
    }

    func prepareForTermination() async {
        await MacAppInformationModel.shared.suspend()
        slashCommands.suspend(); connectionSecurity.suspend()
        isClosingRoleplay = true
        externalOpenRevision = UUID()
        // 退出时不能让等待控件落盘的发送任务随后发出新请求。
        for task in sendTasks.values { task.cancel() }
        suspendRoleplayPresentation()
        requestControls.suspend()

        shortcutTools.suspend()
        builtInTools.suspend(); toolApproval.suspend(); skills.suspend()
        globalProxy.suspend(); speechInput.suspend(); tts.suspend(); backgrounds.suspend(); appearance.suspend(); fonts.suspend(); linux.suspend()
        incomingDocuments.suspend()
        await dataImportOperations.waitForCompletion()
        await dataImportOperations.cancelAndWaitForPreviews()
        await modelTests.cancelAndWait()
        // KV 清理可能等待正在推理的上下文；先取消生成，退出不能排在清理锁后面等待。
        if let service {
            for sessionID in service.runningSessionIDsSubject.value { await service.cancelRequest(for: sessionID) }
        }
        await slashCommands.waitForPendingOperations(); await connectionSecurity.waitForPendingOperations()
        await shortcutTools.waitForPendingWrites()
        await builtInTools.waitForPendingWrites(); await toolApproval.waitForPendingWrites(); await skills.waitForPendingWrites()
        await globalProxy.waitForPendingWrites(); try? await linux.waitForPendingOperations()
        await incomingDocuments.waitForPendingOperations(); await speechInput.waitForPendingOperations(); await tts.waitForPendingOperations(); await backgrounds.waitForPendingOperations()
        await appearance.waitForPendingOperations(); await fonts.waitForPendingOperations()
        await requestControls.waitForPendingWrites()
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
    }

    func allowsRoleplayAction(_ action: String, sessionID: UUID) -> Bool {
        guard phase == .ready, !isRestoringData, !isClosingRoleplay, AppLockManager.shared.state != .locked,
              sessions.contains(where: { $0.id == sessionID }) else { return false }
        if ["macro_expansion_response", "prompt_mutation_response"].contains(action) { return true }
        guard !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking, !roleplayModel.isWorking else { return false }
        if ["set_chat_messages", "create_chat_messages", "delete_chat_messages", "rotate_chat_messages"].contains(action) {
            return !runningSessionIDs.contains(sessionID) && !sendingSessionIDs.contains(sessionID)
        }
        return true
    }

    func handleRoleplayAction(_ action: String, text: String, sessionID: UUID) {
        guard allowsRoleplayAction(action, sessionID: sessionID), let session = currentSession, session.id == sessionID,
              let service else { return }
        switch action {
        case "set_input": draft = text
        case "send_message":
            guard !isGenerating, !isPreparingSend, effectiveModel != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let lease = acquireChatLease(sessionID: sessionID, service: service) else { return }
            let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
            sendingSessionIDs.insert(sessionID)
            // HTML 发送自己的正文，保留用户尚未发送的输入和附件。
            sendTasks[sessionID] = Task { [weak self] in
                await self?.requestControls.waitForPendingWrites()
                if !Task.isCancelled { await configuration.send(text, through: service, sessionID: sessionID, requestLease: lease) }
                lease.release()
                self?.sendTasks.removeValue(forKey: sessionID)
                self?.sendingSessionIDs.remove(sessionID)
            }
        case "generate":
            errorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
        default: break
        }
    }

    private func refreshModels() {
        guard let service else { return }
        modelListTask?.cancel()
        modelListTask = Task { [weak self] in
            let (models, catalog) = await Task.detached {
                let models = service.activatedConversationModels
                return (models, MacSessionModelCatalog(models: models))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.models = models
            sessionModelCatalog = catalog
            refreshEffectiveModel(forceRequestControls: true)
        }
    }

    private func refreshEffectiveModel(forceRequestControls: Bool = false) {
        effectiveModel = sessionModelCatalog.resolvedModel(preferredID: currentSession?.preferredModelIdentifier,
                                                         global: service?.selectedModelSubject.value)
        effectiveModelName = effectiveModel?.model.displayName
        selectedModelSupportsPrefill = effectiveModel?.canRequestAssistantPrefill == true
        selectedModelSupportsRewrite = effectiveModel?.model.isChatModel == true
        requestControls.select(effectiveModel, sessionID: currentSession?.id, force: forceRequestControls)
    }

    func selectSession(_ id: UUID?) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service, let session = sessions.first(where: { $0.id == id }) else { return }
        if currentSession?.id != id { incomingDocuments.invalidateAttachmentContext() }
        Task { [weak self] in await service.selectSession(session, isSelectionAllowed: { self?.canManageLocalModels == true && self?.isMutatingHistory == false }) }
    }

    func newSession() {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, AppLockManager.shared.state != .locked, let service else { return }
        incomingDocuments.invalidateAttachmentContext()
        sessionLibrary.scope = .all
        sessionLibrary.query = ""
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false }
            await Task.detached(priority: .userInitiated) { service.createNewSession() }.value
        }
    }

    func enableTemporaryChat() {
        guard canModifyCurrentHistory, let service, let sourceID = currentSession?.id else { return }
        incomingDocuments.invalidateAttachmentContext()
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false }
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                guard service.currentSessionSubject.value?.id == sourceID else { return MessageToolCallEditingError.messageChanged.localizedDescription }
                guard service.isTemporaryChatEnabled(for: sourceID) || service.messagesSnapshot(for: sourceID).isEmpty else {
                    return NSLocalizedString("临时对话仅可在对话开始前开启。", comment: "")
                }
                // Core 会复用唯一的临时会话，不能切换正在生成的会话。
                if let temporary = service.chatSessionsSubject.value.first(where: \.isTemporary),
                   service.runningSessionIDsSubject.value.contains(temporary.id) { return MacWorkspaceWriteError.busy.localizedDescription }
                service.enableTemporaryChat()
                return nil
            }.value
            if let failure { errorMessage = failure }
            else {
                sessionLibrary.scope = .all
                sessionLibrary.query = ""
            }
        }
    }

    func deleteSession(_ session: ChatSession) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service else { return }
        let attachmentContext = currentSession?.id == session.id ? incomingDocuments.contextID : nil
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false }
            let result = await Task.detached(priority: .userInitiated) { service.deleteSessions([session]) }.value
            switch result {
            case .success:
                if let attachmentContext, incomingDocuments.contextID == attachmentContext {
                    incomingDocuments.invalidateAttachmentContext()
                }
            case .failure(.busy):
                errorMessage = NSLocalizedString("请先停止当前请求并等待结束，再删除会话。", comment: "Cannot delete a session while its request is active")
            }
        }
    }

    func saveSession(_ session: ChatSession, replacing original: ChatSession) async throws {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, let service else { throw MacWorkspaceWriteError.busy }
        isMutatingHistory = true
        defer { isMutatingHistory = false }
        try await Task.detached(priority: .userInitiated) {
            guard service.chatSessionsSubject.value.first(where: { $0.id == original.id }) == original else {
                throw MacWorkspaceWriteError.changedExternally
            }
            var saved = session
            // 普通空白会话可保存设置；明确开启的临时模式仍只更新运行期元数据。
            saved.isTemporary = service.isTemporaryChatEnabled(for: saved.id)
            service.updateSession(saved)
        }.value
    }

    func saveRoleplayBinding(_ draft: MacRoleplayBindingDraft, removing: Bool = false) async throws {
        guard phase == .ready, !isRestoringData, !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking,
              !roleplayModel.isWorking, !roleplayRuntime.isBusy, !sendingSessionIDs.contains(draft.sessionID),
              !runningSessionIDs.contains(draft.sessionID), AppLockManager.shared.state != .locked,
              let service else { throw MacWorkspaceWriteError.busy }
        // 修改可能初始化或替换开场白，沿用历史写入屏障，并始终操作编辑页捕获的会话。
        isMutatingHistory = true
        defer { isMutatingHistory = false }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard service.chatSessionsSubject.value.contains(where: { $0.id == draft.sessionID }) else {
                throw RoleplayDraftWriteError.changedExternally
            }
            guard !service.runningSessionIDsSubject.value.contains(draft.sessionID) else { throw MacWorkspaceWriteError.busy }
            if removing {
                guard let original = draft.original else { throw RoleplayDraftWriteError.changedExternally }
                try service.removeRoleplayBindingDraft(original)
            } else {
                try service.saveRoleplayBindingDraft(draft.preparedBinding(), replacing: draft.original)
            }
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func saveRoleplayData(_ source: RoleplayDataDraft, values: [String: JSONValue], message: ChatMessage?) async throws -> RoleplayDataDraft {
        guard phase == .ready, !isRestoringData, !isExportingSnapshot, !isMutatingHistory, !sessionLibrary.isWorking,
              !roleplayModel.isWorking, !roleplayRuntime.isBusy, sendingSessionIDs.isEmpty, runningSessionIDs.isEmpty,
              AppLockManager.shared.state != .locked, let service else { throw MacWorkspaceWriteError.busy }
        // 共享层可能影响其他会话；编辑期间不与桌面的任何生成或历史写入并发。
        isMutatingHistory = true
        defer { isMutatingHistory = false }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard service.runningSessionIDsSubject.value.isEmpty else { throw MacWorkspaceWriteError.busy }
            return try service.saveRoleplayDataDraft(source, values: values, matching: message)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func send(onMessagesPrepared: ChatSendPresentationHandler? = nil) {
        guard canSend, let service, let session = currentSession else { return }
        let content = draft
        let attachments = self.attachments
        let audioAttachment = self.audioAttachment
        let configuration = MacChatRequestConfiguration(AppConfigStore.shared, session: session)
        guard let lease = acquireChatLease(sessionID: session.id, service: service) else { return }
        sendingSessionIDs.insert(session.id)
        sendTasks[session.id] = Task { [weak self] in
            await self?.requestControls.waitForPendingWrites()
            if !Task.isCancelled {
                await configuration.send(content, attachments: attachments, audioAttachment: audioAttachment, through: service,
                    sessionID: session.id, onMessagesPrepared: onMessagesPrepared, requestLease: lease,
                    onInputAccepted: { [weak self] _, cancelled in
                        guard let self else { return false }
                        guard self.currentSession?.id == session.id else {
                            self.errorMessage = NSLocalizedString("会话已切换，请查看原会话后再继续。", comment: "Send session changed")
                            return false
                        }
                        let attachmentIDs = Set(attachments.map(\.id))
                        let retained = self.draft == content
                            && attachmentIDs.isSubset(of: Set(self.attachments.map(\.id)))
                            && (audioAttachment == nil || self.audioAttachment?.id == audioAttachment?.id)
                        if cancelled { return retained }
                        if self.draft == content { self.draft = "" }
                        self.attachments.removeAll { attachmentIDs.contains($0.id) }
                        if audioAttachment != nil, self.audioAttachment?.id == audioAttachment?.id { self.audioAttachment = nil }
                        return false
                    })
            }
            lease.release()
            self?.sendTasks.removeValue(forKey: session.id)
            self?.sendingSessionIDs.remove(session.id)
        }
    }

    private func acquireChatLease(sessionID: UUID, service: ChatService) -> ChatRequestLease? {
        switch service.beginRequest(sessionID: sessionID) {
        case .success(let lease): return lease
        case .failure(.busy): errorMessage = NSLocalizedString("当前会话正在处理，请稍后再发送。", comment: "Session busy")
        case .failure(.sessionMissing): errorMessage = NSLocalizedString("会话已不存在，内容未发送。", comment: "Missing send session")
        }
        return nil
    }

    private func refreshToolInteractions() {
        guard let sessionID = currentSession?.id else { return }
        for request in toolDrafts.removeValue(forKey: sessionID) ?? [] {
            switch request.mode {
            case .replace: draft = request.text
            case .append:
                draft += draft.isEmpty || draft.last?.isWhitespace == true ? request.text : "\n" + request.text
            }
        }
    }

    private func discardToolInteractions() {
        toolDrafts.removeAll()
    }

    private func pruneToolInteractions() {
        let ids = Set(sessions.map(\.id))
        toolDrafts = toolDrafts.filter { ids.contains($0.key) }
        refreshToolInteractions()
    }

    func stop() {
        guard let service, let sessionID = currentSession?.id else { return }
        sendTasks[sessionID]?.cancel()
        Task { await service.cancelRequest(for: sessionID) }
    }

    func retryMessage(_ message: ChatMessage, prefill: Bool = false) {
        errorMessage = NSLocalizedString("此功能暂不可用。", comment: "Unavailable chat operation")
    }

    func selectVersion(_ index: Int, of message: ChatMessage) {
        guard canModifyCurrentHistory,
              let service, let sessionID = currentSession?.id else { return }
        isMutatingHistory = true
        Task { [weak self] in
            let didSave = await Task.detached(priority: .userInitiated) {
                service.selectMessageVersion(at: index, of: message, sessionID: sessionID)
            }.value
            self?.isMutatingHistory = false
            if !didSave { self?.errorMessage = MessageToolCallEditingError.messageChanged.localizedDescription }
        }
    }

    func branchSession(at message: ChatMessage? = nil, copyMessages: Bool = true, copyPrompts: Bool = true) {
        guard canModifyCurrentHistory,
              let service, let session = currentSession else { return }
        incomingDocuments.invalidateAttachmentContext()
        isMutatingHistory = true
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                if let message {
                    _ = service.branchSessionFromMessage(from: session, upToMessage: message, copyPrompts: copyPrompts)
                } else { _ = service.branchSession(from: session, copyMessages: copyMessages) }
            }.value
            self?.isMutatingHistory = false
        }
    }

    func updateMessage(_ edited: ChatMessage, original: ChatMessage, sessionID: UUID) async throws {
        guard canModifyCurrentHistory, currentSession?.id == sessionID, let service else { throw MessageToolCallEditingError.messageChanged }
        isMutatingHistory = true
        defer { isMutatingHistory = false }
        try await service.updateEditedMessage(edited, original: original, targetSessionID: sessionID)
    }

    func deleteMessage(_ target: MacMessageDeletionTarget) {
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking,
              !sendingSessionIDs.contains(target.sessionID), !runningSessionIDs.contains(target.sessionID),
              AppLockManager.shared.state != .locked, let service else { return }
        isMutatingHistory = true
        Task {
            defer { isMutatingHistory = false }
            let deleted = await Task.detached(priority: .userInitiated) {
                service.deleteHistoryMessage(target.message, sessionID: target.sessionID, kind: target.kind)
            }.value
            if !deleted { errorMessage = MessageToolCallEditingError.messageChanged.localizedDescription }
        }
    }

    @discardableResult
    func receiveDocuments(_ urls: [URL]) -> Bool {
        guard !isRestoringData, !isExportingSnapshot, !isClosingRoleplay else {
            errorMessage = NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            return false
        }
        if AppLockManager.shared.state == .locked { incomingDocuments.suspend(acceptNewFiles: true) }
        return incomingDocuments.enqueue(urls)
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
    func removeAudioAttachment() { audioAttachment = nil }
    func clearComposer() { incomingDocuments.invalidateAttachmentContext(); draft = ""; attachments.removeAll(); audioAttachment = nil }

    func applySpeechInput(_ result: MacSpeechInputResult, source: MacSpeechInputSource) -> Bool {
        guard canManageLocalModels, currentSession?.id == source.sessionID, incomingDocuments.contextID == source.composerContextID else { return false }
        switch result {
        case .audio(let attachment): audioAttachment = attachment
        case .text(let text): draft += draft.isEmpty ? text : "\n" + text
        }
        return true
    }

    func beginSnapshotExport() -> Bool {
        guard !isRestoringData, !isMutatingHistory, !roleplayRuntime.isBusy, !sessionLibrary.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, !SnapshotUploadManager.shared.isUploading else { return false }
        isExportingSnapshot = true
        slashCommands.suspend(); connectionSecurity.suspend(); dataImportOperations.cancelPreviews()
        externalOpenRevision = UUID()
        modelTests.cancelAll()

        shortcutTools.suspend()
        builtInTools.suspend(); toolApproval.suspend(); skills.suspend()
        globalProxy.suspend(); speechInput.suspend(); tts.suspend(); backgrounds.suspend(); appearance.suspend(); fonts.suspend(); linux.suspend()
        incomingDocuments.suspend()
        suspendRoleplayPresentation()
        requestControls.suspend()
        return true
    }

    func endSnapshotExport() { isExportingSnapshot = false; resumeRoleplayPresentation(); resumeRequestControls() }

    private func resumeRequestControls() {
        guard phase == .ready, !isRestoringData, !isExportingSnapshot, !isClosingRoleplay else { return }
        guard AppLockManager.shared.state != .locked else {
            incomingDocuments.suspend(acceptNewFiles: true)
            return
        }
        requestControls.resume()
        slashCommands.resume(); connectionSecurity.resume()
        shortcutTools.resume()
        builtInTools.resume(); toolApproval.resume(); skills.resume()
        globalProxy.resume(); speechInput.resume(); tts.resume(); backgrounds.resume(); appearance.resume(); fonts.resume(); linux.resume()
        incomingDocuments.resume(sessionID: currentSession?.id)
    }

    func importData(_ operation: MacDataImportOperation) async throws -> SyncMergeSummary? {
        try await dataImportOperations.perform { try await self.performDataMaintenance { try await operation.apply(using: $0) } }
    }

    func performDataMaintenance<Value>(_ operation: (ChatService) async throws -> Value) async throws -> Value {
        let cloud = CloudSyncManager.shared
        guard canManageLocalModels, !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading,
              let service, cloud.beginLocalDataRestore() else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        slashCommands.suspend(); connectionSecurity.suspend()
        externalOpenRevision = UUID()
        modelTests.cancelAll()

        shortcutTools.suspend()
        builtInTools.suspend(); toolApproval.suspend(); skills.suspend()
        globalProxy.suspend(); speechInput.suspend(); tts.suspend(); backgrounds.suspend(); appearance.suspend(); fonts.suspend(); linux.suspend()
        incomingDocuments.suspend()
        suspendRoleplayPresentation()
        requestControls.suspend()
        discardToolInteractions()
        var didRestore = false
        defer {
            cloud.endLocalDataRestore(didRestore: didRestore)
            isRestoringData = false
            resumeRoleplayPresentation()
            resumeRequestControls()
        }
        await modelTests.cancelAndWait(); await dataImportOperations.cancelAndWaitForPreviews()
        for sessionID in service.runningSessionIDsSubject.value { await service.cancelRequest(for: sessionID) }
        await MacAppInformationModel.shared.suspend()
        await slashCommands.waitForPendingOperations(); await connectionSecurity.waitForPendingOperations()
        await shortcutTools.waitForPendingWrites()
        await builtInTools.waitForPendingWrites(); await toolApproval.waitForPendingWrites(); await skills.waitForPendingWrites()
        await globalProxy.waitForPendingWrites(); try await linux.waitForPendingOperations()
        await incomingDocuments.waitForPendingOperations(); await speechInput.waitForPendingOperations(); await tts.waitForPendingOperations(); await backgrounds.waitForPendingOperations()
        await appearance.waitForPendingOperations(); await fonts.waitForPendingOperations()
        await requestControls.waitForPendingWrites()
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
        await NetworkConnectionSecurity.shared.prepareForDatabaseRestore()
        do {
            await AppConfigStore.shared.flushPendingWrites()
            let summary = try await operation(service)
            didRestore = true
            await refreshRestoredData(service)
            await NetworkConnectionSecurity.shared.finishDatabaseRestore()
            AppLockManager.shared.refreshState()
            return summary
        } catch {
            await NetworkConnectionSecurity.shared.finishDatabaseRestore()
            throw error
        }
    }

    func resolveCloudConflict(using resolution: CloudSyncInitialResolution, conflictID: UUID) async throws {
        let cloud = CloudSyncManager.shared
        guard !isRestoringData, !isMutatingHistory, !sessionLibrary.isWorking, !roleplayModel.isWorking, !isExportingSnapshot, sendingSessionIDs.isEmpty,
              !SnapshotUploadManager.shared.isUploading, let service,
              cloud.initialConflict?.id == conflictID else {
            throw NSError(domain: "ETOSMacSnapshot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        isRestoringData = true
        slashCommands.suspend(); connectionSecurity.suspend()
        externalOpenRevision = UUID()
        modelTests.cancelAll()

        shortcutTools.suspend()
        builtInTools.suspend(); toolApproval.suspend(); skills.suspend()
        globalProxy.suspend(); speechInput.suspend(); tts.suspend(); backgrounds.suspend(); appearance.suspend(); fonts.suspend(); linux.suspend()
        incomingDocuments.suspend()
        suspendRoleplayPresentation()
        requestControls.suspend()
        discardToolInteractions()
        defer { isRestoringData = false; resumeRoleplayPresentation(); resumeRequestControls() }
        await modelTests.cancelAndWait(); await dataImportOperations.cancelAndWaitForPreviews()
        for sessionID in service.runningSessionIDsSubject.value { await service.cancelRequest(for: sessionID) }
        await slashCommands.waitForPendingOperations(); await connectionSecurity.waitForPendingOperations()
        await shortcutTools.waitForPendingWrites()
        await builtInTools.waitForPendingWrites(); await toolApproval.waitForPendingWrites(); await skills.waitForPendingWrites()
        await globalProxy.waitForPendingWrites(); try await linux.waitForPendingOperations()
        await incomingDocuments.waitForPendingOperations(); await speechInput.waitForPendingOperations(); await tts.waitForPendingOperations(); await backgrounds.waitForPendingOperations()
        await appearance.waitForPendingOperations(); await fonts.waitForPendingOperations()
        await requestControls.waitForPendingWrites()
        await presentationTask?.value
        await roleplayRuntime.waitForPendingActions()
        await NetworkConnectionSecurity.shared.prepareForDatabaseRestore()
        await AppConfigStore.shared.flushPendingWrites()
        // 异步清理期间裁决可能已失效，核心再次核对 ID 后才允许覆盖。
        await cloud.resolveInitialConflict(using: resolution, expectedConflictID: conflictID)
        await refreshRestoredData(service)
        await NetworkConnectionSecurity.shared.finishDatabaseRestore()
        AppLockManager.shared.refreshState()
        if case .failed(let reason) = cloud.state {
            throw NSError(domain: "ETOSMacCloudSync", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    private func refreshRestoredData(_ service: ChatService) async {
        await AppConfigStore.shared.reloadFromPersistentStoreAndWait()
        // 解除恢复屏障前更新工具路由，下一轮聊天不能读取旧数据库的快捷指令。
        await ShortcutToolManager.shared.reloadToolsInBackground()
        await AppToolManager.shared.reloadInBackground()
        do { try await SkillManager.shared.reloadLibraryInBackground() }
        catch { errorMessage = error.localizedDescription }
        do { try await ToolPermissionCenter.shared.reloadPreferencesInBackground() }
        catch { errorMessage = error.localizedDescription }
        await Task.detached(priority: .userInitiated) {
            service.reloadSessionStateFromPersistenceAfterMigration()
            RoleplayStore.shared.invalidateCache()
        }.value
        draft = AppConfigStore.shared.chatComposerDraft
        attachments.removeAll()
        audioAttachment = nil
        roleplayModel.reloadAfterRestore()
    }
}

enum MacWorkspaceWriteError: LocalizedError {
    case busy, changedExternally

    var errorDescription: String? {
        switch self {
        case .busy: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
        case .changedExternally: NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        }
    }
}
