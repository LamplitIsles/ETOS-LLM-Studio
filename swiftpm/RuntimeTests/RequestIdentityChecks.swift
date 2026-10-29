import Foundation

// This executable exercises only the production task-local identity. It has no
// application startup, storage, defaults, credentials, device or network access.
@main
struct RequestIdentityChecks {
    static func main() async {
        let session = UUID()
        let otherSession = UUID()
        let oldToken = UUID()
        let newToken = UUID()
        precondition(ChatRequestTaskIdentity.permits(sessionID: session, token: oldToken))

        await ChatRequestTaskIdentity.$current.withValue(.init(sessionID: session, token: oldToken)) {
            precondition(ChatRequestTaskIdentity.permits(sessionID: session, token: oldToken))
            precondition(!ChatRequestTaskIdentity.permits(sessionID: session, token: newToken))
            precondition(!ChatRequestTaskIdentity.permits(sessionID: otherSession, token: oldToken))

            let inherited = await Task {
                ChatRequestTaskIdentity.permits(sessionID: session, token: oldToken)
                    && !ChatRequestTaskIdentity.permits(sessionID: session, token: newToken)
            }.value
            precondition(inherited, "child request work must retain its original identity")

            let captured = ChatRequestTaskIdentity.current!
            let detached = await Task.detached {
                ChatRequestTaskIdentity.current == nil
                    && captured.sessionID == session && captured.token == oldToken
            }.value
            precondition(detached, "detached work needs an explicitly captured identity")

            ChatRequestTaskIdentity.$current.withValue(.init(sessionID: session, token: newToken)) {
                precondition(ChatRequestTaskIdentity.permits(sessionID: session, token: newToken))
                precondition(!ChatRequestTaskIdentity.permits(sessionID: session, token: oldToken))
            }
            precondition(ChatRequestTaskIdentity.permits(sessionID: session, token: oldToken))
        }
        print("request identity checks passed")
    }
}
