import Foundation

/// 调度器只持有进程生命周期，不依赖移动端内核或桌面进程的具体实现。
protocol LocalCommandSession: Sendable {
    func send(_ data: Data) async throws
    func finishInput() throws
    func interrupt() throws
    func cancel() throws
    func result() async -> LocalLinuxBridgeCommandResult
}

protocol LocalTerminalSession: Sendable {
    func send(_ data: Data) async throws
    func finishInput() throws
    func resize(columns: UInt16, rows: UInt16) throws
    func interrupt() throws
    func cancel() throws
    func result() async throws -> LocalLinuxBridgeTerminalResult
}

public struct LocalLinuxBridgeCommandResult: Equatable, Sendable {
    public let requestID: UInt64
    public let completionReason: LocalLinuxCompletionReason
    public let exitCode: Int32
    public let terminationSignal: Int32
    public let linuxError: Int32
    public let stdoutBytes: UInt64
    public let stderrBytes: UInt64
    public let elapsedMilliseconds: UInt64
}

public enum LocalLinuxTerminalShellConfiguration {
    public static let defaultPath = "/bin/sh"

    static let commonPaths = [
        defaultPath,
        "/bin/ash",
        "/bin/bash",
        "/bin/zsh",
        "/usr/bin/bash",
        "/usr/bin/zsh",
        "/usr/bin/fish"
    ]

    public static func normalizedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return defaultPath
        }
        let normalized = (trimmed as NSString).standardizingPath
        guard normalized != "/" else { return defaultPath }
        return normalized
    }

    public static func loginArguments(for shellPath: String) -> [String] {
        let normalized = normalizedPath(shellPath)
        return [normalized, "-l"]
    }

    static func candidatePaths(shellsFileContents: String?) -> [String] {
        var paths = commonPaths
        if let shellsFileContents {
            paths.append(contentsOf: shellsFileContents.split(whereSeparator: \Character.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("/"), !value.hasPrefix("#") else { return nil }
                return normalizedPath(value)
            })
        }

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

public struct LocalLinuxBridgeTerminalRequest: Equatable, Sendable {
    public let terminalID: UInt64
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let columns: UInt16
    public let rows: UInt16

    public init(
        terminalID: UInt64,
        executable: String = "/bin/sh",
        arguments: [String] = ["/bin/sh", "-l"],
        environment: [String: String],
        workingDirectory: String?,
        columns: UInt16,
        rows: UInt16
    ) {
        self.terminalID = terminalID
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
    }
}

public struct LocalLinuxBridgeTerminalResult: Equatable, Sendable {
    public let terminalID: UInt64
    public let completionReason: LocalLinuxCompletionReason
    public let exitCode: Int32
    public let terminationSignal: Int32
    public let linuxError: Int32
    public let outputBytes: UInt64
    public let droppedBytes: UInt64
    public let elapsedMilliseconds: UInt64
}

public struct LocalLinuxBridgeDiagnosticEvent: Codable, Equatable, Sendable {
    public let category: UInt32
    public let kind: UInt32
    public let scope: UInt32
    public let architecture: UInt32
    public let backend: UInt32
    public let linuxError: Int32
    public let signal: Int32
    public let opcode: UInt32
    public let sequence: UInt64
    public let requestID: UInt64
    public let guestProgramCounter: UInt64
    public let systemCallNumber: UInt64
    public let guestProcessID: UInt32
    public let guestThreadGroupID: UInt32
    public let processName: String?
    public let systemCallName: String?
    public let buildIdentity: String
}
