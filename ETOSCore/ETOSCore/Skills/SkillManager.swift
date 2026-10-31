// ============================================================================
// SkillManager.swift
// ============================================================================
// Agent Skills 管理器
// - 负责技能列表与启用状态
// - 负责聊天工具暴露与执行
// - 提供 GitHub 导入入口
// ============================================================================

import Foundation
import Combine
import os.log

@MainActor
public final class SkillManager: ObservableObject {
    private static var sharedInstance: SkillManager?
    private static var preparationTask: Task<SkillLibraryState, Never>?
    public static var shared: SkillManager {
        if let sharedInstance { return sharedInstance }
        let manager = SkillManager(state: SkillLibraryState.loadInitial())
        sharedInstance = manager
        return manager
    }
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则技能列表与开关状态不会稳定刷新。

    public nonisolated static let chatToolName = "use_skill"

    private enum DefaultsKey {
        static let enabledSkillNames = "skills.enabledNames"
        static let chatToolsEnabled = "skills.chatToolsEnabled"
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "SkillManager")
    private let defaults: UserDefaults
    let libraryWorker = SkillLibraryWorker()
    private var libraryRevision: UInt64 = 0

    @Published public private(set) var skills: [SkillMetadata] = []
    @Published public private(set) var enabledSkillNames: Set<String>
    @Published public private(set) var chatToolsEnabled: Bool
    @Published public private(set) var lastErrorMessage: String?

    private init(state: SkillLibraryState) {
        defaults = .standard
        skills = state.skills
        enabledSkillNames = state.enabledNames
        chatToolsEnabled = state.chatToolsEnabled
    }

    /// 桌面启动在创建聊天服务前预热，避免第一次观察共享管理器时扫描技能目录。
    public static func prepareSharedInBackground() async -> SkillManager {
        if let sharedInstance { return sharedInstance }
        // 多个桌面入口同时启动时只安装、扫描一次，避免内置技能目录的并发替换。
        let task: Task<SkillLibraryState, Never>
        if let preparationTask { task = preparationTask }
        else {
            task = Task.detached(priority: .utility) { SkillLibraryState.loadInitial() }
            preparationTask = task
        }
        let state = await task.value
        preparationTask = nil
        if let sharedInstance { return sharedInstance }
        let manager = SkillManager(state: state)
        sharedInstance = manager
        return manager
    }

    func applyLibraryState(_ state: SkillLibraryState) {
        guard state.revision > libraryRevision else { return }
        libraryRevision = state.revision
        skills = state.skills
        enabledSkillNames = state.enabledNames
        chatToolsEnabled = state.chatToolsEnabled
    }

    func invalidateLibraryAfterReadFailure() {
        // 恢复数据库后读不到新状态时，不允许聊天沿用恢复前的技能与授权入口。
        skills = []; enabledSkillNames = []; chatToolsEnabled = false
    }

    public func reloadFromDisk() {
        skills = SkillStore.listSkills()
        pruneMissingEnabledSkills()
    }

    public func executionPolicyStatus(skillName: String) async -> SkillExecutionPolicyStatus {
        let metadata = skills.first { $0.name == skillName }
        return await Task.detached(priority: .utility) {
            let record = Persistence.skillExecutionPolicy(skillName: skillName)
            let digest = metadata.flatMap { try? SkillRunSnapshotBuilder.build(skill: $0).versionDigest }
            return SkillExecutionPolicyStatus(record: record, currentVersionDigest: digest)
        }.value
    }

    @discardableResult
    public func setExecutionPolicy(
        _ policy: SkillExecutionPolicy,
        skillName: String
    ) async -> Bool {
        guard let metadata = skills.first(where: { $0.name == skillName }) else { return false }
        let record = await Task.detached(priority: .utility) {
            let digest: String?
            if policy == .allowCurrentVersion {
                digest = try? SkillRunSnapshotBuilder.build(skill: metadata).versionDigest
            } else {
                digest = nil
            }
            return SkillExecutionPolicyRecord(
                skillName: skillName,
                policy: policy,
                approvedVersionDigest: digest
            )
        }.value
        guard policy != .allowCurrentVersion || record.approvedVersionDigest != nil else {
            lastErrorMessage = NSLocalizedString("无法读取当前 Skill 版本，未保存执行授权。", comment: "Cannot approve unreadable Skill version")
            return false
        }
        let saved = await Task.detached(priority: .utility) {
            Persistence.saveSkillExecutionPolicy(record)
        }.value
        if !saved {
            lastErrorMessage = NSLocalizedString("保存 Skill 执行策略失败。", comment: "Save Skill execution policy failure")
        }
        return saved
    }

    // MARK: - Private

    private func pruneMissingEnabledSkills() {
        let existingNames = Set(skills.map(\.name))
        let filtered = enabledSkillNames.filter { existingNames.contains($0) }
        if filtered != enabledSkillNames {
            enabledSkillNames = filtered
            persistEnabledSkillNames()
        }
    }

    private func persistEnabledSkillNames() {
        Self.save(enabledSkillNames.sorted(), forKey: DefaultsKey.enabledSkillNames, defaults: defaults)
    }

    private static func usesDatabase(defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    private static func save(_ value: [String], forKey key: String, defaults: UserDefaults) {
        if key == DefaultsKey.enabledSkillNames, usesDatabase(defaults: defaults) {
            AppConfigStore.persistStringArray(value, for: .skillsEnabledNames)
            return
        }
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        guard let encoded = encodeStringArray(value) else { return }
        Persistence.writeAppConfig(key: key, text: encoded, typeHint: "text")
    }

    private static func encodeStringArray(_ value: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

}
