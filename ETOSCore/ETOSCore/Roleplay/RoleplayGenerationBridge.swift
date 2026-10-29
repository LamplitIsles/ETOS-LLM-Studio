// ============================================================================
// RoleplayGenerationBridge.swift
// ============================================================================
// ETOS LLM Studio
//
// 将酒馆助手 generate/generateRaw 配置转换为不落盘的原生模型请求。
// ============================================================================

import Foundation

extension ChatService {
    public func generateRoleplayCompletion(
        config: JSONValue,
        raw: Bool,
        sessionID: UUID,
        store: RoleplayStore = .shared
    ) async throws -> String {
        try Task.checkCancellation()
        let dictionary = config.roleplayDictionary ?? [:]
        let allMessages = messagesSnapshot(for: sessionID)
        guard var resolved = RoleplayRuntime.resolve(sessionID: sessionID, messages: allMessages, store: store) else {
            let fallback = dictionary["user_input"]?.roleplayString ?? ""
            return try await generateDetachedChatCompletion(
                userPrompt: fallback,
                temperature: dictionary.roleplayTemperature,
                requestSource: .chat,
                sessionID: sessionID
            )
        }

        let historyLimit = dictionary["max_chat_history"]?.roleplayInteger
        let history: [ChatMessage]
        if let historyLimit, historyLimit >= 0 {
            history = Array(allMessages.suffix(historyLimit))
        } else {
            history = allMessages
        }
        let transformedHistory = RoleplayRuntime.transformedRequestMessages(history, resolved: &resolved)
        if resolved.variables != store.variableSnapshot(sessionID: sessionID) {
            store.saveVariableSnapshot(resolved.variables, sessionID: sessionID)
        }
        let overrides = dictionary["overrides"]?.roleplayDictionary ?? [:]
        var templateMacroContext = resolved.macroContext
        let builtins = await roleplayGenerationBuiltins(
            resolved: resolved,
            history: transformedHistory,
            overrides: overrides,
            sessionID: sessionID,
            macroContext: &templateMacroContext
        )
        try Task.checkCancellation()
        var requestMessages = RoleplayGenerationPromptAssembler.assemble(
            dictionary: dictionary,
            raw: raw,
            systemPrompts: builtins.system,
            chatHistory: builtins.chatHistory
        )
        let scriptIDs = resolved.binding.helperScriptsEnabled
            ? resolved.characters.flatMap { $0.helperScripts.filter(\.enabled).map(\.id) }
            : []
        if !scriptIDs.isEmpty {
            for index in requestMessages.indices where requestMessages[index].content.contains("{{") {
                try Task.checkCancellation()
                requestMessages[index].content = await RoleplayMacroExpansionBridge.shared.expand(
                    requestMessages[index].content,
                    sessionID: sessionID,
                    scriptIDs: scriptIDs
                )
            }
        }
        requestMessages = await RoleplayPromptTemplateRenderer.renderMessages(
            requestMessages,
            chatHistory: transformedHistory,
            macroContext: &templateMacroContext
        )
        try Task.checkCancellation()
        if templateMacroContext.variables != store.variableSnapshot(sessionID: sessionID) {
            store.saveVariableSnapshot(templateMacroContext.variables, sessionID: sessionID)
        }
        if !scriptIDs.isEmpty {
            requestMessages = await RoleplayPromptMutationBridge.shared.mutate(
                requestMessages,
                sessionID: sessionID,
                scriptIDs: scriptIDs
            )
        }
        try Task.checkCancellation()
        return try await generateDetachedChatCompletion(
            messages: requestMessages,
            temperature: dictionary.roleplayTemperature,
            requestSource: .chat,
            sessionID: sessionID
        )
    }

