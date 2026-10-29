// ============================================================================
// RoleplayMVUInitializer.swift
// ============================================================================
// ETOS LLM Studio
//
// 从开场白 <initvar> 构建会话级原生 MVU 初始状态。
// ============================================================================

import Foundation

struct RoleplayMVUInitializationResult: Hashable, Sendable {
    var data: RoleplayMVUData
    var loadedSourceCount: Int
    var failureReasons: [String]
}

enum RoleplayMVUInitializer {
    static func initialize(
        greeting: String,
        existingVariables: [String: JSONValue],
        macroContext: RoleplayMacroContext
    ) -> RoleplayMVUInitializationResult {
        let greetingPayloads = taggedContents(named: "initvar", in: greeting)
        var failures: [String] = []
        var loadedSourceCount = 0
        var statData: [String: JSONValue] = [:]

        for payload in greetingPayloads {
            let failureCount = failures.count
            mergePayload(
                payload,
                sourceName: NSLocalizedString("开场白 <initvar>", comment: "Roleplay greeting initvar source"),
                macroContext: macroContext,
                into: &statData,
                failures: &failures
            )
            if failures.count == failureCount { loadedSourceCount += 1 }
        }

        let existing = RoleplayMVUData(variables: existingVariables)
        RoleplayMVUData.merge(existing.statData, into: &statData)
        var data = RoleplayMVUData(
            statData: statData,
            displayData: statData,
            extra: existing.extra
        )
        data.regenerateSchema()
        return RoleplayMVUInitializationResult(
            data: data,
            loadedSourceCount: loadedSourceCount,
            failureReasons: failures
        )
    }

    static func taggedContents(named tag: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(NSRegularExpression.escapedPattern(for: tag))\\b[^>]*>([\\s\\S]*?)</\(NSRegularExpression.escapedPattern(for: tag))>",
            options: [.caseInsensitive]
        ) else { return [] }
        let value = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: value.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            return unwrapCodeFence(value.substring(with: match.range(at: 1)))
        }
    }

    private static func mergePayload(
        _ payload: String,
        sourceName: String,
        macroContext: RoleplayMacroContext,
        into variables: inout [String: JSONValue],
        failures: inout [String]
    ) {
        let resolved = RoleplayMacroResolver.resolve(payload, context: macroContext)
        do {
            guard case .dictionary(let parsed) = try RoleplayYAMLParser.parse(resolved) else {
                failures.append(
                    String(format: NSLocalizedString("%@的根节点不是对象。", comment: "Roleplay initvar root is not an object"), sourceName)
                )
                return
            }
            RoleplayMVUData.merge(parsed, into: &variables)
        } catch {
            failures.append(
                String(
                    format: NSLocalizedString("%@解析失败：%@", comment: "Roleplay initvar parse failure"),
                    sourceName,
                    error.localizedDescription
                )
            )
        }
    }

    private static func unwrapCodeFence(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"^```[^\n]*\n([\s\S]*?)\n```$"#,
            options: [.caseInsensitive]
        ) else { return trimmed }
        let value = trimmed as NSString
        guard let match = regex.firstMatch(
            in: trimmed,
            range: NSRange(location: 0, length: value.length)
        ), match.numberOfRanges > 1 else { return trimmed }
        return value.substring(with: match.range(at: 1))
    }
}
