import Foundation

@main
enum CFLMarkdownImageStoreChecks {
    @MainActor
    static func main() async throws {
        let store = CFLMarkdownImageStore()
        let clientID = UUID()
        let context = CFLMarkdownImageStore.Context(target: "target", session: "session", revision: 1, clientID: clientID)
        let other = CFLMarkdownImageStore.Context(target: "target", session: "session", revision: 2, clientID: clientID)
        let newClient = CFLMarkdownImageStore.Context(target: "target", session: "session", revision: 1, clientID: UUID())
        let key = Data("image".utf8)
        let expected = Data("image bytes".utf8)
        var loads = 0
        let first = Task {
            try await store.data(for: key, context: context) {
                loads += 1
                try await Task.sleep(for: .milliseconds(60))
                return expected
            }
        }
        while loads == 0 { await Task.yield() }
        first.cancel() // A Markdown subtree disappeared while its bubble remained.
        let second = Task {
            try await store.data(for: key, context: context) { loads += 1; return Data("wrong".utf8) }
        }
        let shared = try await second.value
        precondition(shared == expected && loads == 1)
        let cached = try await store.data(for: key, context: context) { loads += 1; return Data() }
        precondition(cached == expected && loads == 1)

        let clientBytes = try await store.data(for: key, context: newClient) { Data("client".utf8) }
        let revisionBytes = try await store.data(for: key, context: other) { Data("revision".utf8) }
        precondition(clientBytes != expected && revisionBytes != clientBytes)
        store.invalidate()
        let reloaded = try await store.data(for: key, context: context) { loads += 1; return expected }
        precondition(reloaded == expected && loads == 2)

        struct FixtureError: Error {}
        let failedKey = Data("failed".utf8)
        do {
            _ = try await store.data(for: failedKey, context: context) { throw FixtureError() }
            fatalError("A failed read must report its error")
        } catch is FixtureError {}
        let retried = try await store.data(for: failedKey, context: context) { expected }
        precondition(retried == expected, "Failures must not be cached")
        store.discard(failedKey)
        let replacement = try await store.data(for: failedKey, context: context) { Data("replacement".utf8) }
        precondition(replacement == Data("replacement".utf8), "Undecodable data must be replaceable")

        let oldStamp = store.stamp
        store.updateContext(other)
        store.updateContext(context)
        store.inlineFailure("stale", stamp: oldStamp)
        precondition(!store.inlineFailed, "Old callbacks must not restore failures")
        let currentStamp = store.stamp
        store.inlineFailure("current", stamp: currentStamp)
        store.inlineSuccess("current", stamp: oldStamp)
        precondition(store.inlineFailed, "Old callbacks must not clear current failures")
        store.inlineSuccess("current", stamp: currentStamp)
        precondition(!store.inlineFailed, "A current success clears its failure")

        var started = false
        let outstanding = Task {
            try await store.data(for: Data("other".utf8), context: context) {
                started = true
                try await Task.sleep(for: .seconds(30))
                return expected
            }
        }
        while !started { await Task.yield() }
        store.invalidate()
        do {
            _ = try await outstanding.value
            fatalError("Invalidation must cancel the underlying read")
        } catch is CancellationError {}

        var uncooperativeStarted = false
        let stale = Task {
            try await store.data(for: key, context: context) {
                uncooperativeStarted = true
                try? await Task.sleep(for: .seconds(30))
                return Data("stale".utf8)
            }
        }
        while !uncooperativeStarted { await Task.yield() }
        store.updateContext(other)
        store.updateContext(context)
        do {
            _ = try await stale.value
            fatalError("Returning to a previous context must not accept an old read")
        } catch is CancellationError {}
        print("CFL Markdown image store checks passed")
    }
}
