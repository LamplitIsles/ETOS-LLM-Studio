// ============================================================================
// OpenAIResponsesLocalShellRuntime.swift
// ETOS LLM Studio
//
// 为 OpenAI Responses 原生 local shell 物化冻结的 Skill 包。移动端持有只读
// 挂载并仅公开 guest 路径；macOS 直接提供本次冻结副本的本机路径。
// ============================================================================

import Foundation

enum OpenAIResponsesLocalShellProtocol {
    static let toolName = "openai_responses_local_shell"
    static let skillsField = "openai_responses_local_shell_skills"
}

public actor OpenAIResponsesLocalShellRuntime {
    public static let shared = OpenAIResponsesLocalShellRuntime()

    private struct MountedSkill: Sendable {
        let snapshot: SkillRunSnapshot
        let guestPath: String
    }

    private struct RunEnvironment {
        let skills: [MountedSkill]
    }

    private let packageStore: SkillExecutionPackageStore
    private var environments: [UUID: RunEnvironment] = [:]

    public init(
        packageStore: SkillExecutionPackageStore = .shared
    ) {
        self.packageStore = packageStore
    }

    public func toolDefinition(for context: AgentRuntimeContext) async throws -> InternalToolDefinition {
        let activity = try LocalLinuxActivityBarrier.shared.begin()
        defer { activity.finish() }
        guard let runID = context.runID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 缺少运行标识。", comment: "Missing local Agent run identifier")
            )
        }
        let environment: RunEnvironment
        if let existing = environments[runID] {
            environment = existing
        } else {
            environment = try await prepareEnvironment(context: context)
            try activity.checkCancellation()
            environments[runID] = environment
        }

        let skills: [JSONValue] = environment.skills.map { mounted in
            let trimmedDescription = mounted.snapshot.skillDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = trimmedDescription.flatMap { $0.isEmpty ? nil : $0 }
                ?? mounted.snapshot.skillName
            return .dictionary([
                "name": .string(mounted.snapshot.skillName),
                "description": .string(description),
                "path": .string(mounted.guestPath)
            ])
        }
        #if os(macOS)
        let description = NSLocalizedString("mac.shell.tool.run", comment: "Mac 本机 Shell 工具")
        #else
        let description = NSLocalizedString(
                "在 ETOS 隔离的本地 Linux 用户态中执行 OpenAI Responses 原生 Shell 调用。",
                comment: "OpenAI Responses local shell internal tool description"
            )
        #endif
        return InternalToolDefinition(
            name: OpenAIResponsesLocalShellProtocol.toolName,
            description: description,
            parameters: .dictionary([:]),
            isBlocking: true,
            kind: .openAIResponsesLocalShell,
            providerSpecificFields: [
                OpenAIResponsesLocalShellProtocol.skillsField: .array(skills)
            ]
        )
    }

    public func activateReferencedSkills(argumentsJSON: String, runID: UUID) async {
        guard let environment = environments[runID] else { return }
        for mounted in environment.skills where argumentsJSON.contains(mounted.guestPath) {
            await SkillAllowedToolRuntime.shared.activate(skill: mounted.snapshot, runID: runID)
        }
    }

    public func finishRun(id: UUID) {
        environments.removeValue(forKey: id)
    }

    #if os(macOS)
    private func prepareEnvironment(context: AgentRuntimeContext) async throws -> RunEnvironment {
        var mountedSkills: [MountedSkill] = []
        for snapshot in (context.skillSnapshots ?? []).sorted(by: { $0.skillName < $1.skillName }) {
            let package = try await packageStore.materialize(
                skillName: snapshot.skillName,
                frozenSnapshot: snapshot
            )
            mountedSkills.append(MountedSkill(snapshot: snapshot, guestPath: package.path))
        }
        return RunEnvironment(skills: mountedSkills)
    }
    #endif
}
