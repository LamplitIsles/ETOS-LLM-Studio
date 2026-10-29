// ============================================================================
// LocalAgentRuntimeTests.swift
// ============================================================================
// 本地 Agent Runtime 纯逻辑与文件管线测试
// - 环境变量脱敏与双输出边界
// - 命令安全规则、存储布局与损坏检测
// - Linux / Browser 工具协议和 MCP JSON 转换
// ============================================================================

import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("本地 Agent Runtime 测试")
struct LocalAgentRuntimeTests {
    private final class TerminalResponseCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test("Chat 与 Agent 只切换本地 Linux 能力")
    func agentModeOnlyControlsLocalLinuxCapability() {
        let withoutLinux = AgentToolCapabilityPolicy.resolve(
            mode: .agent,
            isToolContextIsolated: false,
            localLinuxEnabled: false
        )
        #expect(!withoutLinux.preparesAgentRun)
        #expect(withoutLinux.includesConversationTools)
        #expect(withoutLinux.includesBrowserTools)
        #expect(!withoutLinux.includesLocalLinuxTools)

        let chat = AgentToolCapabilityPolicy.resolve(
            mode: .chat,
            isToolContextIsolated: false,
            localLinuxEnabled: true
        )
        #expect(!chat.preparesAgentRun)
        #expect(chat.includesConversationTools)
        #expect(chat.includesBrowserTools)
        #expect(!chat.includesLocalLinuxTools)

        let agent = AgentToolCapabilityPolicy.resolve(
            mode: .agent,
            isToolContextIsolated: false,
            localLinuxEnabled: true
        )
        #expect(agent.includesConversationTools)
        #expect(agent.includesBrowserTools)
        #if os(macOS)
        #expect(agent.preparesAgentRun)
        #expect(agent.includesLocalLinuxTools)
        #else
        #expect(!agent.preparesAgentRun)
        #expect(!agent.includesLocalLinuxTools)
        #endif

        let isolated = AgentToolCapabilityPolicy.resolve(
            mode: .agent,
            isToolContextIsolated: true,
            localLinuxEnabled: true
        )
        #expect(!isolated.preparesAgentRun)
        #expect(!isolated.includesConversationTools)
        #expect(!isolated.includesBrowserTools)
        #expect(!isolated.includesLocalLinuxTools)
    }

    @Test("Browser 能力完整时不显示能力检查区域")
    func completeBrowserCapabilitiesHaveNoMissingItems() {
        let complete = BrowserAgentCapabilities(
            platform: "watchOS",
            isExperimental: true,
            supportsNavigation: true,
            supportsSnapshot: true,
            supportsClick: true,
            supportsTyping: true,
            supportsScrolling: true,
            supportsJavaScript: true,
            supportsScreenshot: true,
            supportsDownload: true,
            supportsUserTakeover: true,
            supportsIPhoneDelegation: true,
            notes: []
        )
        #expect(complete.unavailableCapabilities.isEmpty)

        let limited = BrowserAgentCapabilities(
            platform: "watchOS",
            isExperimental: true,
            supportsNavigation: true,
            supportsSnapshot: true,
            supportsClick: true,
            supportsTyping: true,
            supportsScrolling: true,
            supportsJavaScript: true,
            supportsScreenshot: false,
            supportsDownload: false,
            supportsUserTakeover: true,
            supportsIPhoneDelegation: true,
            notes: []
        )
        #expect(limited.unavailableCapabilities == [.screenshot, .download])
    }

    @Test("环境变量脱敏遵循长度、重叠和关闭规则")
    func redactEnvironmentValues() {
        let enabled = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            "short abc token-123456 token-123456-extra",
            values: ["abc", "token-123456", "token-123456-extra"],
            isEnabled: true
        )
        #expect(enabled.didRedact)
        #expect(!enabled.text.contains("token-123456"))
        #expect(enabled.text.contains("abc"))

