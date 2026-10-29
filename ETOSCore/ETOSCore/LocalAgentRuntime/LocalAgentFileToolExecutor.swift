// ============================================================================
// LocalAgentFileToolExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 复用现有文件工具名称，并按 URI 路由到 Documents 和外部目录。
// 外部目录通过 Documents/ETOSMounts 虚拟命名空间访问，不要求启动 Linux。
// ============================================================================

import Foundation

public actor LocalAgentFileToolExecutor {
    public static let shared = LocalAgentFileToolExecutor()

    enum Backend: Equatable {
        case app
        case appMountRoot
        case appMount(UUID)
    }

    struct RoutedPath: Equatable {
        let backend: Backend
        let original: String
        let path: String
    }

    struct TrustedContext: Sendable {
        let sessionID: UUID
        let runID: UUID
        let triggeringMessageID: UUID?
        let toolCallID: String
        let selectedMCPServerIDs: [UUID]
    }

    private enum MutationPayload: Sendable {
        case app(mutationID: UUID, rootDirectory: URL)
    }

    private struct MutationEntry: Sendable {
        let id: UUID
        let operation: String
        let payload: MutationPayload
    }

    private let mountManager: LocalLinuxMountManager
    private let trustedRunValidator: @Sendable (UUID, UUID) throws -> Void
    private var mutationsByRunID: [UUID: [MutationEntry]] = [:]
    private var runActivities: [UUID: LocalLinuxActivityLease] = [:]
    private var activeRunOperations = Set<UUID>()
    private var runOperationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let maximumUndoEntriesPerRun = 64

    public init(mountManager: LocalLinuxMountManager = .shared) {
        self.mountManager = mountManager
        self.trustedRunValidator = { runID, sessionID in
            try Self.validateTrustedConversationRun(
                Persistence.loadConversationRun(id: runID), sessionID: sessionID
            )
        }
    }

    init(
        mountManager: LocalLinuxMountManager = .shared,
        trustedRunValidator: @escaping @Sendable (UUID, UUID) throws -> Void
    ) {
        self.mountManager = mountManager
        self.trustedRunValidator = trustedRunValidator
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        defer { activity.finish() }
        var arguments = try decode(argumentsJSON)
        let trustedContext = removeTrustedContext(from: &arguments)
        let acquiredRunID = trustedContext?.runID
        if let trustedContext {
            try trustedRunValidator(trustedContext.runID, trustedContext.sessionID)
            // App 文件工具也可能拥有撤销快照；没有 Linux Run 记录时仍需由宿主收尾。
            if runActivities[trustedContext.runID] == nil {
                runActivities[trustedContext.runID] = try LocalLinuxActivityBarrier.shared.begin()
            }
        }
        if let acquiredRunID {
            await acquireRunOperation(acquiredRunID)
        }
        defer {
            if let acquiredRunID {
                releaseRunOperation(acquiredRunID)
            }
        }
        if let trustedContext {
            try activity.checkCancellation()
            try trustedRunValidator(trustedContext.runID, trustedContext.sessionID)
        }
        let routedPaths = try pathArguments(in: arguments).map { key, value in
            (key, try route(value))
        }

        if toolName == AppToolKind.undoSandboxMutation.toolName, let trustedContext {
            return try await executeUndo(context: trustedContext)
        }

        if routedPaths.contains(where: { $0.1.backend == .appMountRoot }) {
            return try listAppMounts(toolName: toolName, routedPaths: routedPaths)
        }

        if routedPaths.contains(where: {
            if case .appMount = $0.1.backend { return true }
            return false
        }) {
            return try await executeAppMountTool(
                toolName: toolName,
                arguments: arguments,
                routedPaths: routedPaths,
                trustedContext: trustedContext
            )
        }

        for (key, routed) in routedPaths where routed.backend == .app {
            arguments[key] = routed.path
        }
        guard isMutatingFileTool(toolName), let trustedContext else {
            let result = try await executeAppTool(toolName: toolName, arguments: arguments)
            return try addingAppMountRootIfNeeded(
                to: result,
                toolName: toolName,
                arguments: arguments
            )
        }
        let mutationID = UUID()
        let result = try await executeAppTool(
            toolName: toolName,
            arguments: arguments,
            undoContext: .init(runID: trustedContext.runID, mutationID: mutationID)
        )
        if SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: trustedContext.runID) {
            await commitMutation(
                MutationEntry(
                    id: mutationID,
                    operation: toolName,
                    payload: .app(
                        mutationID: mutationID,
                        rootDirectory: StorageUtility.documentsDirectory
                    )
                ),
                runID: trustedContext.runID
            )
        }
        return result
    }

    private func executeAppMountTool(
        toolName: String,
        arguments: [String: Any],
        routedPaths: [(String, RoutedPath)],
        trustedContext: TrustedContext?
    ) async throws -> String {
        let mountIDs = Set(routedPaths.compactMap { _, routed -> UUID? in
            guard case .appMount(let id) = routed.backend else { return nil }
            return id
        })
        guard mountIDs.count == 1,
              let mountID = mountIDs.first,
              routedPaths.allSatisfy({ _, routed in
                  routed.backend == .appMount(mountID)
              }),
              let record = Persistence.loadLocalLinuxMounts().first(where: { $0.id == mountID }) else {
            throw LocalLinuxRuntimeError.invalidPath(
                routedPaths.map(\.1.original).joined(separator: ", ")
            )
        }
        if isMutatingFileTool(toolName), record.access != .readWrite {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("此外部文件夹为只读挂载，不能修改内容。", comment: "Read-only app mount mutation error")
            )
        }

        let directoryAccess = try await mountManager.accessExternalDirectory(id: mountID)
        var rewrittenArguments = arguments
        for (key, routed) in routedPaths {
            rewrittenArguments[key] = routed.path
        }
        let fileSpace = SandboxFileToolSupport.FileSpace(
            rootDirectory: directoryAccess.url,
            displayRoot: LocalLinuxMountManager.appMountDisplayPath(id: mountID),
            retainedAccess: directoryAccess
        )

        return try await SandboxFileToolSupport.$fileSpace.withValue(fileSpace) {
            guard isMutatingFileTool(toolName), let trustedContext else {
                return try await executeAppTool(
                    toolName: toolName,
                    arguments: rewrittenArguments
                )
            }
            let mutationID = UUID()
            let result = try await executeAppTool(
                toolName: toolName,
                arguments: rewrittenArguments,
                undoContext: .init(runID: trustedContext.runID, mutationID: mutationID)
            )
            if SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: trustedContext.runID) {
                await commitMutation(
                    MutationEntry(
                        id: mutationID,
                        operation: toolName,
                        payload: .app(
                            mutationID: mutationID,
                            rootDirectory: directoryAccess.url
                        )
                    ),
                    runID: trustedContext.runID
                )
            }
            return result
        }
    }

    private func listAppMounts(
        toolName: String,
        routedPaths: [(String, RoutedPath)]
    ) throws -> String {
        guard toolName == AppToolKind.listSandboxDirectory.toolName,
              routedPaths.count == 1,
              routedPaths[0].0 == "path" else {
            throw LocalLinuxRuntimeError.invalidPath(
                routedPaths.map(\.1.original).joined(separator: ", ")
            )
        }
        let formatter = ISO8601DateFormatter()
        let items: [[String: Any]] = Persistence.loadLocalLinuxMounts()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { record in
                [
                    "path": LocalLinuxMountManager.appMountDisplayPath(id: record.id),
                    "uri": LocalLinuxMountManager.appMountURI(id: record.id),
                    "name": record.displayName,
                    "isDirectory": true,
                    "size": 0,
                    "modifiedAt": formatter.string(from: record.updatedAt),
                    "mountID": record.id.uuidString.lowercased(),
                    "access": record.access.rawValue,
                    "authorizationState": record.authorizationState.rawValue
                ]
            }
        return try encode([
            "path": LocalLinuxMountManager.appMountsDisplayPath,
            "items": items
        ])
    }

    private func addingAppMountRootIfNeeded(
        to result: String,
        toolName: String,
        arguments: [String: Any]
    ) throws -> String {
        guard toolName == AppToolKind.listSandboxDirectory.toolName,
              isDocumentsRootPath(arguments["path"] as? String) else {
            return result
        }
        let records = Persistence.loadLocalLinuxMounts()
        guard !records.isEmpty else { return result }

        var payload = try decode(result)
        var items = payload["items"] as? [[String: Any]] ?? []
        guard !items.contains(where: {
            ($0["path"] as? String) == LocalLinuxMountManager.appMountsDisplayPath
        }) else { return result }
        items.append([
            "path": LocalLinuxMountManager.appMountsDisplayPath,
            "name": LocalLinuxMountManager.appMountsDirectoryName,
            "isDirectory": true,
            "size": 0,
            "modifiedAt": ISO8601DateFormatter().string(
                from: records.map(\.updatedAt).max() ?? Date()
            ),
            "virtual": true
        ])
        payload["items"] = items
        return try encode(payload)
    }

    private func isDocumentsRootPath(_ path: String?) -> Bool {
        let normalized = (path ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return normalized.isEmpty || normalized.caseInsensitiveCompare("Documents") == .orderedSame
    }

    private func executeUndo(context: TrustedContext) async throws -> String {
        guard var entries = mutationsByRunID[context.runID], let entry = entries.popLast() else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("当前 Agent Run 没有可撤销的文件修改。", comment: "Agent file undo history empty")
            )
        }
        if entries.isEmpty {
            mutationsByRunID.removeValue(forKey: context.runID)
        } else {
            mutationsByRunID[context.runID] = entries
        }

        var shouldRestoreHistory = true
        do {
            switch entry.payload {
            case .app(let mutationID, let rootDirectory):
                guard SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: context.runID) else {
                    shouldRestoreHistory = false
                    throw SandboxFileToolError.noUndoHistory
                }
                let result = try SandboxFileToolSupport.undoMutation(
                    id: mutationID,
                    runID: context.runID,
                    rootDirectory: rootDirectory
                )
                return try encode([
                    "operation": result.operation,
                    "recordedAt": result.recordedAt
                ])

            }
        } catch {
            if shouldRestoreHistory {
                var restored = mutationsByRunID[context.runID] ?? []
                restored.append(entry)
                mutationsByRunID[context.runID] = restored
            }
            throw error
        }
    }

    private func commitMutation(_ entry: MutationEntry, runID: UUID) async {
        var entries = mutationsByRunID[runID] ?? []
        entries.append(entry)
        let stale: MutationEntry?
        if entries.count > maximumUndoEntriesPerRun {
            stale = entries.removeFirst()
        } else {
            stale = nil
        }
        mutationsByRunID[runID] = entries
        if let stale {
            await discardMutation(stale, runID: runID)
        }
    }

    private func discardMutation(_ entry: MutationEntry, runID: UUID) async {
        switch entry.payload {
        case .app(let mutationID, _):
            SandboxFileToolSupport.discardUndoMutation(id: mutationID, runID: runID)
        }
    }

    /// Run 结束后，撤销入口已不再可达，因此同步清理内存记录与 app 快照。
    public func finishRun(id runID: UUID) async {
        let activity = runActivities.removeValue(forKey: runID)
        defer { activity?.finish() }
        await acquireRunOperation(runID)
        defer { releaseRunOperation(runID) }
        mutationsByRunID.removeValue(forKey: runID)
        SandboxFileToolSupport.discardUndoMutations(runID: runID)
    }

    public func finishActiveRunsForHostDataOperation() async {
        precondition(LocalLinuxActivityBarrier.shared.isSuspended)
        for id in Array(runActivities.keys) { await finishRun(id: id) }
    }

    static func validateTrustedConversationRun(_ run: ConversationRun?, sessionID: UUID) throws {
        guard let run, !run.status.isTerminal else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 已经结束，不能再次执行迟到的工具调用。", comment: "Terminal Agent run cannot be resumed")
            )
        }
        guard run.sessionID == sessionID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 标识不属于当前会话。", comment: "Agent run session mismatch")
            )
        }
    }

    private func acquireRunOperation(_ runID: UUID) async {
        guard activeRunOperations.contains(runID) else {
            activeRunOperations.insert(runID)
            return
        }
        await withCheckedContinuation { continuation in
            runOperationWaiters[runID, default: []].append(continuation)
        }
    }

    private func releaseRunOperation(_ runID: UUID) {
        if var waiters = runOperationWaiters[runID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                runOperationWaiters.removeValue(forKey: runID)
            } else {
                runOperationWaiters[runID] = waiters
            }
            next.resume()
            return
        }
        activeRunOperations.remove(runID)
    }

    func isMutatingFileTool(_ toolName: String) -> Bool {
        [
            AppToolKind.writeSandboxFile.toolName,
            AppToolKind.moveSandboxItem.toolName,
            AppToolKind.copySandboxItem.toolName,
            AppToolKind.createSandboxDirectory.toolName,
            AppToolKind.batchEditSandboxFile.toolName,
            AppToolKind.editSandboxFile.toolName,
            AppToolKind.deleteSandboxItem.toolName
        ].contains(toolName)
    }

    private func executeAppTool(
        toolName: String,
        arguments: [String: Any],
        undoContext: SandboxFileToolSupport.SandboxUndoContext? = nil
    ) async throws -> String {
        let argumentsJSON = try encode(arguments)
        return try await SandboxFileToolSupport.$undoContext.withValue(undoContext) {
            try await AppToolManager.shared.executeToolForBuiltInMCP(
                toolName: toolName,
                argumentsJSON: argumentsJSON
            )
        }
    }

    private func route(_ rawPath: String) throws -> RoutedPath {
        let value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("linux://") || value.hasPrefix("mount://") {
            throw LocalLinuxRuntimeError.invalidPath(rawPath)
        }
        if value.hasPrefix("app://") {
            let relative = String(value.dropFirst("app://".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return try routeAppPath(relative, original: rawPath)
        }
        return try routeAppPath(rawPath, original: rawPath)
    }

    private func routeAppPath(_ path: String, original: String) throws -> RoutedPath {
        let normalized = path
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relative: String
        if normalized == "Documents" {
            relative = ""
        } else if normalized.hasPrefix("Documents/") {
            relative = String(normalized.dropFirst("Documents/".count))
        } else {
            relative = normalized
        }

        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard components.first.map(String.init) == LocalLinuxMountManager.appMountsDirectoryName else {
            return RoutedPath(backend: .app, original: original, path: path)
        }
        guard components.count > 1 else {
            return RoutedPath(backend: .appMountRoot, original: original, path: "")
        }
        guard let id = UUID(uuidString: String(components[1])) else {
            throw LocalLinuxRuntimeError.invalidPath(original)
        }
        let relativePath = components.dropFirst(2).joined(separator: "/")
        return RoutedPath(backend: .appMount(id), original: original, path: relativePath)
    }

    private func pathArguments(in arguments: [String: Any]) throws -> [(String, String)] {
        let keys = ["path", "source_path", "destination_path"]
        return keys.compactMap { key in
            guard let value = arguments[key] else { return nil }
            guard let path = value as? String else { return (key, "") }
            return (key, path)
        }
    }

    private func removeTrustedContext(from arguments: inout [String: Any]) -> TrustedContext? {
        let sessionID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.conversationSourceSessionIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let runID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentRunIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let triggeringMessageID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let toolCallID = arguments.removeValue(forKey: MCPBuiltInAppToolServer.conversationToolCallIDArgument) as? String
        let selectedIDs = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentSelectedMCPServerIDsArgument) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
        guard let sessionID, let runID, let toolCallID, !toolCallID.isEmpty else { return nil }
        return TrustedContext(
            sessionID: sessionID,
            runID: runID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            selectedMCPServerIDs: selectedIDs
        )
    }

    func invalidArguments(_ key: String) -> AppToolExecutionError {
        .invalidArguments(
            String(
                format: NSLocalizedString("错误：文件工具缺少或无法解析参数 %@。", comment: "Local file tool invalid argument"),
                key
            )
        )
    }

    private func decode(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidArguments("JSON")
        }
        return object
    }

    func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else { throw invalidArguments("JSON") }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else { throw invalidArguments("JSON") }
        return string
    }

}
