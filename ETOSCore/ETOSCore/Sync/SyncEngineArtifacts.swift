// ============================================================================
// SyncEngineArtifacts.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步包中的反馈、每日脉冲与 AppStorage 合并逻辑。
// ============================================================================

import Foundation

extension SyncEngine {
    // MARK: - Feedback Tickets

    static func mergeFeedbackTickets(_ incoming: [FeedbackTicket]) -> (imported: Int, skipped: Int) {
        FeedbackStore.mergeTickets(incoming)
    }

    // MARK: - Daily Pulse

    static func mergeDailyPulseArtifacts(
        runs incomingRuns: [DailyPulseRun],
        feedbackHistory incomingHistory: [DailyPulseFeedbackEvent],
        pendingCuration incomingCuration: DailyPulseCurationNote?,
        externalSignals incomingSignals: [DailyPulseExternalSignal],
        tasks incomingTasks: [DailyPulseTask]
    ) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0

        var localRuns = Persistence.loadDailyPulseRuns()
        if incomingRuns.isEmpty {
            if localRuns.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseRuns([])
                imported += 1
            }
        } else {
            for run in incomingRuns.sorted(by: { $0.generatedAt < $1.generatedAt }) {
                if let existingIndex = localRuns.firstIndex(where: { $0.dayKey == run.dayKey }) {
                    let merged = Self.mergeRun(local: localRuns[existingIndex], incoming: run)
                    if merged == localRuns[existingIndex] {
                        skipped += 1
                        continue
                    }
                    localRuns[existingIndex] = merged
                    imported += 1
                    continue
                }

                localRuns.append(run)
                imported += 1
            }
            let trimmedRuns = Self.trimmedRuns(
                localRuns,
                limit: Self.dailyPulseRunRetentionLimit
            )
            Persistence.saveDailyPulseRuns(trimmedRuns)
        }

        if incomingHistory.isEmpty {
            let localHistory = Persistence.loadDailyPulseFeedbackHistory()
            if localHistory.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseFeedbackHistory([])
                imported += 1
            }
        } else {
            var localHistory = Persistence.loadDailyPulseFeedbackHistory()
            let original = localHistory
            for event in incomingHistory.sorted(by: { $0.createdAt < $1.createdAt }) {
                localHistory = Self.appendingFeedbackEvent(
                    event,
                    to: localHistory,
                    limit: Self.dailyPulseFeedbackRetentionLimit
                )
            }
            Persistence.saveDailyPulseFeedbackHistory(localHistory)
            if localHistory == original {
                skipped += incomingHistory.count
            } else {
                imported += max(1, localHistory.count - original.count)
            }
        }

        let localCuration = Persistence.loadDailyPulsePendingCuration()
        if localCuration != nil || incomingCuration != nil {
            if localCuration == incomingCuration {
                skipped += 1
            } else if let incomingCuration {
                let shouldReplace = localCuration == nil
                    || incomingCuration.createdAt >= (localCuration?.createdAt ?? .distantPast)
                if shouldReplace {
                    Persistence.saveDailyPulsePendingCuration(incomingCuration)
                    imported += 1
                } else {
                    skipped += 1
                }
            } else {
                Persistence.saveDailyPulsePendingCuration(nil)
                imported += 1
            }
        }

        if incomingSignals.isEmpty {
            let localSignals = Persistence.loadDailyPulseExternalSignals()
            if localSignals.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseExternalSignals([])
                imported += 1
            }
        } else {
            var localSignals = Persistence.loadDailyPulseExternalSignals()
            let original = localSignals
            for signal in incomingSignals.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                localSignals = Self.appendingExternalSignal(
                    signal,
                    to: localSignals,
                    limit: Self.dailyPulseSignalRetentionLimit
                )
            }
            Persistence.saveDailyPulseExternalSignals(localSignals)
            if localSignals == original {
                skipped += incomingSignals.count
            } else {
                imported += max(1, localSignals.count - original.count)
            }
        }

        if incomingTasks.isEmpty {
            let localTasks = Persistence.loadDailyPulseTasks()
            if localTasks.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseTasks([])
                imported += 1
            }
        } else {
            var localTasks = Persistence.loadDailyPulseTasks()
            let original = localTasks
            for task in incomingTasks {
                if let existingIndex = localTasks.firstIndex(where: { existing in
                    if existing.id == task.id {
                        return true
                    }
                    if let localCardID = existing.sourceCardID, let incomingCardID = task.sourceCardID {
                        return localCardID == incomingCardID && existing.sourceDayKey == task.sourceDayKey
                    }
                    return false
                }) {
                    let merged = Self.mergeTask(local: localTasks[existingIndex], incoming: task)
                    if merged == localTasks[existingIndex] {
                        skipped += 1
                    } else {
                        localTasks[existingIndex] = merged
                        imported += 1
                    }
                } else {
                    localTasks.append(task)
                    imported += 1
                }
            }
            let sortedTasks = Self.sortedTasks(localTasks)
            Persistence.saveDailyPulseTasks(sortedTasks)
            if sortedTasks == original {
                skipped += incomingTasks.count
            }
        }

        return (imported, skipped)
    }

    nonisolated static let dailyPulseRunRetentionLimit = 14
    nonisolated static let dailyPulseFeedbackRetentionLimit = 120
    nonisolated static let dailyPulseSignalRetentionLimit = 40
    nonisolated static let taskRetentionLimit = 80

    internal nonisolated static func trimmedRuns(_ runs: [DailyPulseRun], limit: Int) -> [DailyPulseRun] {
        runs.sorted(by: { $0.generatedAt > $1.generatedAt }).prefix(max(1, limit)).map { $0 }
    }

    internal nonisolated static func sortedTasks(_ tasks: [DailyPulseTask]) -> [DailyPulseTask] {
        tasks
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted && rhs.isCompleted
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(Self.taskRetentionLimit)
            .map { $0 }
    }

    internal nonisolated static func trimmedExternalSignals(_ signals: [DailyPulseExternalSignal], limit: Int) -> [DailyPulseExternalSignal] {
        signals
            .sorted(by: { $0.capturedAt > $1.capturedAt })
            .prefix(max(1, limit))
            .map { $0 }
    }

    internal nonisolated static func mergeRun(local: DailyPulseRun, incoming: DailyPulseRun) -> DailyPulseRun {
        let base = incoming.generatedAt >= local.generatedAt ? incoming : local
        let secondary = incoming.generatedAt >= local.generatedAt ? local : incoming

        let mergedCards = base.cards.map { baseCard in
            guard let matchingSecondary = secondary.cards.first(where: {
                areTopicsSimilar($0.title, baseCard.title) ||
                areTopicsSimilar(topicText(for: $0), topicText(for: baseCard))
            }) else {
                return baseCard
            }

            var merged = baseCard
            merged.feedback = mergedFeedback(base: baseCard.feedback, incoming: matchingSecondary.feedback)
            if merged.savedSessionID == nil {
                merged.savedSessionID = matchingSecondary.savedSessionID
            }
            return merged
        }

        return DailyPulseRun(
            id: base.id,
            dayKey: base.dayKey,
            generatedAt: max(base.generatedAt, secondary.generatedAt),
            headline: base.headline,
            cards: mergedCards,
            sourceDigest: base.sourceDigest
        )
    }

    internal nonisolated static func appendingFeedbackEvent(
        _ event: DailyPulseFeedbackEvent,
        to history: [DailyPulseFeedbackEvent],
        limit: Int
    ) -> [DailyPulseFeedbackEvent] {
        var updated = history
        if let existingIndex = updated.firstIndex(where: {
            $0.dayKey == event.dayKey
                && areTopicsSimilar($0.topicHint, event.topicHint)
                && $0.action == event.action
        }) {
            updated[existingIndex] = event
        } else {
            updated.insert(event, at: 0)
        }

        return Array(
            updated
                .sorted(by: { $0.createdAt > $1.createdAt })
                .prefix(max(1, limit))
        )
    }

    internal nonisolated static func appendingExternalSignal(
        _ signal: DailyPulseExternalSignal,
        to history: [DailyPulseExternalSignal],
        limit: Int
    ) -> [DailyPulseExternalSignal] {
        var updated = history
        if let existingIndex = updated.firstIndex(where: {
            $0.source == signal.source
                && areTopicsSimilar($0.title, signal.title)
        }) {
            if signal.capturedAt >= updated[existingIndex].capturedAt {
                updated[existingIndex] = signal
            }
        } else {
            updated.insert(signal, at: 0)
        }

        return trimmedExternalSignals(updated, limit: limit)
    }

    internal nonisolated static func mergeTask(local: DailyPulseTask, incoming: DailyPulseTask) -> DailyPulseTask {
        let base = incoming.updatedAt >= local.updatedAt ? incoming : local
        let secondary = incoming.updatedAt >= local.updatedAt ? local : incoming

        var merged = base
        if merged.completedAt == nil {
            merged.completedAt = secondary.completedAt
        }
        if merged.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.details = secondary.details
        }
        if merged.suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.suggestedPrompt = secondary.suggestedPrompt
        }
        return merged
    }

    private nonisolated static func mergedFeedback(base: DailyPulseCardFeedback, incoming: DailyPulseCardFeedback) -> DailyPulseCardFeedback {
        let priority: [DailyPulseCardFeedback: Int] = [
            .none: 0,
            .liked: 1,
            .disliked: 2,
            .hidden: 3
        ]
        return (priority[incoming] ?? 0) > (priority[base] ?? 0) ? incoming : base
    }

    internal nonisolated static func topicText(for card: DailyPulseCard) -> String {
        "\(card.title) \(card.summary)"
    }

    internal nonisolated static func areTopicsSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = topicFingerprint(lhs)
        let right = topicFingerprint(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right || left.contains(right) || right.contains(left) {
            return true
        }

        let leftSet = Set(left)
        let rightSet = Set(right)
        guard !leftSet.isEmpty, !rightSet.isEmpty else { return false }
        let overlap = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        guard union > 0 else { return false }
        return Double(overlap) / Double(union) >= 0.72
    }

    internal nonisolated static func topicFingerprint(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
        let filteredScalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar)
        }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        return String(filtered.prefix(48))
    }

    private nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    // MARK: - AppStorage

    static func mergeAppStorage(
        _ snapshotData: Data?,
        userDefaults: UserDefaults
    ) async -> (imported: Int, skipped: Int) {
        var incomingSnapshot: [String: Any] = [:]

        if let snapshotData, let decoded = decodeAppStorageSnapshot(snapshotData) {
            incomingSnapshot = decoded
        } else {
            return (0, 1)
        }

        guard !incomingSnapshot.isEmpty else {
            return (0, 0)
        }

        let normalized = normalizedAppConfigSnapshot(incomingSnapshot)
        let currentSnapshot = collectAppStorageSnapshot(userDefaults: userDefaults)
        var imported = 0
        var skipped = normalized.skipped
        var acceptedSnapshot: [String: Any] = [:]

        for (key, incomingValue) in normalized.snapshot {
            let localValue = currentSnapshot[key]
            if appStorageValuesEqual(localValue, incomingValue) {
                skipped += 1
                continue
            }

            acceptedSnapshot[key] = incomingValue
            imported += 1
        }

        if !acceptedSnapshot.isEmpty {
            await AppConfigStore.shared.apply(snapshot: acceptedSnapshot)
            await reloadAppConfigBackedManagersIfNeeded(changedKeys: Set(acceptedSnapshot.keys))
        }

        return (imported, skipped)
    }

    @MainActor
    private static func reloadAppConfigBackedManagersIfNeeded(changedKeys: Set<String>) {
        if changedKeys.contains(AppConfigKey.appToolsChatToolsEnabled.rawValue)
            || changedKeys.contains(AppConfigKey.appToolsEnabledToolIDs.rawValue)
            || changedKeys.contains(AppConfigKey.appToolsToolApprovalPolicies.rawValue) {
            AppToolManager.shared.reloadAppConfigBackedState()
        }
        if changedKeys.contains(AppConfigKey.shortcutChatToolsEnabled.rawValue) {
            ShortcutToolManager.shared.reloadAppConfigBackedState()
        }
        if changedKeys.contains(AppConfigKey.modelOrderRunnableModels.rawValue)
            || changedKeys.contains(AppConfigKey.providerOrderIDs.rawValue)
            || changedKeys.contains(AppConfigKey.selectedRunnableModelID.rawValue) {
            ChatService.shared.reloadAppConfigBackedModelState()
        }
        if changedKeys.contains(AppConfigKey.messageRegexRules.rawValue) {
            MessageRegexRuleStore.shared.reload(notify: true)
        }
        if changedKeys.contains(AppConfigKey.customChatSlashCommands.rawValue) {
            CustomChatSlashCommandStore.shared.reload(notify: true)
        }
    }

    static func encodeAppStorageSnapshot(_ snapshot: [String: Any]) -> Data? {
        guard PropertyListSerialization.propertyList(snapshot, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    static func decodeAppStorageSnapshot(_ data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func collectAppStorageSnapshot(userDefaults _: UserDefaults) -> [String: Any] {
        AppConfigStore.persistentSnapshot()
            .filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
    }

    static func defaultSynchronizedAppStorageSnapshot() -> Data? {
        let defaults = AppConfigKey.allCases.reduce(into: [String: Any]()) { result, key in
            guard key.participatesInSync,
                  isCandidateAppStorageKey(key.rawValue),
                  isPropertyListEncodableValue(key.defaultValue.anyValue) else {
                return
            }
            result[key.rawValue] = key.defaultValue.anyValue
        }
        return encodeAppStorageSnapshot(defaults)
    }

    static func normalizedAppConfigSnapshot(
        _ snapshot: [String: Any]
    ) -> (snapshot: [String: Any], skipped: Int) {
        var normalizedSnapshot: [String: Any] = [:]
        var skipped = 0
        for (rawKey, value) in snapshot {
            guard isCandidateAppStorageKey(rawKey),
                  let key = AppConfigKey(rawValue: rawKey),
                  key.participatesInSync,
                  let normalizedValue = normalizedAppConfigValue(value, for: key),
                  isPropertyListEncodableValue(normalizedValue) else {
                skipped += 1
                continue
            }
            normalizedSnapshot[rawKey] = normalizedValue
        }
        return (normalizedSnapshot, skipped)
    }

    static func normalizedAppConfigValue(_ value: Any, for key: AppConfigKey) -> Any? {
        switch key.defaultValue {
        case .bool:
            if let value = value as? Bool {
                return value
            }
            if let value = value as? NSNumber {
                return value.boolValue
            }
            if let value = value as? String {
                switch value.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    return nil
                }
            }
            return nil
        case .integer:
            if let value = value as? Int {
                return value
            }
            if let value = value as? NSNumber {
                return value.intValue
            }
            if let value = value as? String {
                return Int(value)
            }
            return nil
        case .real:
            if let value = value as? Double {
                return value
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            if let value = value as? String {
                return Double(value)
            }
            return nil
        case .text:
            if let value = value as? String {
                return value
            }
            if let value = value as? NSString {
                return value as String
            }
            return nil
        }
    }

    static func isPropertyListEncodableValue(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(["value": value], isValidFor: .binary)
    }

    static func isCandidateAppStorageKey(_ key: String) -> Bool {
        if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") {
            return false
        }
        if appStorageExcludedExactKeys.contains(key) {
            return false
        }
        if appStorageExcludedPrefixes.contains(where: { key.hasPrefix($0) }) {
            return false
        }
        return true
    }

    static func appStorageValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        default:
            break
        }

        if let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject {
            return lhsObject.isEqual(rhsObject)
        }

        return String(describing: lhs) == String(describing: rhs)
    }
}
