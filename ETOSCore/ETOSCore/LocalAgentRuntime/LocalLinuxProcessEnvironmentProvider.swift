// ============================================================================
// LocalLinuxProcessEnvironmentProvider.swift
// ============================================================================
// ETOS LLM Studio
//
// 设置页变量只在创建 guest 进程时注入；原始输出留给用户，模型副本再按
// OpenMinis 的值匹配规则脱敏。
// ============================================================================

import CryptoKit
import Foundation

public struct LocalLinuxEnvironmentSnapshot: Equatable, Sendable {
    public let values: [String: String]
    public let hash: String
    public let redactionValues: [String]

    public init(values: [String: String], hash: String, redactionValues: [String]) {
        self.values = values
        self.hash = hash
        self.redactionValues = redactionValues
    }
}

public struct LocalLinuxRedactionResult: Equatable, Sendable {
    public let text: String
    public let didRedact: Bool
}

public actor LocalLinuxProcessEnvironmentProvider {
    public static let shared = LocalLinuxProcessEnvironmentProvider()

    #if os(macOS)
    static var baseEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var values: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/zsh"
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            values[key] = inherited[key]
        }
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["TERM_PROGRAM"] = LocalLinuxTerminalIdentity.programName
        values["TERM_PROGRAM_VERSION"] = LocalLinuxTerminalIdentity.programVersion
        return values
    }
    #endif

    public func variables() -> [LocalLinuxEnvironmentVariable] {
        Persistence.loadLocalLinuxEnvironmentVariables()
    }

    public func save(_ variable: LocalLinuxEnvironmentVariable) throws {
        guard Self.isValidName(variable.name) else {
            throw LocalLinuxRuntimeError.invalidEnvironmentVariable(variable.name)
        }
        guard !variable.value.utf8.contains(0) else {
            throw LocalLinuxRuntimeError.invalidEnvironmentVariable(variable.name)
        }
        guard Persistence.saveLocalLinuxEnvironmentVariable(variable) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法保存 Linux 环境变量。", comment: "Save Linux environment variable failure")
            )
        }
    }

    public func delete(id: UUID) throws {
        guard Persistence.deleteLocalLinuxEnvironmentVariable(id: id) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("无法删除 Linux 环境变量。", comment: "Delete Linux environment variable failure")
            )
        }
    }

    public func snapshot(additional: [String: String] = [:]) throws -> LocalLinuxEnvironmentSnapshot {
        #if os(macOS)
        var environment = Self.baseEnvironment
        let enabledVariables = variables().filter(\.isEnabled)
        for variable in enabledVariables {
            guard Self.isValidName(variable.name), !variable.value.utf8.contains(0) else {
                throw LocalLinuxRuntimeError.invalidEnvironmentVariable(variable.name)
            }
            environment[variable.name] = variable.value
        }
        for (name, value) in additional {
            guard Self.isValidName(name), !value.utf8.contains(0) else {
                throw LocalLinuxRuntimeError.invalidEnvironmentVariable(name)
            }
            environment[name] = value
        }

        return try snapshot(explicitValues: environment, redactionValues: enabledVariables.map(\.value) + Array(additional.values))
        #else
        throw LocalLinuxRuntimeError.runtimeUnavailable(NSLocalizedString("本机 shell 仅在 macOS 可用。", comment: "Native shell unavailable"))
        #endif
    }

    /// 为本地 MCP 解析 GRDB 变量引用。Agent Run 可传入冻结快照，确保设置页
    /// 在执行期间发生修改时不会改变同一 Run 的进程环境。
    public func snapshot(
        referenceIDs: [UUID],
        inheritGlobalEnvironment: Bool,
        additional: [String: String] = [:],
        frozenGlobalValues: [String: String]? = nil,
        frozenReferences: [LocalLinuxEnvironmentReferenceSnapshot]? = nil,
        frozenRedactionValues: [String]? = nil,
        baseValues: [String: String]? = nil
    ) throws -> LocalLinuxEnvironmentSnapshot {
        #if os(macOS)
        let allVariables = variables()
        var environment: [String: String]
        var redactionValues: [String]
        if inheritGlobalEnvironment {
            if let frozenGlobalValues {
                environment = frozenGlobalValues
                redactionValues = frozenRedactionValues ?? []
            } else {
                environment = baseValues ?? Self.baseEnvironment
                let enabled = allVariables.filter(\.isEnabled)
                for variable in enabled {
                    environment[variable.name] = variable.value
                }
                redactionValues = enabled.map(\.value)
            }
        } else {
            // 即使不继承用户变量，仍保留所选执行环境启动所需的基础 PATH/HOME。
            environment = baseValues ?? Self.baseEnvironment
            redactionValues = []
        }

        let selectedIDs = Set(referenceIDs)
        if let frozenReferences {
            for variable in frozenReferences where selectedIDs.contains(variable.id) && variable.isEnabled {
                environment[variable.name] = variable.value
                redactionValues.append(variable.value)
            }
        } else {
            for variable in allVariables where selectedIDs.contains(variable.id) && variable.isEnabled {
                environment[variable.name] = variable.value
                redactionValues.append(variable.value)
            }
        }
        for (name, value) in additional {
            environment[name] = value
            redactionValues.append(value)
        }
        return try snapshot(explicitValues: environment, redactionValues: redactionValues)
        #else
        throw LocalLinuxRuntimeError.runtimeUnavailable(NSLocalizedString("本机 shell 仅在 macOS 可用。", comment: "Native shell unavailable"))
        #endif
    }

    public func snapshot(explicitValues: [String: String]) throws -> LocalLinuxEnvironmentSnapshot {
        try snapshot(explicitValues: explicitValues, redactionValues: Array(explicitValues.values))
    }

    public func snapshot(
        explicitValues: [String: String],
        redactionValues: [String]
    ) throws -> LocalLinuxEnvironmentSnapshot {
        try makeSnapshot(explicitValues: explicitValues, redactionValues: redactionValues)
    }

    private func makeSnapshot(
        explicitValues: [String: String],
        redactionValues: [String]
    ) throws -> LocalLinuxEnvironmentSnapshot {
        for (name, value) in explicitValues {
            guard Self.isValidName(name), !value.utf8.contains(0) else {
                throw LocalLinuxRuntimeError.invalidEnvironmentVariable(name)
            }
        }

        let canonical = explicitValues.keys.sorted().map { key in
            "\(key.utf8.count):\(key)\(explicitValues[key]?.utf8.count ?? 0):\(explicitValues[key] ?? "")"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let normalizedRedactionValues = Array(Set(redactionValues.filter { $0.count >= 5 }))
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs < rhs }
                return lhs.count > rhs.count
            }
        return LocalLinuxEnvironmentSnapshot(
            values: explicitValues,
            hash: digest,
            redactionValues: normalizedRedactionValues
        )
    }

    public nonisolated static func redactModelOutput(
        _ text: String,
        values: [String],
        isEnabled: Bool
    ) -> LocalLinuxRedactionResult {
        guard isEnabled, !text.isEmpty else {
            return LocalLinuxRedactionResult(text: text, didRedact: false)
        }
        var result = text
        var didRedact = false
        for value in Array(Set(values.filter { $0.count >= 5 })).sorted(by: {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }) where result.contains(value) {
            let replacement: String
            if value.count < 8 {
                replacement = String(repeating: "*", count: value.count)
            } else {
                replacement = String(value.prefix(2))
                    + String(repeating: "*", count: value.count - 4)
                    + String(value.suffix(2))
            }
            result = result.replacingOccurrences(of: value, with: replacement)
            didRedact = true
        }
        return LocalLinuxRedactionResult(text: result, didRedact: didRedact)
    }

    public nonisolated static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first.value == 95 || CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.dropFirst().allSatisfy { scalar in
            scalar.value == 95 || CharacterSet.alphanumerics.contains(scalar)
        }
    }
}