    private func roleplayGenerationBuiltins(
        resolved: ResolvedRoleplaySession,
        history: [ChatMessage],
        overrides: [String: JSONValue],
        sessionID: UUID,
        macroContext: inout RoleplayMacroContext
    ) async -> (system: [String: String], chatHistory: [ChatMessage]) {
        let character = resolved.characters.first
        let macro = macroContext
        func resolvedText(_ raw: String) -> String {
            RoleplayMacroResolver.resolve(raw, context: macro)
        }
        func overridden(_ key: String, fallback: String) -> String {
            overrides[key]?.roleplayString.map(resolvedText) ?? resolvedText(fallback)
        }
        let dialogueExamples = resolvedText(character?.messageExamples ?? "")
        let system: [String: String] = [
            "persona_description": overridden("persona_description", fallback: resolved.persona?.description ?? ""),
            "char_description": overridden("char_description", fallback: character?.description ?? ""),
            "char_personality": overridden("char_personality", fallback: character?.personality ?? ""),
            "scenario": overridden("scenario", fallback: character?.scenario ?? ""),
            "dialogue_examples": overridden("dialogue_examples", fallback: dialogueExamples)
        ]
        let chatOverride = overrides["chat_history"]?.roleplayDictionary ?? [:]
        var generationHistory = history.map { message in
            var message = message
            message.content = resolvedText(message.content)
            return message
        }
        let authorNote = chatOverride["author_note"]?.roleplayString
            ?? character?.postHistoryInstructions
            ?? ""
        let authorNoteBlock = resolvedText(authorNote)
        if !authorNoteBlock.isEmpty {
            generationHistory.append(ChatMessage(role: .system, content: authorNoteBlock))
        }
        return (system, generationHistory)
    }

}

struct RoleplayGenerationPromptAssembler {
    static func assemble(
        dictionary: [String: JSONValue],
        raw: Bool,
        systemPrompts: [String: String],
        chatHistory: [ChatMessage]
    ) -> [ChatMessage] {
        let defaultOrder = [
            "persona_description", "char_description", "char_personality",
            "scenario", "dialogue_examples", "chat_history", "user_input"
        ]
        let order = dictionary["ordered_prompts"]?.roleplayArray
            ?? dictionary["order"]?.roleplayArray
            ?? defaultOrder.map(JSONValue.string)
        let overrides = dictionary["overrides"]?.roleplayDictionary ?? [:]
        var messages: [ChatMessage] = []
        for item in order {
            if let name = item.roleplayString {
                switch name {
                case "user_input":
                    if let content = dictionary["user_input"]?.roleplayString, !content.isEmpty {
                        messages.append(ChatMessage(role: .user, content: content))
                    }
                case "chat_history":
                    messages.append(contentsOf: overriddenHistory(overrides) ?? chatHistory)
                default:
                    if let content = systemPrompts[name], !content.isEmpty {
                        messages.append(ChatMessage(role: .system, content: content))
                    }
                }
            } else if let prompt = item.roleplayDictionary,
                      let role = messageRole(prompt["role"]?.roleplayString),
                      let content = prompt["content"]?.roleplayString,
                      !content.isEmpty {
                messages.append(ChatMessage(role: role, content: content))
            }
        }
        if !raw, !messages.contains(where: { $0.role == .user }),
           let lastUser = chatHistory.last(where: { $0.role == .user }) {
            messages.append(lastUser)
        }
        applyInjects(dictionary["injects"]?.roleplayArray ?? dictionary["inject"]?.roleplayArray ?? [], to: &messages)
        return messages
    }

    private static func overriddenHistory(_ overrides: [String: JSONValue]) -> [ChatMessage]? {
        let raw = overrides["chat_history"]
        let prompts = raw?.roleplayArray ?? raw?.roleplayDictionary?["prompts"]?.roleplayArray
        guard let prompts else { return nil }
        return prompts.compactMap { item in
            guard let value = item.roleplayDictionary,
                  let role = messageRole(value["role"]?.roleplayString),
                  let content = value["content"]?.roleplayString else { return nil }
            return ChatMessage(role: role, content: content)
        }
    }

    private static func applyInjects(_ injects: [JSONValue], to messages: inout [ChatMessage]) {
        for item in injects {
            guard let value = item.roleplayDictionary,
                  value["position"]?.roleplayString != "none",
                  let role = messageRole(value["role"]?.roleplayString),
                  let content = value["content"]?.roleplayString,
                  !content.isEmpty else { continue }
            let depth = max(0, value["depth"]?.roleplayInteger ?? 0)
            messages.insert(ChatMessage(role: role, content: content), at: max(0, messages.count - depth))
        }
    }

    private static func messageRole(_ raw: String?) -> MessageRole? {
        switch raw?.lowercased() {
        case "system": return .system
        case "assistant", "character": return .assistant
        case "user": return .user
        default: return nil
        }
    }
}

private extension JSONValue {
    var roleplayDictionary: [String: JSONValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    var roleplayArray: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var roleplayString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var roleplayInteger: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var roleplayBoolean: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value):
            if ["true", "1"].contains(value.lowercased()) { return true }
            if ["false", "0"].contains(value.lowercased()) { return false }
            return nil
        default: return nil
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var roleplayTemperature: Double {
        let custom = self["custom_api"]?.roleplayDictionary?["temperature"]
        switch custom {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value) ?? 0.7
        default: return 0.7
        }
    }
}
