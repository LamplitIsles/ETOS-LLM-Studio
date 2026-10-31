import Foundation
import GRDB

public enum SkillLibraryError: LocalizedError, Sendable {
    case changed, persistenceFailed, duplicateName, invalidStoredValue
    public var errorDescription: String? {
        switch self {
        case .changed: NSLocalizedString("技能内容已变化，请重新打开后再试。", comment: "")
        case .persistenceFailed, .invalidStoredValue: NSLocalizedString("保存技能设置失败，请重试。", comment: "")
        case .duplicateName: NSLocalizedString("已有同名技能。", comment: "")
        }
    }
}

struct SkillLibraryState: Sendable {
    var revision: UInt64 = 0
    let skills: [SkillMetadata]
    let enabledNames: Set<String>
    let chatToolsEnabled: Bool

    static func loadInitial() -> Self {
        let installed = SkillStore.installBuiltInSkillsIfNeeded()
        let skills = SkillStore.listSkills()
        let stored = Set(AppConfigStore.stringArrayValue(for: .skillsEnabledNames, defaultValue: []) ?? [])
        let enabled = stored.union(installed).intersection(Set(skills.map(\.name)))
        if enabled != stored { AppConfigStore.persistStringArray(enabled.sorted(), for: .skillsEnabledNames) }
        return Self(skills: skills, enabledNames: enabled,
                    chatToolsEnabled: AppConfigStore.boolValue(for: .skillsChatToolsEnabled, defaultValue: true))
    }
}

/// 更新单个字段前读数据库的最新值，不能用页面打开时的整份列表覆盖其他修改。
enum SkillLibrarySettings {
    static func read(in db: Database) throws -> (Set<String>, Bool) {
        let raw = try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                                      arguments: [AppConfigKey.skillsEnabledNames.rawValue])
        let names: Set<String>
        if let raw {
            guard let decoded = AppConfigStore.decodeStringArray(from: raw) else { throw SkillLibraryError.invalidStoredValue }
            names = Set(decoded)
        } else { names = [] }
        let enabled = try Int.fetchOne(db, sql: "SELECT value_integer FROM app_config WHERE key = ?",
                                       arguments: [AppConfigKey.skillsChatToolsEnabled.rawValue])
        return (names, enabled.map { $0 != 0 } ?? true)
    }

}
