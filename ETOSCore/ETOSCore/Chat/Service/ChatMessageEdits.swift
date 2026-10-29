import Foundation

/// Call with the session state lock held. A failed edit never changes the input.
enum ChatMessageEdits {
    static func matches(_ current: ChatMessage, expected: ChatMessage) -> Bool {
        var current = current
        var expected = expected
        if var metrics = current.responseMetrics { metrics.speedSamples = nil; current.responseMetrics = metrics }
        if var metrics = expected.responseMetrics { metrics.speedSamples = nil; expected.responseMetrics = metrics }
        return current == expected
    }

    /// A display edit may carry an older copy of runtime-only speed samples.
    static func preservingSpeedSamples(in updated: ChatMessage, from current: ChatMessage) -> ChatMessage {
        var result = updated
        if var metrics = result.responseMetrics, let currentMetrics = current.responseMetrics {
            metrics.speedSamples = currentMetrics.speedSamples
            result.responseMetrics = metrics
        }
        return result
    }

    static func edit(_ messages: inout [ChatMessage], expected: ChatMessage, _ change: (inout [ChatMessage], Int) -> Bool) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == expected.id }), matches(messages[index], expected: expected) else { return false }
        var candidate = messages
        guard change(&candidate, index) else { return false }
        messages = candidate
        return true
    }

    static func selectVersion(_ index: Int, expected: ChatMessage, messages: inout [ChatMessage]) -> Bool {
        edit(&messages, expected: expected) { candidate, position in
            let current = candidate[position]
            if let info = ChatResponseAttemptSupport.versionInfo(for: current, in: candidate) {
                let attempts = ChatResponseAttemptSupport.orderedAttemptIDs(for: info.responseGroupID, in: candidate)
                guard attempts.indices.contains(index) else { return false }
                candidate = ChatResponseAttemptSupport.selectAttempt(attemptID: attempts[index], groupID: info.responseGroupID, in: candidate)
            } else {
                guard current.getAllVersions().indices.contains(index) else { return false }
                candidate[position].switchToVersion(index)
            }
            return true
        }
    }

    static func deleteVersion(_ index: Int, expected: ChatMessage, messages: inout [ChatMessage], deleteMessage: (inout [ChatMessage], ChatMessage) -> Void) -> Bool {
        edit(&messages, expected: expected) { candidate, position in
            let current = candidate[position]
            if let info = ChatResponseAttemptSupport.versionInfo(for: current, in: candidate) {
                guard let updated = ChatResponseAttemptSupport.deleteAttempt(at: index, groupID: info.responseGroupID, in: candidate) else { return false }
                candidate = updated
            } else {
                guard current.getAllVersions().indices.contains(index) else { return false }
                if current.getAllVersions().count == 1 { deleteMessage(&candidate, current) }
                else { candidate[position].removeVersion(at: index) }
            }
            return true
        }
    }

    static func removeImage(_ name: String, from message: inout ChatMessage) -> Bool {
        guard message.imageFileNames?.contains(name) == true else { return false }
        let remaining = (message.imageFileNames ?? []).filter { $0 != name }
        let excluded = (message.modelExcludedImageFileNames ?? []).filter { $0 != name }
        message.imageFileNames = remaining.isEmpty ? nil : remaining
        message.modelExcludedImageFileNames = excluded.isEmpty ? nil : excluded
        return true
    }
}
