import Foundation

@main
enum ShortcutTransportFallbackChecks {
    static func main() async {
        var attempted: [Int] = []
        let preflightFailure = await ShortcutTransportFallback.run(transports: [1, 2]) { transport in
            attempted.append(transport)
            return transport == 1 ? .notStarted("bad URL") : .completed("complete")
        }
        precondition(attempted == [1, 2] && preflightFailure?.result == "complete")

        attempted = []
        let unknown = await ShortcutTransportFallback.run(transports: [1, 2]) { transport in
            attempted.append(transport)
            return .outcomeUnknown("outcome unknown")
        }
        guard case .outcomeUnknown("outcome unknown")? = unknown else { preconditionFailure("unknown outcome lost") }
        precondition(attempted == [1])

        attempted = []
        let failure = await ShortcutTransportFallback.run(transports: [1, 2]) { transport in
            attempted.append(transport)
            return .completed("callback failure")
        }
        guard case .completed("callback failure")? = failure else { preconditionFailure("callback outcome lost") }
        precondition(attempted == [1])

        attempted = []
        let stopped = await ShortcutTransportFallback.run(transports: [1, 2]) { transport in
            attempted.append(transport)
            return .stopped("cancelled before start")
        }
        guard case .stopped("cancelled before start")? = stopped else { preconditionFailure("stop outcome lost") }
        precondition(attempted == [1])
        print("shortcut transport fallback checks passed")
    }
}
