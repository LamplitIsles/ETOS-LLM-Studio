// ============================================================================
// AppToolAskUserInput.swift
// ============================================================================
// ETOS LLM Studio
//
// 共享问答值类型与答案策略，供设备消息 Survey 使用。
// ============================================================================

import Foundation

public enum AppToolAskUserInputQuestionType: String, Codable, Hashable, Sendable {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
}

public enum AppToolAskUserInputAnswerPolicy {
    public static func normalizedCustomText(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func hasAnswer(selectedOptionIDs: Set<String>, customText: String?) -> Bool {
        !selectedOptionIDs.isEmpty || normalizedCustomText(customText) != nil
    }

    public static func canSelectOption(type: AppToolAskUserInputQuestionType, customText: String?) -> Bool {
        switch type {
        case .singleSelect:
            return normalizedCustomText(customText) == nil
        case .multiSelect:
            return true
        }
    }

    public static func shouldClearSelectedOptionsAfterTypingCustomText(
        type: AppToolAskUserInputQuestionType,
        customText: String?
    ) -> Bool {
        type == .singleSelect && normalizedCustomText(customText) != nil
    }
}

public struct AppToolAskUserInputOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct AppToolAskUserInputQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let options: [AppToolAskUserInputOption]
    public let allowOther: Bool
    public let required: Bool

    public init(
        id: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        options: [AppToolAskUserInputOption],
        allowOther: Bool,
        required: Bool
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.options = options
        self.allowOther = allowOther
        self.required = required
    }
}

public struct AppToolAskUserInputRequest: Codable, Identifiable, Equatable, Sendable {
    public let requestID: String
    public let title: String?
    public let description: String?
    public let submitLabel: String
    public let questions: [AppToolAskUserInputQuestion]

    public init(
        requestID: String,
        title: String?,
        description: String?,
        submitLabel: String,
        questions: [AppToolAskUserInputQuestion]
    ) {
        self.requestID = requestID
        self.title = title
        self.description = description
        self.submitLabel = submitLabel
        self.questions = questions
    }

    public var id: String { requestID }
}

public struct AppToolAskUserInputQuestionAnswer: Codable, Equatable, Sendable {
    public let questionID: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let selectedOptionIDs: [String]
    public let selectedOptionLabels: [String]
    public let otherText: String?

    public init(
        questionID: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        selectedOptionIDs: [String],
        selectedOptionLabels: [String],
        otherText: String?
    ) {
        self.questionID = questionID
        self.question = question
        self.type = type
        self.selectedOptionIDs = selectedOptionIDs
        self.selectedOptionLabels = selectedOptionLabels
        self.otherText = otherText
    }
}