        let disabled = LocalLinuxProcessEnvironmentProvider.redactModelOutput(
            "token-123456",
            values: ["token-123456"],
            isEnabled: false
        )
        #expect(disabled.text == "token-123456")
        #expect(!disabled.didRedact)
    }

    @Test("输出收集器跨 chunk 打码且保留用户原始输出")
    func outputCollectorRedactsAcrossChunks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: ["super-secret"],
            privacyEnabled: true,
            modelByteLimit: 4_096
        )

        collector.append(stream: .stdout, data: Data("value=super-".utf8))
        collector.append(stream: .stdout, data: Data("secret\n".utf8), streamEnded: true)
        collector.finish()

        let modelOutput = try String(contentsOf: modelURL, encoding: .utf8)
        let snapshot = collector.snapshot()
        #expect(collector.userVisiblePreview().contains("super-secret"))
        #expect(!modelOutput.contains("super-secret"))
        #expect(modelOutput.contains("su********et"))
        #expect(modelOutput.contains(NSLocalizedString(
            "\n[隐私模式已按环境变量值打码；用户原始日志未被修改]\n",
            comment: "Linux model output redaction notice"
        )))
        #expect(snapshot.didRedact)
        #expect(snapshot.stdoutBytes == UInt64("value=super-secret\n".utf8.count))
    }

    @Test("模型输出达到预算后标记截断但原始输出继续写入")
    func outputCollectorTruncatesOnlyModelProjection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: [],
            privacyEnabled: true,
            modelByteLimit: 16
        )
        let content = String(repeating: "x", count: 128)
        collector.append(stream: .stderr, data: Data(content.utf8), streamEnded: true)
        collector.finish()

        let snapshot = collector.snapshot()
        let modelOutput = try String(contentsOf: modelURL, encoding: .utf8)
        #expect(snapshot.didTruncateModelOutput)
        #expect(snapshot.stderrBytes == 128)
        #expect(collector.userVisiblePreview().contains(content))
        #expect(modelOutput.contains("模型输出已截断"))
    }

    @Test("终端收集器生成富文本并转发协议查询响应")
    func outputCollectorBuildsTerminalPresentationAndForwardsResponses() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let responseCapture = TerminalResponseCapture()
        let collector = try LocalLinuxOutputCollector(
            rawURL: directory.appendingPathComponent("raw.log"),
            modelURL: directory.appendingPathComponent("model.log"),
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 4_096,
            terminalColumns: 80,
            terminalRows: 24,
            terminalResponseHandler: { responseCapture.append($0) }
        )

        collector.append(stream: .terminal, data: Data("\u{1B}[31m红色\u{1B}[0m\u{1B}[6n默认".utf8))
        collector.finish()

        let darkPresentation = try #require(collector.userVisibleTerminalPresentation())
        let lightPresentation = try #require(
            collector.userVisibleTerminalPresentation(appearance: .light)
        )
        #expect(darkPresentation.plainText == "红色默认")
        #expect(darkPresentation.attributedText != AttributedString("红色默认"))
        #expect(lightPresentation.attributedText != darkPresentation.attributedText)
        #expect(String(decoding: responseCapture.data, as: UTF8.self) == "\u{1B}[1;5R")
    }

    @Test("原始输出分页跨越大帧时不会丢失内容")
    func rawOutputPagingPreservesFrameRemainder() async throws {
        let documents = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let manager = LocalLinuxStorageManager(documentsDirectory: documents)
        let layout = try await manager.prepareLayout()
        let directory = layout.workspaces.appendingPathComponent("paging", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rawURL = directory.appendingPathComponent("raw.log")
        let modelURL = directory.appendingPathComponent("model.log")
        let collector = try LocalLinuxOutputCollector(
            rawURL: rawURL,
            modelURL: modelURL,
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 1_024
        )
        let expected = String(repeating: "0123456789", count: 10)
        collector.append(stream: .stdout, data: Data(expected.utf8), streamEnded: true)
        collector.finish()

        let relativePath = try await manager.relativePath(for: rawURL)
        var cursor = LocalLinuxRawOutputCursor()
        var joined = ""
        var visited: Set<LocalLinuxRawOutputCursor> = []
        while true {
            #expect(visited.insert(cursor).inserted)
            let page = try await manager.readRawOutputPage(
                relativePath: relativePath,
                cursor: cursor,
                maximumBytes: 1
            )
            joined += page.text
            guard let next = page.nextCursor else {
                #expect(page.isComplete)
                break
            }
            cursor = next
        }
        #expect(joined == "\n[stdout]\n" + expected)
    }

    @Test("命令规则逐段匹配前缀、后缀与正则并可整体关闭")
    func commandSafetyRules() {
        let prefix = LocalLinuxCommandRule(
            name: "删除提醒",
            pattern: "/bin/rm -rf",
            matchKind: .prefix,
            scope: .all,
            action: .confirm,
            sortIndex: 0
        )
        let expression = LocalLinuxCommandRule(
            name: "包安装",
            pattern: #"(^|[;&|]\s*)apk\s+add\b"#,
            matchKind: .regularExpression,
            scope: .shell,
            action: .warn,
            sortIndex: 1
        )
        let suffix = LocalLinuxCommandRule(
            name: "强制参数",
            pattern: "--force",
            matchKind: .suffix,
            scope: .shell,
            action: .confirm,
            sortIndex: 2
        )
        let earlyWarning = LocalLinuxCommandRule(
            name: "输出提醒",
            pattern: "echo",
            matchKind: .prefix,
            scope: .shell,
            action: .warn,
            sortIndex: 0
        )
        let laterDenial = LocalLinuxCommandRule(
            name: "拒绝删除",
            pattern: "/bin/rm",
            matchKind: .prefix,
            scope: .shell,
            action: .deny,
            sortIndex: 1
        )
        let runRequest = LocalLinuxJobRequest(
            executable: "/bin/rm",
            arguments: ["/bin/rm", "-rf", "/tmp/demo"]
        )
        let shellRequest = LocalLinuxJobRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "apk add bash"],
            shellScript: "echo ready; apk add bash"
        )
        let compoundRequest = LocalLinuxJobRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "echo ready && /bin/rm -rf /tmp/demo"],
            shellScript: "echo ready && /bin/rm -rf /tmp/demo"
        )
        let suffixRequest = LocalLinuxJobRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "deploy --force && echo done"],
            shellScript: "deploy --force && echo done"
        )
        let quotedConnectorRequest = LocalLinuxJobRequest(
            executable: "/bin/sh",
            arguments: ["/bin/sh", "-lc", "echo '/bin/rm -rf /tmp && still text'"],
            shellScript: "echo '/bin/rm -rf /tmp && still text'"
        )
        let structuredArgumentRequest = LocalLinuxJobRequest(
            executable: "/bin/echo",
            arguments: ["/bin/echo", "text && /bin/rm -rf /tmp"]
        )

        let runMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix, expression],
            request: runRequest,
            kind: .run,
            isEnabled: true
        )
        let shellMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix, expression],
            request: shellRequest,
            kind: .shell,
            isEnabled: true
        )
        let disabled = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: runRequest,
            kind: .run,
            isEnabled: false
        )
        let compoundMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: compoundRequest,
            kind: .shell,
            isEnabled: true
        )
        let suffixMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [suffix],
            request: suffixRequest,
            kind: .shell,
            isEnabled: true
        )
        let quotedConnectorMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: quotedConnectorRequest,
            kind: .shell,
            isEnabled: true
        )
        let recipeMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: compoundRequest,
            kind: .recipe,
            isEnabled: true
        )
        let structuredArgumentMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [prefix],
            request: structuredArgumentRequest,
            kind: .run,
            isEnabled: true
        )
        let mostRestrictiveMatch = LocalLinuxApprovalPolicy.evaluate(
            rules: [earlyWarning, laterDenial],
            request: compoundRequest,
            kind: .shell,
            isEnabled: true
        )

        #expect(runMatch?.ruleID == prefix.id)
        #expect(shellMatch?.ruleID == expression.id)
        #expect(compoundMatch?.ruleID == prefix.id)
        #expect(suffixMatch?.ruleID == suffix.id)
        #expect(quotedConnectorMatch == nil)
        #expect(recipeMatch?.ruleID == prefix.id)
        #expect(structuredArgumentMatch == nil)
        #expect(mostRestrictiveMatch?.ruleID == laterDenial.id)
        #expect(disabled == nil)
        #expect(
            LocalLinuxApprovalPolicy.shellCommandFragments(
                "echo \"a && b\" && /bin/rm -rf /tmp || deploy --force; printf 'x|y' | sed s/x/y/\ncleanup"
            ) == [
                "echo \"a && b\"",
                "/bin/rm -rf /tmp",
                "deploy --force",
                "printf 'x|y'",
                "sed s/x/y/",
                "cleanup"
            ]
        )
    }

    @Test("结构化命令按冻结 PATH 解析可执行文件候选")
    func commandExecutableSearchCandidates() {
        #expect(
            LocalLinuxJobScheduler.executableSearchCandidates(
                command: "python3",
                environment: ["PATH": "/usr/local/bin:/usr/bin:tools:"],
                workingDirectory: "/workspace/demo"
            ) == [
                "/usr/local/bin/python3",
                "/usr/bin/python3",
                "/workspace/demo/tools/python3",
                "/workspace/demo/python3"
            ]
        )
        #expect(
            LocalLinuxJobScheduler.executableSearchCandidates(
                command: "./configure",
                environment: ["PATH": "/bin"],
                workingDirectory: "/workspace/demo"
            ) == ["./configure"]
        )
    }

    @Test("交互终端 Shell 路径会标准化并以登录模式启动")
    func terminalShellLaunchConfiguration() {
        #expect(LocalLinuxTerminalShellConfiguration.normalizedPath("bash") == "/bin/sh")
        #expect(LocalLinuxTerminalShellConfiguration.normalizedPath("/bin/../bin/bash") == "/bin/bash")
        #expect(
            LocalLinuxTerminalShellConfiguration.loginArguments(for: "/bin/zsh")
                == ["/bin/zsh", "-l"]
        )
    }

    @Test("外部目录无需启动 Linux 即可通过 App 文件工具访问")
    func externalDirectoryAccessDoesNotRequireLinuxRuntime() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "external".write(to: file, atomically: true, encoding: .utf8)

        let mountID = UUID()
        let bookmark = try directory.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
        let record = LocalLinuxMountRecord(
            id: mountID,
            displayName: "External",
            bookmark: bookmark,
            access: .readOnly,
            guestPath: "/mnt/etos/\(mountID.uuidString.lowercased())",
            authorizationState: .needsReauthorization
        )
        #expect(Persistence.saveLocalLinuxMount(record))
        defer { _ = Persistence.deleteLocalLinuxMount(id: mountID) }

        do {
            let access = try await LocalLinuxMountManager().accessExternalDirectory(id: mountID)
            #expect(access.url.standardizedFileURL == directory.standardizedFileURL)
            #expect(try String(contentsOf: access.url.appendingPathComponent("note.txt"), encoding: .utf8) == "external")
        }
        #expect(Persistence.loadLocalLinuxMounts().first(where: { $0.id == mountID })?.authorizationState == .available)

        let executor = LocalAgentFileToolExecutor()
        let documents = try await executor.execute(
            toolName: AppToolKind.listSandboxDirectory.toolName,
            argumentsJSON: #"{"path":"Documents"}"#
        )
        #expect(documents.contains(LocalLinuxMountManager.appMountsDisplayPath))

        let mounts = try await executor.execute(
            toolName: AppToolKind.listSandboxDirectory.toolName,
            argumentsJSON: #"{"path":"Documents/ETOSMounts"}"#
        )
        #expect(mounts.contains(LocalLinuxMountManager.appMountURI(id: mountID)))

        let read = try await executor.execute(
            toolName: AppToolKind.readSandboxFile.toolName,
            argumentsJSON: "{\"path\":\"\(LocalLinuxMountManager.appMountURI(id: mountID))/note.txt\"}"
        )
        #expect(read.contains("external"))
        #expect(read.contains("\(LocalLinuxMountManager.appMountDisplayPath(id: mountID))/note.txt"))

        await #expect(throws: LocalLinuxRuntimeError.self) {
            try await executor.execute(
                toolName: AppToolKind.writeSandboxFile.toolName,
                argumentsJSON: "{\"path\":\"\(LocalLinuxMountManager.appMountURI(id: mountID))/note.txt\",\"content\":\"changed\"}"
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")

        var writableRecord = record
        writableRecord.access = .readWrite
        writableRecord.authorizationState = .available
        #expect(Persistence.saveLocalLinuxMount(writableRecord))
        _ = try await executor.execute(
            toolName: AppToolKind.writeSandboxFile.toolName,
            argumentsJSON: "{\"path\":\"\(LocalLinuxMountManager.appMountURI(id: mountID))/note.txt\",\"content\":\"changed\"}"
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "changed")
        _ = try SandboxFileToolSupport.undoLastMutation(rootDirectory: directory)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")
    }

    @Test("Agent 工作区可为未落库临时会话补建父记录")
    func agentWorkspaceCreatesMissingTemporarySession() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        let sessionID = UUID()
        let workspace = LocalAgentWorkspace(
            sessionID: sessionID,
            guestPath: LocalLinuxStorageManager.guestWorkspacePath(
                forHostRelativePath: "Workspaces/test"
            ),
            hostRelativePath: "Workspaces/test"
        )

        try store.saveLocalAgentWorkspace(workspace)

        #expect(store.loadChatSession(id: sessionID)?.isTemporary == true)
        let savedWorkspaces = try store.loadLocalAgentWorkspaces(sessionID: sessionID)
        let saved = try #require(savedWorkspaces.first)
        #expect(savedWorkspaces.count == 1)
        #expect(saved.id == workspace.id)
        #expect(saved.sessionID == sessionID)
        #expect(saved.profileID == nil)
        #expect(saved.guestPath == "/mnt/workspaces/test")
        #expect(saved.hostRelativePath == "Workspaces/test")
    }

    @Test("用户终端工作区不属于任何聊天会话")
    func interactiveUserWorkspaceIsSessionIndependent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        let workspace = LocalAgentWorkspace(
            id: LocalLinuxStorageManager.interactiveUserWorkspaceID,
            sessionID: nil,
            profileID: nil,
            guestPath: LocalLinuxStorageManager.guestWorkspacePath(
                forHostRelativePath: "Workspaces/UserTerminal"
            ),
            hostRelativePath: "Workspaces/UserTerminal"
        )

        try store.saveLocalAgentWorkspace(workspace)

        let saved = try #require(store.loadLocalAgentWorkspaces().first)
        #expect(saved.id == LocalLinuxStorageManager.interactiveUserWorkspaceID)
        #expect(saved.sessionID == nil)
        #expect(saved.profileID == nil)
        #expect(saved.guestPath == "/mnt/workspaces/UserTerminal")
    }

    @Test("终端兼容性诊断直接显示且保持长度边界")
    func terminalDiagnosticsAreVisibleAndBounded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalLinuxDiagnosticsRecorder(
            storage: LocalLinuxStorageManager(documentsDirectory: directory, appGroupLayout: nil)
        )
        let olderJobID = UUID()
        let newerJobID = UUID()
        let olderEvent = LocalLinuxBridgeDiagnosticEvent(
            category: 1,
            kind: 1,
            scope: 3,
            architecture: 2,
            backend: 1,
            linuxError: 0,
            signal: 4,
            opcode: 0xd503201f,
            sequence: 7,
            requestID: 31,
            guestProgramCounter: 0x4000,
            systemCallNumber: 0,
            guestProcessID: 101,
            guestThreadGroupID: 101,
            processName: "python3",
            systemCallName: nil,
            buildIdentity: "test-build"
        )
        let newerEvent = LocalLinuxBridgeDiagnosticEvent(
            category: 1,
            kind: 1,
            scope: 3,
            architecture: 2,
            backend: 1,
            linuxError: 0,
            signal: 4,
            opcode: 0xd4200000,
            sequence: 9,
            requestID: 32,
            guestProgramCounter: 0x5000,
            systemCallNumber: 0,
            guestProcessID: 202,
            guestThreadGroupID: 202,
            processName: "pip",
            systemCallName: nil,
            buildIdentity: "test-build"
        )

        await recorder.append([olderEvent], jobID: olderJobID)
        await recorder.append([newerEvent], jobID: newerJobID)

        let summary = LocalLinuxDiagnosticPresentation.userSummary(newerEvent)
        #expect(summary.contains("process=pip"))
        #expect(summary.contains("signal=SIGILL"))
        #expect(summary.contains("opcode=0xd4200000"))
        #expect(summary.utf8.count <= 256)
        #expect(await recorder.latestEvent(jobID: olderJobID) == olderEvent)

        let oversizedEvent = LocalLinuxBridgeDiagnosticEvent(
            category: 1,
            kind: 1,
            scope: 3,
            architecture: 2,
            backend: 1,
            linuxError: 0,
            signal: 4,
            opcode: 0xd4200000,
            sequence: 10,
            requestID: 33,
            guestProgramCounter: 0x6000,
            systemCallNumber: 0,
            guestProcessID: 303,
            guestThreadGroupID: 303,
            processName: String(repeating: "超长进程", count: 100),
            systemCallName: String(repeating: "超长调用", count: 100),
            buildIdentity: String(repeating: "超长构建", count: 100)
        )
        await recorder.append([oversizedEvent], jobID: newerJobID)
        #expect(LocalLinuxDiagnosticPresentation.userSummary(oversizedEvent).utf8.count <= 256)

        let collector = try LocalLinuxOutputCollector(
            rawURL: directory.appendingPathComponent("terminal.raw"),
            modelURL: directory.appendingPathComponent("terminal.model"),
            redactionValues: [],
            privacyEnabled: false,
            modelByteLimit: 4_096,
            terminalColumns: 80,
            terminalRows: 24
        )
        collector.append(stream: .terminal, data: Data("ETOS:/mnt/home# ".utf8))
        collector.appendTerminalDiagnostic(newerEvent)
        collector.finish()
        let presentation = try #require(collector.userVisibleTerminalPresentation())
        #expect(presentation.plainText.contains(summary))
        #expect(presentation.plainText.contains(LocalLinuxDiagnosticPresentation.userGuidance))
        #expect(collector.userVisiblePreview() == "ETOS:/mnt/home#")
        let modelOutput = try String(
            contentsOf: directory.appendingPathComponent("terminal.model"),
            encoding: .utf8
        )
        #expect(modelOutput.contains(summary))
        #expect(!modelOutput.contains(LocalLinuxDiagnosticPresentation.userGuidance))
    }

    @Test("Linux、Browser 与反馈工具协议暴露完整动作")
    func toolDefinitionsExposeExpectedContract() throws {
        #expect(Set(LocalLinuxToolDefinitions.all.map(\.name)) == ["linux_run", "linux_shell", "linux_process"])
        #expect(BrowserAgentToolDefinitions.all.map(\.name) == ["browser_control"])

        let browserData = try JSONEncoder().encode(BrowserAgentToolDefinitions.all[0].parameters)
        let browserSchema = try #require(String(data: browserData, encoding: .utf8))
        #expect(browserSchema.contains("evaluate_javascript"))
        #expect(browserSchema.contains("screenshot"))
        #expect(browserSchema.contains("download"))

        let feedbackData = try JSONEncoder().encode(AppToolKind.submitFeedbackTicket.parameters)
        let feedbackSchema = try #require(String(data: feedbackData, encoding: .utf8))
        #expect(feedbackSchema.contains("linux_runtime_diagnostic_id"))
    }

    @Test("Browser 数据 profile 与快照可以稳定编码")
    func browserModelsCodableRoundTrip() throws {
        let snapshot = BrowserAgentSnapshot(
            title: "Example",
            url: "https://example.com",
            text: "正文",
            elements: [.init(
                index: 0,
                elementID: "continue-button",
                domRevision: 1,
                role: "button",
                label: "继续",
                value: nil,
                isVisible: true,
                bounds: BrowserAgentElementBounds(x: 0, y: 0, width: 120, height: 44),
                actions: ["click"]
            )],
            wasTruncated: false,
            domRevision: 1
        )
        let decoded = try JSONDecoder().decode(
            BrowserAgentSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)
        #expect(BrowserAgentDataProfile(rawValue: "session_isolated") == .sessionIsolated)
        #expect(BrowserAgentDataProfile(rawValue: "persistent_shared") == .persistentShared)
    }

    #if canImport(WebKit) && canImport(UIKit) && !os(watchOS)
    @Test("Browser 下载只携带目标域和路径适用的 Cookie")
    func browserDownloadCookieScope() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .domain: ".example.com",
            .path: "/account",
            .name: "session",
            .value: "secret",
            .secure: "TRUE"
        ]))
        #expect(BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://api.example.com/account/file")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://api.example.com/accounting")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "http://api.example.com/account/file")!))
        #expect(!BrowserSessionManager.cookieApplies(cookie, to: URL(string: "https://example.net/account/file")!))
    }
    #endif

    @Test("任务规则命中与 Agent 提示词会随 Run 快照稳定编码")
    func agentRunSnapshotCodableRoundTrip() throws {
        let ruleID = UUID()
        let request = LocalLinuxJobRequest(
            executable: "/bin/rm",
            arguments: ["/bin/rm", "-rf", "/tmp/demo"],
            commandRuleMatch: LocalLinuxCommandRuleMatch(
                ruleID: ruleID,
                ruleName: "删除确认",
                action: .confirm,
                matchedText: "/bin/rm -rf /tmp/demo"
            )
        )
        let decodedRequest = try JSONDecoder().decode(
            LocalLinuxJobRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decodedRequest.commandRuleMatch?.ruleID == ruleID)
        #expect(decodedRequest.commandRuleMatch?.matchedText == "/bin/rm -rf /tmp/demo")

        let sessionID = UUID()
        let runID = UUID()
        let workspaceID = UUID()
        let promptID = UUID()
        let context = AgentRuntimeContext(
            sessionID: sessionID,
            runID: runID,
            rootRunID: runID,
            parentRunID: nil,
            triggeringMessageID: UUID(),
            toolCallID: nil,
            workspaceID: workspaceID,
            workingDirectory: "/workspace/demo",
            environmentSnapshotHash: "snapshot-hash",
            environmentValues: ["TOKEN": "secret"],
            environmentRedactionValues: ["secret"],
            environmentReferenceSnapshots: [],
            mountIDs: [],
            browserSessionID: sessionID,
            browserDataProfile: .sessionIsolated,
            promptProfileID: promptID,
            promptContent: "固定的 Agent 提示词",
            executorDeviceID: "test-device",
            mode: .agent
        )
        let decodedContext = try JSONDecoder().decode(
            AgentRuntimeContext.self,
            from: JSONEncoder().encode(context)
        )
        #expect(decodedContext == context)
        #expect(decodedContext.promptProfileID == promptID)
        #expect(decodedContext.promptContent == "固定的 Agent 提示词")
    }

    @Test("v13 Linux 任务迁移保留记录并接受 Browser 类型")
    func browserJobSchemaMigration() throws {
        let queue = try DatabaseQueue()
        let existingID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL)")
            try PersistenceGRDBStore.createLocalAgentRuntimeTables(db)
            try db.execute(sql: "DROP TABLE local_linux_diagnostics")
            try db.execute(sql: "DROP TABLE local_linux_audit")
            try db.execute(sql: "DROP TABLE local_linux_jobs")
            try db.execute(sql: """
                CREATE TABLE local_linux_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    request_id INTEGER NOT NULL UNIQUE,
                    kind TEXT NOT NULL CHECK(kind IN ('run', 'shell', 'terminal', 'local_mcp', 'recipe')),
                    session_id TEXT, run_id TEXT, root_run_id TEXT, parent_run_id TEXT,
                    tool_call_id TEXT, workspace_id TEXT, executor_device_id TEXT NOT NULL,
                    request_json BLOB NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'queued', 'starting', 'running', 'waiting_for_input',
                        'completed', 'failed', 'cancelled', 'interrupted'
                    )),
                    completion_reason TEXT, exit_code INTEGER, termination_signal INTEGER,
                    linux_error INTEGER, stdout_bytes INTEGER NOT NULL DEFAULT 0,
                    stderr_bytes INTEGER NOT NULL DEFAULT 0, output_relative_path TEXT,
                    model_output_relative_path TEXT, diagnostic_id TEXT,
                    created_at REAL NOT NULL, started_at REAL, finished_at REAL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE local_linux_diagnostics (
                    id TEXT PRIMARY KEY NOT NULL, job_id TEXT, request_id INTEGER NOT NULL,
                    category TEXT NOT NULL, payload_json BLOB NOT NULL,
                    redacted_summary TEXT NOT NULL, occurrence_count INTEGER NOT NULL DEFAULT 1,
                    created_at REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE local_linux_audit (
                    id TEXT PRIMARY KEY NOT NULL, session_id TEXT, run_id TEXT, job_id TEXT,
                    action TEXT NOT NULL, decision TEXT NOT NULL, scope TEXT NOT NULL,
                    matched_rule_id TEXT, redacted_summary TEXT NOT NULL,
                    executor_device_id TEXT NOT NULL, created_at REAL NOT NULL
                )
            """)
            try db.execute(
                sql: """
                    INSERT INTO local_linux_jobs (
                        id, request_id, kind, executor_device_id, request_json, state, created_at
                    ) VALUES (?, 1, 'run', 'test-device', ?, 'completed', 1)
                """,
                arguments: [existingID, Data("{}".utf8)]
            )

            try PersistenceGRDBStore.migrateLocalAgentBrowserSchema(db)

            let preserved = try String.fetchOne(
                db,
                sql: "SELECT kind FROM local_linux_jobs WHERE id = ?",
                arguments: [existingID]
            )
            #expect(preserved == "run")
            try db.execute(
                sql: """
                    INSERT INTO local_linux_jobs (
                        id, request_id, kind, executor_device_id, request_json, state, created_at
                    ) VALUES (?, 2, 'browser', 'test-device', ?, 'completed', 2)
                """,
                arguments: [UUID().uuidString, Data("{}".utf8)]
            )
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_linux_jobs") == 2)
        }
    }

    @Test("命令规则迁移保留旧记录并接受后缀匹配")
    func commandRuleSuffixMigration() throws {
        let queue = try DatabaseQueue()
        let existingID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE local_linux_command_rules (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    pattern TEXT NOT NULL,
                    match_kind TEXT NOT NULL CHECK(match_kind IN ('prefix', 'regular_expression')),
                    scope TEXT NOT NULL CHECK(scope IN ('run', 'shell', 'all')),
                    action TEXT NOT NULL CHECK(action IN ('warn', 'confirm', 'deny')),
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    sort_index INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(
                sql: """
                    INSERT INTO local_linux_command_rules (
                        id, name, pattern, match_kind, scope, action,
                        is_enabled, sort_index, created_at, updated_at
                    ) VALUES (?, '旧前缀规则', 'rm ', 'prefix', 'shell', 'confirm', 1, 0, 1, 1)
                """,
                arguments: [existingID]
            )

            try PersistenceAuxiliaryGRDBStore.migrateLocalLinuxCommandRuleSuffix(db)

            #expect(try String.fetchOne(
                db,
                sql: "SELECT name FROM local_linux_command_rules WHERE id = ?",
                arguments: [existingID]
            ) == "旧前缀规则")
            try db.execute(
                sql: """
                    INSERT INTO local_linux_command_rules (
                        id, name, pattern, match_kind, scope, action,
                        is_enabled, sort_index, created_at, updated_at
                    ) VALUES (?, '后缀规则', '--force', 'suffix', 'shell', 'warn', 1, 1, 2, 2)
                """,
                arguments: [UUID().uuidString]
            )
            #expect(try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM local_linux_command_rules WHERE match_kind = 'suffix'"
            ) == 1)
        }
    }

    @Test("本地 Agent 修复迁移可以从缺失表的数据库重建")
    func localAgentSchemaRepairFromMissingTables() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL)")
            try PersistenceGRDBStore.migrateLocalAgentBrowserSchema(db)
            let jobTable = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'local_linux_jobs'"
            )
            #expect(jobTable?.contains("'browser'") == true)
        }
    }

    @Test("RootFS 更新只沿清单中的确定链路执行")
    func rootFSMigrationUsesDeclaredPath() throws {
        let seedA = String(repeating: "a", count: 64)
        let seedB = String(repeating: "b", count: 64)
        let seedC = String(repeating: "c", count: 64)
        let scriptSHA = String(repeating: "d", count: 64)
        let migrations = [
            LocalLinuxRootFSMigrationDefinition(
                id: "001-a-to-b",
                fromSeedSHA256: seedA,
                toSeedSHA256: seedB,
                scriptFile: "001-a-to-b.sh",
                scriptSHA256: scriptSHA
            ),
            LocalLinuxRootFSMigrationDefinition(
                id: "002-b-to-c",
                fromSeedSHA256: seedB,
                toSeedSHA256: seedC,
                scriptFile: "002-b-to-c.sh",
                scriptSHA256: scriptSHA
            )
        ]
        let resource = LocalLinuxRootFSMigrationResource(
            manifestURL: URL(fileURLWithPath: "/manifest.json"),
            manifest: LocalLinuxRootFSMigrationManifest(
                format: "etos-rootfs-migrations-v1",
                targetSeedSHA256: seedC,
                migrations: migrations
            ),
            scriptURLs: [:]
        )

        #expect(try resource.migrationPath(from: seedA).map(\.id) == ["001-a-to-b", "002-b-to-c"])
        #expect(try resource.migrationPath(from: seedC).isEmpty)
        #expect(throws: LocalLinuxRuntimeError.self) {
            _ = try resource.migrationPath(from: String(repeating: "e", count: 64))
        }
    }

    @Test("RootFS 迁移完成后只推进安装收据")
    func rootFSMigrationAdvancesReceipt() async throws {
        let documents = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: documents) }
        let manager = LocalLinuxStorageManager(documentsDirectory: documents)
        let layout = try await manager.prepareLayout()
        try FileManager.default.createDirectory(at: layout.rootFSData, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: layout.rootFS.appendingPathComponent("meta.db").path,
            contents: Data()
        )
        let previousSeed = String(repeating: "a", count: 64)
        let targetSeed = String(repeating: "b", count: 64)
        try Data("format=ish-rootfs-install-v1\nseed_archive_sha256=\(previousSeed)\n".utf8)
            .write(to: layout.rootFS.appendingPathComponent("rootfs-installation.txt"))

        try await manager.recordInstalledSeedSHA256(targetSeed)

        #expect(await manager.systemIntegrity() == .installed(seedSHA256: targetSeed))
        #expect(FileManager.default.fileExists(atPath: layout.rootFSData.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
