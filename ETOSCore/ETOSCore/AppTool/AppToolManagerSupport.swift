// ============================================================================
// AppToolManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具管理器的持久化、辅助计算与通用工具定义。
// ============================================================================

import Foundation
import Combine
import os.log

extension AppToolManager {
    func toolDefinition(for kind: AppToolKind) -> InternalToolDefinition {
        InternalToolDefinition(
            name: kind.toolName,
            description: kind.builtInDescriptionPromptID.map { BuiltInPromptStore.template(for: $0) } ?? kind.toolDescription,
            parameters: kind.parameters,
            isBlocking: true
        )
    }

    func restoreStateForTests(
        chatToolsEnabled: Bool,
        enabledKinds: Set<AppToolKind>,
        approvalPolicies: [AppToolKind: AppToolApprovalPolicy] = [:],
        customJSTools: [AppToolCustomJSTool]? = nil
    ) {
        self.chatToolsEnabled = chatToolsEnabled
        enabledToolIDs = Set(enabledKinds.map(\.rawValue))
        toolApprovalPolicies = approvalPolicies.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard pair.key.requiresApproval else { return }
            guard pair.value != .askEveryTime else { return }
            result[pair.key.rawValue] = pair.value
        }
        AppConfigStore.persistSynchronously(.bool(chatToolsEnabled), for: .appToolsChatToolsEnabled)
        AppConfigStore.persistStringArray(Array(enabledToolIDs).sorted(), for: .appToolsEnabledToolIDs)
        let rawPolicyValues = toolApprovalPolicies.mapValues(\.rawValue)
        AppConfigStore.persistStringDictionary(rawPolicyValues, for: .appToolsToolApprovalPolicies)
        if let customJSTools {
            self.customJSTools = customJSTools
        }
        objectWillChange.send()
    }

    static func runSandboxFileOperationOffMainThread<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        let undoContext = SandboxFileToolSupport.undoContext
        let fileSpace = SandboxFileToolSupport.fileSpace
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try SandboxFileToolSupport.$fileSpace.withValue(fileSpace) {
                        try SandboxFileToolSupport.$undoContext.withValue(undoContext) {
                            try operation()
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runSQLiteOperationOffMainThread<T>(
        _ operation: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func persistEnabledToolIDs() {
        AppConfigStore.persistStringArray(Array(enabledToolIDs).sorted(), for: .appToolsEnabledToolIDs)
        objectWillChange.send()
    }

    func persistToolApprovalPolicies() {
        let rawPolicyValues = toolApprovalPolicies.mapValues(\.rawValue)
        AppConfigStore.persistStringDictionary(rawPolicyValues, for: .appToolsToolApprovalPolicies)
        objectWillChange.send()
    }

    static func normalizedRequestID(_ rawValue: String?) -> String {
        if let normalized = normalizedOptionalText(rawValue) {
            return normalized
        }
        return UUID().uuidString
    }

    static func normalizedQuestionID(_ rawValue: String?, fallbackIndex: Int) -> String {
        normalizedOptionalText(rawValue) ?? "question_\(fallbackIndex + 1)"
    }

    static func uniqueIdentifier(from candidate: String, seen: inout Set<String>) -> String {
        if !seen.contains(candidate) {
            seen.insert(candidate)
            return candidate
        }
        var suffix = 2
        while true {
            let next = "\(candidate)_\(suffix)"
            if !seen.contains(next) {
                seen.insert(next)
                return next
            }
            suffix += 1
        }
    }

    static func normalizedOptionalText(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func prettyPrintedJSONString(from payload: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(data: data, encoding: .utf8)
                ?? NSLocalizedString("错误：工具结果序列化失败。", comment: "App tool result serialization fallback")
        } catch {
            return NSLocalizedString("错误：工具结果序列化失败。", comment: "App tool result serialization error")
        }
    }
}
