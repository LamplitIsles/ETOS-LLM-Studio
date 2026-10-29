import Foundation

/// An observation in this process; it does not assert whether the tool ran.
public struct ChatUnknownToolOutcome: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let messageID: UUID
    public let toolCallID: String
    public let toolName: String
}

/// The owner serializes access with the request-state lock.
struct ChatUnknownToolOutcomes {
    private var records: [UUID: [UUID: ChatUnknownToolOutcome]] = [:]

    mutating func record(_ outcome: ChatUnknownToolOutcome, sessionExists: Bool) {
        guard sessionExists else { return }
        records[outcome.sessionID, default: [:]][outcome.id] = outcome
    }
    func snapshot() -> [UUID: [ChatUnknownToolOutcome]] {
        records.mapValues { $0.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    }
    mutating func acknowledge(sessionID: UUID, id: UUID) -> Bool {
        guard records[sessionID]?.removeValue(forKey: id) != nil else { return false }
        if records[sessionID]?.isEmpty == true { records.removeValue(forKey: sessionID) }
        return true
    }
    mutating func removeSession(_ sessionID: UUID) { records.removeValue(forKey: sessionID) }
}
