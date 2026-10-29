import Foundation

enum ChatToolRetryDecision: Equatable {
    case reuse(String)
    case outcomeUnknown

    static func decide(storedResult: String?, embeddedResult: String?) -> Self {
        for value in [storedResult, embeddedResult] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return .reuse(trimmed) }
        }
        return .outcomeUnknown
    }
}
