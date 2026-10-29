import Foundation

enum ShortcutTransportAttempt<Result> {
    case notStarted(Result)
    case completed(Result)
    case outcomeUnknown(Result)
    case stopped(Result)

    var result: Result {
        switch self {
        case .notStarted(let result), .completed(let result), .outcomeUnknown(let result), .stopped(let result): return result
        }
    }
}

enum ShortcutTransportFallback {
    static func run<Transport, Result>(
        transports: [Transport],
        attempt: (Transport) async -> ShortcutTransportAttempt<Result>
    ) async -> ShortcutTransportAttempt<Result>? {
        var last: ShortcutTransportAttempt<Result>?
        for transport in transports {
            switch await attempt(transport) {
            case .notStarted(let result): last = .notStarted(result)
            case let outcome: return outcome
            }
        }
        return last
    }
}
