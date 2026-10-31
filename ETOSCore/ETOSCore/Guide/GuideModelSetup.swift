// ============================================================================
// GuideModelSetup.swift
// ============================================================================
// ETOS LLM Studio
//
// 首次模型配置的状态与输入校验。
// ============================================================================

import Foundation
import Combine

public enum GuideModelSetupChoice: String, CaseIterable, Identifiable, Sendable {
    case cloud
    case custom
    case local
    case importConfiguration

    public var id: String { rawValue }
}

public struct GuideProviderTemplate: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let apiFormat: String

    public init(id: String, name: String, baseURL: String, apiFormat: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiFormat = apiFormat
    }

    public static let cloudTemplates = [
        GuideProviderTemplate(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            apiFormat: "openai-compatible"
        ),
        GuideProviderTemplate(
            id: "anthropic",
            name: "Anthropic",
            baseURL: "https://api.anthropic.com/v1",
            apiFormat: "anthropic"
        ),
        GuideProviderTemplate(
            id: "gemini",
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiFormat: "gemini"
        )
    ]
}

public enum GuideModelSetupStateResolver {
    public static func resolve(
        providers: [Provider],
        selectedModel: RunnableModel?
    ) -> GuideModelSetupState {
        guard !providers.isEmpty else { return .needsProvider }

        let remoteHasCredentials = providers.contains { !$0.apiKeys.isEmpty }
        if !remoteHasCredentials {
            return .needsCredential
        }

        let chatModels = providers.flatMap { provider in
            provider.models.filter(\.isChatModel).map { RunnableModel(provider: provider, model: $0) }
        }
        guard !chatModels.isEmpty else { return .needsModel }

        let activated = chatModels.filter { $0.model.isActivated }
        guard !activated.isEmpty,
              let selectedModel,
              activated.contains(where: { $0.id == selectedModel.id }) else {
            return .needsActivationOrSelection
        }
        return .ready
    }

    public static func resolve(chatService: ChatService = .shared) -> GuideModelSetupState {
        resolve(
            providers: chatService.providersSubject.value,
            selectedModel: chatService.selectedModelSubject.value
        )
    }
}

public enum GuideModelSetupValidation {
    public static func isValidRemoteBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return false
        }
        return ["http", "https"].contains(components.scheme?.lowercased() ?? "")
            && !(components.host ?? "").isEmpty
    }
}
