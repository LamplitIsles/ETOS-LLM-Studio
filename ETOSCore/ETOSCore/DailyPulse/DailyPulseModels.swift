// ============================================================================
// DailyPulseModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲的公开模型、内部生成输入与外部上下文结构定义。
// ============================================================================

import Foundation

public enum DailyPulseCardFeedback: String, Codable, Hashable, Sendable {
    case none
    case liked
    case disliked
    case hidden
}

public enum DailyPulseTrigger: String, Codable, Hashable, Sendable {
    case automatic
    case manual
    case delivery
}

public enum DailyPulseHistoryAction: String, Codable, Hashable, Sendable {
    case liked
    case disliked
    case hidden
    case saved
}

public struct DailyPulseFeedbackEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var dayKey: String
    public var topicHint: String
    public var cardTitle: String
    public var action: DailyPulseHistoryAction

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        dayKey: String,
        topicHint: String,
        cardTitle: String,
        action: DailyPulseHistoryAction
    ) {
        self.id = id
        self.createdAt = createdAt
        self.dayKey = dayKey
        self.topicHint = topicHint
        self.cardTitle = cardTitle
        self.action = action
    }
}

public struct DailyPulseCurationNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var targetDayKey: String
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        targetDayKey: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetDayKey = targetDayKey
        self.text = text
        self.createdAt = createdAt
    }
}

public enum DailyPulseExternalSignalSource: String, Codable, Hashable, Sendable {
    case shortcutResult
    case mcpOutput
    case mcpError
    case announcement
}

public struct DailyPulseExternalSignal: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: DailyPulseExternalSignalSource
    public var title: String
    public var preview: String
    public var capturedAt: Date
    public var isFailure: Bool

    public init(
        id: UUID = UUID(),
        source: DailyPulseExternalSignalSource,
        title: String,
        preview: String,
        capturedAt: Date = Date(),
        isFailure: Bool = false
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.preview = preview
        self.capturedAt = capturedAt
        self.isFailure = isFailure
    }
}

public struct DailyPulseTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceDayKey: String
    public var sourceCardID: UUID?
    public var title: String
    public var details: String
    public var suggestedPrompt: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceDayKey: String,
        sourceCardID: UUID?,
        title: String,
        details: String,
        suggestedPrompt: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceDayKey = sourceDayKey
        self.sourceCardID = sourceCardID
        self.title = title
        self.details = details
        self.suggestedPrompt = suggestedPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public var isCompleted: Bool {
        completedAt != nil
    }
}

public struct DailyPulseCard: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var whyRecommended: String
    public var summary: String
    public var detailsMarkdown: String
    public var suggestedPrompt: String
    public var feedback: DailyPulseCardFeedback
    public var savedSessionID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        whyRecommended: String,
        summary: String,
        detailsMarkdown: String,
        suggestedPrompt: String,
        feedback: DailyPulseCardFeedback = .none,
        savedSessionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.whyRecommended = whyRecommended
        self.summary = summary
        self.detailsMarkdown = detailsMarkdown
        self.suggestedPrompt = suggestedPrompt
        self.feedback = feedback
        self.savedSessionID = savedSessionID
    }

    public var isVisible: Bool {
        feedback != .hidden
    }
}

public struct DailyPulseRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var dayKey: String
    public var generatedAt: Date
    public var headline: String
    public var cards: [DailyPulseCard]
    public var sourceDigest: String
    public var deliveryBatches: [DailyPulseDeliveryBatch]?

    public init(
        id: UUID = UUID(),
        dayKey: String,
        generatedAt: Date,
        headline: String,
        cards: [DailyPulseCard],
        sourceDigest: String,
        deliveryBatches: [DailyPulseDeliveryBatch]? = nil
    ) {
        self.id = id
        self.dayKey = dayKey
        self.generatedAt = generatedAt
        self.headline = headline
        self.cards = cards
        self.sourceDigest = sourceDigest
        self.deliveryBatches = deliveryBatches
    }

    public var visibleCards: [DailyPulseCard] {
        cards.filter(\.isVisible)
    }
}

public struct DailyPulseDeliveryBatch: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var deliveryTimeID: UUID
    public var scheduledAt: Date
    public var headline: String
    public var cardIDs: [UUID]

    public init(
        id: UUID = UUID(),
        deliveryTimeID: UUID,
        scheduledAt: Date,
        headline: String,
        cardIDs: [UUID]
    ) {
        self.id = id
        self.deliveryTimeID = deliveryTimeID
        self.scheduledAt = scheduledAt
        self.headline = headline
        self.cardIDs = cardIDs
    }
}

struct DailyPulseGenerationCheckpoint: Codable, Hashable, Sendable {
    var dayKey: String
    var scheduleSignature: String
    var sourceDigest: String
    var generatedCards: [DailyPulseCard]
    var deliveryBatches: [DailyPulseDeliveryBatch]
    var firstHeadline: String?
    var startedAt: Date
    var updatedAt: Date

    init(
        dayKey: String,
        scheduleSignature: String,
        sourceDigest: String,
        generatedCards: [DailyPulseCard] = [],
        deliveryBatches: [DailyPulseDeliveryBatch] = [],
        firstHeadline: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.dayKey = dayKey
        self.scheduleSignature = scheduleSignature
        self.sourceDigest = sourceDigest
        self.generatedCards = generatedCards
        self.deliveryBatches = deliveryBatches
        self.firstHeadline = firstHeadline
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    func hasCompletedDeliveryGroup(_ deliveryTimes: [DailyPulseDeliveryTime]) -> Bool {
        let cardIDs = Set(generatedCards.map(\.id))
        var referencedCardIDs = Set<UUID>()
        for deliveryTime in deliveryTimes {
            guard let batch = deliveryBatches.first(where: { $0.deliveryTimeID == deliveryTime.id }),
                  batch.cardIDs.count == 1,
                  let cardID = batch.cardIDs.first else {
                return false
            }
            guard cardIDs.contains(cardID), referencedCardIDs.insert(cardID).inserted else {
                return false
            }
        }
        return true
    }
}

struct DailyPulseGenerationAttempt: Codable, Hashable, Sendable {
    var dayKey: String
    var lastAttemptAt: Date
    var retryAfter: Date
    var consecutiveFailureCount: Int
}

struct DailyPulseGenerationRuntimeState: Codable, Hashable, Sendable {
    var checkpoints: [DailyPulseGenerationCheckpoint]
    var attempts: [DailyPulseGenerationAttempt]

    static let empty = DailyPulseGenerationRuntimeState(checkpoints: [], attempts: [])
}

public enum DailyPulseGenerationError: LocalizedError {
    case noModelSelected
    case insufficientContext
    case invalidModelOutput

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return NSLocalizedString("每日脉冲生成失败：当前没有可用的聊天模型。", comment: "Daily pulse error when no model is available")
        case .insufficientContext:
            return NSLocalizedString("每日脉冲暂时无法生成：当前可用的聊天、记忆、明日策展或外部上下文还不够。", comment: "Daily pulse error when not enough context is available")
        case .invalidModelOutput:
            return NSLocalizedString("每日脉冲生成失败：模型返回内容无法解析。", comment: "Daily pulse error when model output is invalid")
        }
    }
}
