// ============================================================================
// LocalLinuxJobScheduler.swift
// ============================================================================
// ETOS LLM Studio
//
// 动态任务注册表不设置产品并发上限。命令、终端与后续本地 MCP 都携带
// session/run/tool/device 归属，页面是否订阅不影响输出 drain 与任务完成。
// ============================================================================

import Foundation

public actor LocalLinuxJobScheduler {
    public static let shared = LocalLinuxJobScheduler()

    private struct ActiveCommand {
        var job: LocalLinuxJob
        let session: any LocalCommandSession
        let collector: LocalLinuxOutputCollector
        let workspace: LocalAgentWorkspace
    }

    private struct ActiveTerminal {
        let activity: LocalLinuxActivityLease
        var job: LocalLinuxJob
        let session: any LocalTerminalSession
        let collector: LocalLinuxOutputCollector
        var inputOwner: LocalLinuxTerminalInputOwner
        let workspace: LocalAgentWorkspace
    }

    private let runtime: LocalLinuxRuntimeController
    private let storage: LocalLinuxStorageManager
    private let environmentProvider: LocalLinuxProcessEnvironmentProvider
    private let approvalPolicy: LocalLinuxApprovalPolicy
    private let diagnostics: LocalLinuxDiagnosticsRecorder
    private let executorDeviceID: String

    private var activeCommands: [UUID: ActiveCommand] = [:]
    private var activeTerminals: [UUID: ActiveTerminal] = [:]
    private var suspensionInterruptedJobIDs: Set<UUID> = []
    private var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    private var didRegisterRuntimeCancellation = false

    public init(
        runtime: LocalLinuxRuntimeController = .shared,
        storage: LocalLinuxStorageManager = .shared,
        environmentProvider: LocalLinuxProcessEnvironmentProvider = .shared,
        approvalPolicy: LocalLinuxApprovalPolicy = .shared,
        diagnostics: LocalLinuxDiagnosticsRecorder = .shared,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.runtime = runtime
        self.storage = storage
        self.environmentProvider = environmentProvider
        self.approvalPolicy = approvalPolicy
        self.diagnostics = diagnostics
        self.executorDeviceID = executorDeviceID
    }

    public func activeJobs() -> [LocalLinuxJob] {
        let externalJobs = Persistence.loadLocalLinuxJobs(activeOnly: true).filter {
            ($0.kind == .localMCP || $0.kind == .browser) && activeCommands[$0.id] == nil
        }
        return Self.orderedJobs(
            activeCommands.values.map(\.job) + activeTerminals.values.map(\.job) + externalJobs
        )
    }

    /// 聊天页缩略窗只观察独立用户终端，不把 Agent PTY 冒充成用户正在操作的终端。
    public func activeStandaloneUserTerminals() -> [LocalLinuxJob] {
        Self.orderedJobs(
            activeTerminals.values.compactMap { terminal in
                let job = terminal.job
                guard job.sessionID == nil, job.runID == nil, !job.state.isTerminal else {
                    return nil
                }
                return job
            }
        )
    }

    public static func orderedJobs(_ jobs: [LocalLinuxJob]) -> [LocalLinuxJob] {
        jobs.sorted {
            jobComesBefore($0, $1)
        }
    }

    public static func orderedJobGroups(_ jobs: [LocalLinuxJob]) -> [[LocalLinuxJob]] {
        Dictionary(grouping: jobs) {
            "\($0.sessionID?.uuidString ?? "device")/\($0.runID?.uuidString ?? "user")"
        }.values
            .map { orderedJobs($0) }
            .sorted { lhs, rhs in
                guard let left = lhs.first else { return false }
                guard let right = rhs.first else { return true }
                return jobComesBefore(left, right)
            }
    }

    private static func jobComesBefore(_ lhs: LocalLinuxJob, _ rhs: LocalLinuxJob) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    public func hasActiveJobs() -> Bool {
        !activeCommands.isEmpty
            || !activeTerminals.isEmpty
            || Persistence.loadLocalLinuxJobs(activeOnly: true).contains {
                $0.kind == .localMCP || $0.kind == .browser
            }
    }

    public func job(id: UUID) -> LocalLinuxJob? {
        if let command = activeCommands[id] { return command.job }
        if let terminal = activeTerminals[id] { return terminal.job }
        return Persistence.loadLocalLinuxJob(id: id)
    }

    public func latestDiagnosticEvent(jobID: UUID) async -> LocalLinuxBridgeDiagnosticEvent? {
        await diagnostics.latestEvent(jobID: jobID)
    }

    /// 活跃任务不分页；只给终态历史加 cursor，避免较早活跃任务被历史淹没。
    public func jobsPage(
        sessionID: UUID? = nil,
        cursor: LocalLinuxJobCursor? = nil,
        historyLimit: Int = 50
    ) -> LocalLinuxJobPage {
        let active = activeJobs().filter { sessionID == nil || $0.sessionID == sessionID }
        let history = Persistence.loadLocalLinuxJobHistoryPage(
            sessionID: sessionID,
            cursor: cursor,
            limit: historyLimit
        )
        return LocalLinuxJobPage(
            activeJobs: active,
            historyJobs: history.jobs,
            nextCursor: history.nextCursor
        )
    }

    public func modelOutput(jobID: UUID, maximumBytes: Int) async throws -> String {
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.modelOutputRelativePath else { return "" }
        return try await storage.readOutput(relativePath: relativePath, maximumBytes: maximumBytes)
    }

    public func userVisibleOutput(jobID: UUID) async throws -> String {
        if let collector = activeCommands[jobID]?.collector ?? activeTerminals[jobID]?.collector {
            return await Task.detached(priority: .utility) {
                collector.userVisiblePreview()
            }.value
        }
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.outputRelativePath else { return "" }
        return try await storage.readRawOutput(relativePath: relativePath, maximumBytes: 262_144)
    }

    public func terminalDisplayUpdates(
        jobID: UUID,
        appearance: LocalLinuxTerminalAppearance,
        minimumInterval: Duration
    ) throws -> AsyncStream<[LocalLinuxTerminalDisplayLine]> {
        guard let active = activeTerminals[jobID] else {
            throw LocalLinuxRuntimeError.jobNotFound(jobID)
        }
        return active.collector.terminalDisplayUpdates(appearance: appearance, minimumInterval: minimumInterval)
    }

    public func userVisibleTerminalPresentation(
        jobID: UUID,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) async throws -> LocalLinuxTerminalPresentation {
        guard let terminal = activeTerminals[jobID] else {
            throw LocalLinuxRuntimeError.jobNotFound(jobID)
        }
        let collector = terminal.collector
        // 屏幕解析与快照仍共用锁。等待它或拼接富文本时释放
        // 调度器 actor，才能让用户输入、中断和其他会话继续被及时调度。
        return await Task.detached(priority: .utility) {
            collector.userVisibleTerminalPresentation(appearance: appearance) ?? .empty
        }.value
    }

    public func userVisibleTerminalPreviewPresentation(
        jobID: UUID,
        maximumLines: Int,
        appearance: LocalLinuxTerminalAppearance = .dark
    ) async throws -> LocalLinuxTerminalPresentation {
        guard let terminal = activeTerminals[jobID] else {
            throw LocalLinuxRuntimeError.jobNotFound(jobID)
        }
        let collector = terminal.collector
        return await Task.detached(priority: .utility) {
            collector.userVisibleTerminalPreviewPresentation(
                maximumLines: maximumLines,
                appearance: appearance
            ) ?? .empty
        }.value
    }

    public func userVisibleOutputPage(
        jobID: UUID,
        cursor: LocalLinuxRawOutputCursor,
        maximumBytes: Int
    ) async throws -> LocalLinuxRawOutputPage {
        guard let job = job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard let relativePath = job.outputRelativePath else {
            return LocalLinuxRawOutputPage(cursor: cursor, text: "", nextCursor: nil, isComplete: true)
        }
        return try await storage.readRawOutputPage(
            relativePath: relativePath,
            cursor: cursor,
            maximumBytes: maximumBytes
        )
    }

    public func terminalInputOwner(jobID: UUID) throws -> LocalLinuxTerminalInputOwner {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        return terminal.inputOwner
    }

    /// 所有本地运行任务共用同一个单调 request ID 源，避免不同工具同时落库时冲突。
    public func reserveRequestID() -> UInt64 {
        nextRequestID()
    }

    /// Skill 在建立动态只读挂载前先启动 runtime，避免把挂载注册发送给未启动的 bridge。
    public func prepareForAgentExecution() async throws {
        await registerRuntimeCancellationIfNeeded()
        _ = try await runtime.ensureReady(trigger: .agentRequest)
    }

    #if os(macOS)
    public func availableExecutablePath(
        _ command: String,
        environment: [String: String],
        workingDirectory: String?
    ) async throws -> String? {
        try await prepareForAgentExecution()
        let requestID = nextRequestID()
        let resolved = await resolveExecutableFromPATH(
            command,
            environment: environment,
            workingDirectory: workingDirectory,
            requestID: requestID
        )
        #if os(macOS)
        let directory = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return try? MacNativeProcess.resolveExecutable(resolved, environment: environment, workingDirectory: directory).path
        #endif
    }

    public func runCommand(
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        approval: LocalLinuxCommandApproval = LocalLinuxCommandApproval(),
        toolCallID: String? = nil
    ) async throws -> LocalLinuxJob {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        defer { activity.finish() }
        await registerRuntimeCancellationIfNeeded()
        guard kind == .run || kind == .shell || kind == .recipe || kind == .localMCP else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("任务类型不能使用结构化命令执行。", comment: "Linux command kind validation error")
            )
        }
        let environment: LocalLinuxEnvironmentSnapshot
        if let context {
            var values = context.environmentValues
            for (name, value) in request.environment {
                values[name] = value
            }
            environment = try await environmentProvider.snapshot(
                explicitValues: values,
                redactionValues: (context.environmentRedactionValues ?? []) + Array(request.environment.values)
            )
        } else {
            environment = try await environmentProvider.snapshot(additional: request.environment)
        }
        let commandRuleMatch = try await authorizeCommand(
            kind: kind,
            request: request,
            context: context,
            approval: approval,
            redactionValues: environment.redactionValues
        )
        let runtimeSnapshot = try await runtime.ensureReady(trigger: trigger(for: kind))
        var resolvedRequest = request
        resolvedRequest.environment = environment.values
        if resolvedRequest.timeoutSeconds == nil {
            resolvedRequest.timeoutSeconds = Double(AppConfigStore.integerValue(for: .localLinuxDefaultTimeoutSeconds))
        }

        let requestID = nextRequestID()
        if kind == .run {
            resolvedRequest.executable = await resolveExecutableFromPATH(
                resolvedRequest.executable,
                environment: environment.values,
                workingDirectory: resolvedRequest.workingDirectory,
                requestID: requestID
            )
        }
        var persistedRequest = resolvedRequest
        persistedRequest.commandRuleMatch = commandRuleMatch
        persistedRequest.environment = Dictionary(
            uniqueKeysWithValues: resolvedRequest.environment.keys.map { ($0, "<injected>") }
        )
        persistedRequest = redactedPersistedRequest(
            persistedRequest,
            values: environment.redactionValues
        )
        var job = makeJob(
            requestID: requestID,
            kind: kind,
            request: persistedRequest,
            context: context,
            workspace: workspace,
            toolCallID: toolCallID
        )
        let urls = try await storage.outputURLs(jobID: job.id, workspace: workspace)
        job.outputRelativePath = try await storage.relativePath(for: urls.raw)
        job.modelOutputRelativePath = try await storage.relativePath(for: urls.model)
        job.state = .starting
        job.startedAt = Date()
        _ = Persistence.saveLocalLinuxJob(job)

        let collector: LocalLinuxOutputCollector
        do {
            collector = try LocalLinuxOutputCollector(
                rawURL: urls.raw,
                modelURL: urls.model,
                redactionValues: environment.redactionValues,
                privacyEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled),
                modelByteLimit: UInt64(AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes)),
                rawOutputChanged: { [jobID = job.id] in LocalLinuxJobNotifications.outputChanged(jobID: jobID) }
            )
        } catch {
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.finishedAt = Date()
            _ = Persistence.saveLocalLinuxJob(job)
            throw error
        }
        do {
            try activity.checkCancellation()
            let receiveOutput: @Sendable (LocalLinuxOutputStream, Data, Int32) -> Void = { stream, data, terminalError in
                collector.append(stream: stream, data: data, terminalError: terminalError, streamEnded: data.isEmpty)
            }
            #if os(macOS)
            let session = try MacNativeProcess.start(requestID: requestID, request: resolvedRequest, onOutput: receiveOutput)
            #endif
            job.state = .running
            _ = Persistence.saveLocalLinuxJob(job)
            activeCommands[job.id] = ActiveCommand(
                job: job,
                session: session,
                collector: collector,
                workspace: workspace
            )
            if (try? activity.checkCancellation()) == nil { try? session.cancel() }
            await publishActivityCounts()
            let result = await session.result()
            return await finishCommand(jobID: job.id, result: result, runtimeSnapshot: runtimeSnapshot)
        } catch {
            collector.finish()
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.linuxError = bridgeErrorCode(error)
            job.finishedAt = Date()
            applyOutputSnapshot(collector.snapshot(), to: &job)
            job.diagnosticID = await diagnostics.finalize(
                job: job,
                completionReason: .runtimeFailure,
                exitCode: nil,
                signal: nil,
                linuxError: job.linuxError,
                runtime: runtimeSnapshot
            )
            _ = Persistence.saveLocalLinuxJob(job)
            await publishActivityCounts()
            throw error
        }
    }

    public func startTerminal(
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        inputOwner: LocalLinuxTerminalInputOwner,
        columns: UInt16,
        rows: UInt16,
        shellPathOverride: String? = nil,
        toolCallID: String? = nil
    ) async throws -> LocalLinuxJob {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        var transferredActivity = false
        defer { if !transferredActivity { activity.finish() } }
        await registerRuntimeCancellationIfNeeded()
        let runtimeSnapshot = try await runtime.ensureReady(trigger: .userTerminal)
        let baseEnvironment: LocalLinuxEnvironmentSnapshot
        if let context {
            baseEnvironment = try await environmentProvider.snapshot(
                explicitValues: context.environmentValues,
                redactionValues: context.environmentRedactionValues ?? []
            )
        } else {
            baseEnvironment = try await environmentProvider.snapshot()
        }
        var shellPath = LocalLinuxTerminalShellConfiguration.normalizedPath(
            shellPathOverride ?? AppConfigStore.textValue(for: .localLinuxDefaultShellPath)
        )
        var environmentValues = baseEnvironment.values
        environmentValues["SHELL"] = shellPath
        var environment = try await environmentProvider.snapshot(
            explicitValues: environmentValues,
            redactionValues: baseEnvironment.redactionValues
        )
        let requestID = nextRequestID()
        var terminalRequest = LocalLinuxBridgeTerminalRequest(
            terminalID: requestID,
            executable: shellPath,
            arguments: LocalLinuxTerminalShellConfiguration.loginArguments(for: shellPath),
            environment: environment.values,
            // 独立用户终端从 HOME 开始，避免把内部工作区路径暴露成默认操作目录。
            workingDirectory: environment.values["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            columns: columns,
            rows: rows
        )
        do {
            try await validateTerminalLaunchPaths(terminalRequest, requestID: requestID)
        } catch let error as LocalLinuxRuntimeError {
            guard case .terminalShellUnavailable = error,
                  shellPath != LocalLinuxTerminalShellConfiguration.defaultPath else {
                throw error
            }
            // 用户卸载了已选 Shell 时仍保证终端可用；下次打开设置页会同步回默认值。
            shellPath = LocalLinuxTerminalShellConfiguration.defaultPath
            environmentValues["SHELL"] = shellPath
            environment = try await environmentProvider.snapshot(
                explicitValues: environmentValues,
                redactionValues: baseEnvironment.redactionValues
            )
            terminalRequest = LocalLinuxBridgeTerminalRequest(
                terminalID: requestID,
                executable: shellPath,
                arguments: LocalLinuxTerminalShellConfiguration.loginArguments(for: shellPath),
                environment: environment.values,
                workingDirectory: environment.values["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                columns: columns,
                rows: rows
            )
            try await validateTerminalLaunchPaths(terminalRequest, requestID: requestID)
        }
        let jobRequest = LocalLinuxJobRequest(
            executable: terminalRequest.executable,
            arguments: terminalRequest.arguments,
            environment: Dictionary(
                uniqueKeysWithValues: terminalRequest.environment.keys.map { ($0, "<injected>") }
            ),
            workingDirectory: terminalRequest.workingDirectory
        )
        var job = makeJob(
            requestID: requestID,
            kind: .terminal,
            request: jobRequest,
            context: context,
            workspace: workspace,
            toolCallID: toolCallID
        )
        let urls = try await storage.outputURLs(jobID: job.id, workspace: workspace)
        job.outputRelativePath = try await storage.relativePath(for: urls.raw)
        job.modelOutputRelativePath = try await storage.relativePath(for: urls.model)
        job.state = .starting
        job.startedAt = Date()
        _ = Persistence.saveLocalLinuxJob(job)
        let collector: LocalLinuxOutputCollector
        let terminalResponseRelay = LocalLinuxTerminalResponseRelay()
        do {
            collector = try LocalLinuxOutputCollector(
                rawURL: urls.raw,
                modelURL: urls.model,
                redactionValues: environment.redactionValues,
                privacyEnabled: AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled),
                modelByteLimit: UInt64(AppConfigStore.integerValue(for: .localLinuxOutputPreviewBytes)),
                terminalColumns: Int(columns),
                terminalRows: Int(rows),
                terminalResponseHandler: { terminalResponseRelay.enqueue($0) },
                rawOutputChanged: { [jobID = job.id] in LocalLinuxJobNotifications.outputChanged(jobID: jobID) }
            )
        } catch {
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.finishedAt = Date()
            _ = Persistence.saveLocalLinuxJob(job)
            throw error
        }
        do {
            try activity.checkCancellation()
            let receiveOutput: @Sendable (Data, UInt64) -> Void = { data, dropped in
                collector.append(stream: .terminal, data: data)
                if dropped != 0 {
                    let droppedMessage = String(
                        format: NSLocalizedString("\n[PTY 输出缓冲区丢弃了 %llu 字节]\n", comment: "PTY dropped output bytes"),
                        dropped
                    )
                    collector.append(
                        stream: .terminal,
                        data: Data(droppedMessage.utf8)
                    )
                }
            }
            #if os(macOS)
            let session = try MacNativeTerminalSession(request: terminalRequest, onOutput: receiveOutput)
            #endif
            terminalResponseRelay.bind(to: session)
            job.state = .running
            _ = Persistence.saveLocalLinuxJob(job)
            activeTerminals[job.id] = ActiveTerminal(
                activity: activity,
                job: job,
                session: session,
                collector: collector,
                inputOwner: inputOwner,
                workspace: workspace
            )
            transferredActivity = true
            if (try? activity.checkCancellation()) == nil { try? session.cancel() }
            await publishActivityCounts()
            Task { [weak self] in
                do {
                    let result = try await session.result()
                    await self?.finishTerminal(jobID: job.id, result: result, runtimeSnapshot: runtimeSnapshot)
                } catch {
                    await self?.failTerminal(jobID: job.id, error: error, runtimeSnapshot: runtimeSnapshot)
                }
            }
            return job
        } catch {
            collector.finish()
            job.state = .failed
            job.completionReason = .runtimeFailure
            job.linuxError = bridgeErrorCode(error)
            job.finishedAt = Date()
            applyOutputSnapshot(collector.snapshot(), to: &job)
            job.diagnosticID = await diagnostics.finalize(
                job: job,
                completionReason: .runtimeFailure,
                exitCode: nil,
                signal: nil,
                linuxError: job.linuxError,
                runtime: runtimeSnapshot
            )
            _ = Persistence.saveLocalLinuxJob(job)
            throw error
        }
    }

    #endif

    public func claimTerminalInput(jobID: UUID, owner: LocalLinuxTerminalInputOwner) async throws {
        try activeTerminals[jobID]?.activity.checkCancellation()
        guard activeTerminals[jobID] != nil else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard activeTerminals[jobID]?.inputOwner != owner else { return }
        activeTerminals[jobID]?.inputOwner = owner
        await publishActivityCounts()
    }

    public func sendTerminalInput(
        jobID: UUID,
        owner: LocalLinuxTerminalInputOwner,
        data: Data
    ) async throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard terminal.inputOwner == owner else { throw LocalLinuxRuntimeError.terminalInputOwned }
        try terminal.activity.checkCancellation()
        try await terminal.session.send(data)
    }

    public func resizeTerminal(jobID: UUID, columns: UInt16, rows: UInt16) throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        try terminal.activity.checkCancellation()
        try terminal.session.resize(columns: columns, rows: rows)
        terminal.collector.resizeTerminalPreview(columns: Int(columns), rows: Int(rows))
    }

    public func finishTerminalInput(jobID: UUID, owner: LocalLinuxTerminalInputOwner) throws {
        guard let terminal = activeTerminals[jobID] else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
        guard terminal.inputOwner == owner else { throw LocalLinuxRuntimeError.terminalInputOwned }
        try terminal.activity.checkCancellation()
        try terminal.session.finishInput()
    }

    public func interrupt(jobID: UUID) throws {
        if let command = activeCommands[jobID] {
            try command.session.interrupt()
            return
        }
        if let terminal = activeTerminals[jobID] {
            try terminal.session.interrupt()
            return
        }
        throw LocalLinuxRuntimeError.jobNotFound(jobID)
    }

    public func cancel(jobID: UUID) async {
        if let command = activeCommands[jobID] {
            try? command.session.cancel()
            return
        }
        if let terminal = activeTerminals[jobID] {
            try? terminal.session.cancel()
            return
        }
    }

    public func cancel(runID: UUID) async {
        activeCommands.values.filter { $0.job.runID == runID }.forEach { try? $0.session.cancel() }
        activeTerminals.values.filter { $0.job.runID == runID }.forEach { try? $0.session.cancel() }
    }

    public func cancel(sessionID: UUID) async {
        activeCommands.values.filter { $0.job.sessionID == sessionID }.forEach { try? $0.session.cancel() }
        activeTerminals.values.filter { $0.job.sessionID == sessionID }.forEach { try? $0.session.cancel() }
    }

    public func cancelAll() async {
        await cancelAllLinuxRuntimeWork()
    }

    /// 等待本机命令和终端的取消及输出收尾。
    public func cancelAllLinuxRuntimeWork() async {
        let commands = Array(activeCommands.values)
        let terminals = Array(activeTerminals.values)
        commands.forEach { try? $0.session.cancel() }
        terminals.forEach { try? $0.session.cancel() }
        for command in commands {
            _ = await command.session.result()
        }
        for terminal in terminals {
            _ = try? await terminal.session.result()
        }
    }

    /// 系统即将冻结进程时先记录中断归因，再取消 guest 进程组。恢复后不会重放这些命令。
    public func interruptForSystemSuspension() async {
        let interruptedRunIDs = Set(
            activeCommands.values.compactMap(\.job.runID)
                + activeTerminals.values.compactMap(\.job.runID)
        )
        suspensionInterruptedJobIDs.formUnion(activeCommands.keys)
        suspensionInterruptedJobIDs.formUnion(activeTerminals.keys)
        activeCommands.values.forEach { try? $0.session.cancel() }
        activeTerminals.values.forEach { try? $0.session.cancel() }
        for runID in interruptedRunIDs {
            await LocalAgentRuntimeContextManager.shared.finishRun(id: runID, state: .interrupted)
        }
    }

    public func authorizeCommand(
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        approval: LocalLinuxCommandApproval,
        redactionValues: [String]
    ) async throws -> LocalLinuxCommandRuleMatch? {
        await registerRuntimeCancellationIfNeeded()
        let enabled = AppConfigStore.boolValue(for: .localLinuxCommandSafetyEnabled)
        guard let match = await approvalPolicy.evaluate(request: request, kind: kind, isEnabled: enabled) else {
            return nil
        }
        let rawSummary = request.shellScript ?? request.arguments.joined(separator: " ")
        let summary = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            rawSummary,
            values: redactionValues,
            isEnabled: true
        ).text
        let decision: String
        switch match.action {
        case .warn:
            decision = "warned_and_continued"
        case .confirm where approval.approvedRuleIDs.contains(match.ruleID):
            decision = "user_approved"
        case .confirm:
            decision = "approval_required"
        case .deny:
            decision = "denied"
        }
        _ = Persistence.saveLocalLinuxAudit(
            LocalLinuxAuditRecord(
                sessionID: context?.sessionID,
                runID: context?.runID,
                jobID: nil,
                action: kind.rawValue,
                decision: decision,
                scope: kind.rawValue,
                matchedRuleID: match.ruleID,
                redactedSummary: summary,
                executorDeviceID: executorDeviceID
            )
        )
        if match.action == .confirm, !approval.approvedRuleIDs.contains(match.ruleID) {
            throw LocalLinuxRuntimeError.commandApprovalRequired(
                ruleName: match.ruleName,
                matchedText: match.matchedText
            )
        }
        if match.action == .deny {
            throw LocalLinuxRuntimeError.commandDenied(ruleName: match.ruleName, matchedText: match.matchedText)
        }
        let redactedMatchedText = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            match.matchedText,
            values: redactionValues,
            isEnabled: true
        ).text
        return LocalLinuxCommandRuleMatch(
            ruleID: match.ruleID,
            ruleName: match.ruleName,
            action: match.action,
            matchedText: redactedMatchedText
        )
    }

    private func finishCommand(
        jobID: UUID,
        result: LocalLinuxBridgeCommandResult,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async -> LocalLinuxJob {
        guard var active = activeCommands.removeValue(forKey: jobID) else {
            preconditionFailure("结构化命令完成时缺少活跃任务记录：\(jobID)")
        }
        active.collector.finish()
        let completionReason = suspensionInterruptedJobIDs.remove(jobID) != nil
            ? LocalLinuxCompletionReason.interruptedBySuspension
            : result.completionReason
        active.job.completionReason = completionReason
        active.job.exitCode = result.exitCode
        active.job.terminationSignal = result.terminationSignal
        active.job.linuxError = result.linuxError
        active.job.finishedAt = Date()
        active.job.state = terminalState(reason: completionReason, exitCode: result.exitCode)
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: completionReason,
            exitCode: result.exitCode,
            signal: result.terminationSignal,
            linuxError: result.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        await storage.scheduleWorkspaceSizeRefresh(active.workspace)
        await publishActivityCounts()
        return active.job
    }

    private func finishTerminal(
        jobID: UUID,
        result: LocalLinuxBridgeTerminalResult,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async {
        guard var active = activeTerminals.removeValue(forKey: jobID) else { return }
        defer { active.activity.finish() }
        active.collector.finish(completeTerminalUpdates: false)
        let completionReason = suspensionInterruptedJobIDs.remove(jobID) != nil
            ? LocalLinuxCompletionReason.interruptedBySuspension
            : result.completionReason
        active.job.completionReason = completionReason
        active.job.exitCode = result.exitCode
        active.job.terminationSignal = result.terminationSignal
        active.job.linuxError = result.linuxError
        active.job.finishedAt = Date()
        active.job.state = terminalState(reason: completionReason, exitCode: result.exitCode)
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: completionReason,
            exitCode: result.exitCode,
            signal: result.terminationSignal,
            linuxError: result.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        active.collector.finishTerminalUpdates()
        await storage.scheduleWorkspaceSizeRefresh(active.workspace)
        await publishActivityCounts()
    }

    private func failTerminal(
        jobID: UUID,
        error: Error,
        runtimeSnapshot: LocalLinuxRuntimeSnapshot
    ) async {
        guard var active = activeTerminals.removeValue(forKey: jobID) else { return }
        defer { active.activity.finish() }
        active.collector.finish(completeTerminalUpdates: false)
        let wasInterruptedBySuspension = suspensionInterruptedJobIDs.remove(jobID) != nil
        active.job.state = wasInterruptedBySuspension ? .interrupted : .failed
        active.job.completionReason = wasInterruptedBySuspension ? .interruptedBySuspension : .runtimeFailure
        active.job.linuxError = bridgeErrorCode(error)
        active.job.finishedAt = Date()
        applyOutputSnapshot(active.collector.snapshot(), to: &active.job)
        active.job.diagnosticID = await diagnostics.finalize(
            job: active.job,
            completionReason: active.job.completionReason ?? .runtimeFailure,
            exitCode: nil,
            signal: nil,
            linuxError: active.job.linuxError,
            runtime: runtimeSnapshot
        )
        _ = Persistence.saveLocalLinuxJob(active.job)
        active.collector.finishTerminalUpdates()
        await storage.scheduleWorkspaceSizeRefresh(active.workspace)
        await publishActivityCounts()
    }

    private func makeJob(
        requestID: UInt64,
        kind: LocalLinuxJobKind,
        request: LocalLinuxJobRequest,
        context: AgentRuntimeContext?,
        workspace: LocalAgentWorkspace,
        toolCallID: String?
    ) -> LocalLinuxJob {
        LocalLinuxJob(
            requestID: requestID,
            kind: kind,
            sessionID: context?.sessionID ?? workspace.sessionID,
            runID: context?.runID,
            rootRunID: context?.rootRunID,
            parentRunID: context?.parentRunID,
            toolCallID: toolCallID ?? context?.toolCallID,
            workspaceID: workspace.id,
            executorDeviceID: executorDeviceID,
            request: request
        )
    }

    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }

    private func trigger(for kind: LocalLinuxJobKind) -> LocalLinuxRuntimeTrigger {
        switch kind {
        case .recipe: return .recipe
        case .localMCP: return .localMCP
        case .browser: return .agentRequest
        default: return .agentRequest
        }
    }

    private func terminalState(reason: LocalLinuxCompletionReason, exitCode: Int32) -> LocalLinuxJobState {
        switch reason {
        case .exited: return exitCode == 0 ? .completed : .failed
        case .cancelled: return .cancelled
        case .interruptedBySuspension: return .interrupted
        default: return .failed
        }
    }

    private func applyOutputSnapshot(_ output: LocalLinuxOutputSnapshot, to job: inout LocalLinuxJob) {
        job.stdoutBytes = output.stdoutBytes + output.terminalBytes
        job.stderrBytes = output.stderrBytes
        if output.writeError != nil, job.linuxError == nil || job.linuxError == 0 {
            job.linuxError = -5
            job.state = .failed
            job.completionReason = .runtimeFailure
        }
    }

    private func bridgeErrorCode(_ error: Error) -> Int32? {
        guard let runtimeError = error as? LocalLinuxRuntimeError,
              case .bridgeFailure(_, let code) = runtimeError else { return nil }
        return code
    }

    #if os(macOS)
    /// 在创建任务记录前分别确认 Shell 与 cwd，避免把同一个 ENOENT 裸错误码
    /// 同时用于两种故障，也防止无效启动在任务列表里留下失败占位。
    private func validateTerminalLaunchPaths(
        _ request: LocalLinuxBridgeTerminalRequest,
        requestID: UInt64
    ) async throws {
        #if os(macOS)
        var isShellDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.executable, isDirectory: &isShellDirectory),
              !isShellDirectory.boolValue, FileManager.default.isExecutableFile(atPath: request.executable) else {
            throw LocalLinuxRuntimeError.terminalShellUnavailable(request.executable)
        }
        if let directory = request.workingDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LocalLinuxRuntimeError.terminalWorkingDirectoryUnavailable(directory)
            }
        }
        #endif
    }

    /// 公共 CommandSession 接收 execve 风格路径，不替调用方搜索 PATH。
    /// 找不到候选时保留原字符串，由原生进程报告错误。
    private func resolveExecutableFromPATH(
        _ command: String,
        environment: [String: String],
        workingDirectory: String?,
        requestID: UInt64
    ) async -> String {
        #if os(macOS)
        let directory = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return (try? MacNativeProcess.resolveExecutable(command, environment: environment, workingDirectory: directory).path) ?? command
        #endif
    }

    #endif

    static func executableSearchCandidates(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> [String] {
        guard !command.hasPrefix("/"), !command.contains("/") else { return [command] }
        let path = environment["PATH"]
            ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.split(separator: ":", omittingEmptySubsequences: false).map { rawDirectory in
            let directory = String(rawDirectory)
            if directory.hasPrefix("/") {
                return directory == "/" ? "/\(command)" : "\(directory)/\(command)"
            }
            let relativeDirectory = directory.isEmpty ? "." : directory
            guard let cwd, cwd.hasPrefix("/") else {
                return "\(relativeDirectory)/\(command)"
            }
            let base = cwd == "/" ? "" : cwd
            return ("\(base)/\(relativeDirectory)/\(command)" as NSString).standardizingPath
        }
    }

    private func registerRuntimeCancellationIfNeeded() async {
        guard !didRegisterRuntimeCancellation else { return }
        didRegisterRuntimeCancellation = true
        await runtime.setActiveWorkCancellationHandler { [weak self] in
            await self?.cancelAllLinuxRuntimeWork()
        }
    }

    private func publishActivityCounts() async {
        let browserJobCount = Persistence.loadLocalLinuxJobs(activeOnly: true)
            .filter { $0.kind == .browser }
            .count
        await runtime.updateActivityCounts(
            jobs: activeCommands.count + browserJobCount,
            terminals: activeTerminals.count,
            localMCP: (await runtime.snapshot()).activeMCPProcessCount
        )
    }

    public func refreshActivityCounts() async {
        await publishActivityCounts()
    }

    private func redactedPersistedRequest(
        _ request: LocalLinuxJobRequest,
        values: [String]
    ) -> LocalLinuxJobRequest {
        let enabled = AppConfigStore.boolValue(for: .localLinuxEnvironmentPrivacyEnabled)
        func redact(_ value: String) -> String {
            LocalLinuxProcessEnvironmentProvider.redactModelOutput(
                value,
                values: values,
                isEnabled: enabled
            ).text
        }
        var result = request
        result.executable = redact(result.executable)
        result.arguments = result.arguments.map(redact)
        result.workingDirectory = result.workingDirectory.map(redact)
        result.shellScript = result.shellScript.map(redact)
        return result
    }
}
