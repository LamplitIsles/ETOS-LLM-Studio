// ============================================================================
// GuideSourceService.swift
// ============================================================================
// ETOS LLM Studio
//
// 只允许读取当前构建精确 Commit 的公开源码；LocalBuild 与短 SHA 不做猜测。
// ============================================================================

import Foundation

public enum GuideBuildVersion {
    public static func fullCommitSHA(bundle: Bundle = .main) -> String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ETOS_DEBUG_COMMIT_HASH"],
           isFullSHA(override) {
            return override.lowercased()
        }
        #endif
        guard let value = bundle.object(forInfoDictionaryKey: "ETCommitHash") as? String,
              isFullSHA(value) else {
            return nil
        }
        return value.lowercased()
    }

    public static func displayCommit(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "LocalBuild" }
        return String(value.prefix(7))
    }

    public static func isFullSHA(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count == 40 && normalized.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
