import Foundation

/// Keeps a bubble's image reads alive while its Markdown subtree is replaced.
@MainActor
final class CFLMarkdownImageStore {
    struct Context: Equatable {
        let target: String?
        let session: String?
        let revision: Int
        let clientID: UUID
    }

    private struct Pending {
        let id: UUID
        let task: Task<Data, Error>
    }
    private let cached = NSCache<NSData, NSData>()
    private var pending: [Data: Pending] = [:]
    private var context: Context?
    private var generation: UInt64 = 0
    private var inlineFailures: Set<String> = []

    var inlineFailed: Bool { !inlineFailures.isEmpty }

    init() {
        cached.totalCostLimit = 32 * 1024 * 1024
    }

    func updateContext(_ next: Context) {
        guard context != next else { return }
        invalidate()
        context = next
    }

    var stamp: UInt64 { generation }

    func inlineFailure(_ key: String, stamp: UInt64) {
        guard self.stamp == stamp else { return }
        inlineFailures.insert(key)
    }

    func inlineSuccess(_ key: String, stamp: UInt64) {
        guard self.stamp == stamp else { return }
        inlineFailures.remove(key)
    }

    func clearInlineFailures() { inlineFailures.removeAll() }

    func data(for key: Data, context: Context, load: @escaping @MainActor () async throws -> Data) async throws -> Data {
        updateContext(context)
        let expectedGeneration = generation
        if let value = cached.object(forKey: key as NSData) { return value as Data }
        if let existing = pending[key] {
            let value = try await existing.task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            return value
        }
        let id = UUID()
        let task = Task { try await load() }
        pending[key] = Pending(id: id, task: task)
        do {
            let value = try await task.value
            guard generation == expectedGeneration else { throw CancellationError() }
            if pending[key]?.id == id {
                pending[key] = nil
                cached.setObject(value as NSData, forKey: key as NSData, cost: value.count)
            }
            return value
        } catch {
            if pending[key]?.id == id { pending[key] = nil }
            throw error
        }
    }

    func invalidate() {
        generation &+= 1
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
        cached.removeAllObjects()
        inlineFailures.removeAll()
    }

    func discard(_ key: Data) {
        cached.removeObject(forKey: key as NSData)
    }
}
