import Foundation

// Minimal in-memory values exercise the production edit transaction and version dispatch.
struct Metrics: Equatable { var speedSamples: [Int]?; var other: Int = 0 }
struct ChatMessage: Equatable {
    var id = UUID()
    var content: String
    var versions: [String]
    var selected = 0
    var responseMetrics: Metrics?
    var imageFileNames: [String]?
    var modelExcludedImageFileNames: [String]?
    var group: UUID?
    var attempt: UUID?
    var selectedAttempt: UUID?
    init(_ content: String, images: [String]? = nil) { self.content = content; self.versions = [content]; self.imageFileNames = images }
    func getAllVersions() -> [String] { versions }
    mutating func addVersion(_ value: String) { versions.append(value); selected = versions.count - 1; content = value }
    mutating func switchToVersion(_ index: Int) { selected = index; content = versions[index] }
    mutating func removeVersion(at index: Int) { versions.remove(at: index); selected = min(selected, versions.count - 1); content = versions[selected] }
}
struct AttemptInfo { var responseGroupID: UUID }
enum ChatResponseAttemptSupport {
    static func versionInfo(for message: ChatMessage, in messages: [ChatMessage]) -> AttemptInfo? {
        guard let group = message.group, orderedAttemptIDs(for: group, in: messages).count > 1 else { return nil }
        return AttemptInfo(responseGroupID: group)
    }
    static func orderedAttemptIDs(for group: UUID, in messages: [ChatMessage]) -> [UUID] {
        messages.filter { $0.group == group }.compactMap(\.attempt)
    }
    static func selectAttempt(attemptID: UUID, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { var m = $0; if m.group == groupID { m.selectedAttempt = attemptID }; return m }
    }
    static func deleteAttempt(at index: Int, groupID: UUID, in messages: [ChatMessage]) -> [ChatMessage]? {
        let ids = orderedAttemptIDs(for: groupID, in: messages)
        guard ids.indices.contains(index) else { return nil }
        return messages.filter { $0.group != groupID || $0.attempt != ids[index] }
    }
}
private final class State: @unchecked Sendable {
    let lock = NSLock()
    var messages: [ChatMessage]
    init(_ messages: [ChatMessage]) { self.messages = messages }
}
@main struct ChatMessageEditsChecks {
    static func main() {
        var original = ChatMessage("first", images: ["shared.png"])
        original.responseMetrics = Metrics(speedSamples: [1])
        let state = State([original])
        let appended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            state.lock.withLock { state.messages.append(ChatMessage("new", images: ["shared.png"])) }
            appended.signal()
        }
        precondition(appended.wait(timeout: .now() + 3) == .success)
        let committed = state.lock.withLock {
            ChatMessageEdits.edit(&state.messages, expected: original) { messages, index in
                messages[index].addVersion("second")
                return true
            }
        }
        precondition(committed && state.messages.count == 2 && state.messages[1].content == "new")
        var current = state.messages
        let unchanged = current
        precondition(!ChatMessageEdits.edit(&current, expected: original) { _, _ in true } && current == unchanged)
        var absent = original; absent.id = UUID()
        precondition(!ChatMessageEdits.edit(&current, expected: absent) { _, _ in true } && current == unchanged)
        var updated = current[0]; updated.content = "edited"; updated.responseMetrics?.speedSamples = [0]
        current[0].responseMetrics?.speedSamples = [42]
        let preserved = ChatMessageEdits.preservingSpeedSamples(in: updated, from: current[0])
        precondition(preserved.content == "edited" && preserved.responseMetrics?.speedSamples == [42])
        var expected = current[0]; expected.responseMetrics?.speedSamples = [99]
        precondition(ChatMessageEdits.selectVersion(0, expected: expected, messages: &current))
        precondition(current[0].content == "first" && current[1].content == "new")
        expected = current[0]
        precondition(!ChatMessageEdits.selectVersion(99, expected: expected, messages: &current) && current[0] == expected)
        precondition(ChatMessageEdits.deleteVersion(1, expected: expected, messages: &current, deleteMessage: { messages, target in messages.removeAll { $0.id == target.id } }))
        precondition(current[0].versions == ["first"])
        precondition(ChatMessageEdits.removeImage("shared.png", from: &current[0]))
        precondition(current[0].imageFileNames == nil && current[1].imageFileNames == ["shared.png"])
        precondition(!ChatMessageEdits.removeImage("missing", from: &current[0]))
        let group = UUID(), a = UUID(), b = UUID()
        var first = ChatMessage("a"); first.group = group; first.attempt = a
        var second = ChatMessage("b"); second.group = group; second.attempt = b
        var attempts = [first, second, ChatMessage("other")]
        precondition(ChatMessageEdits.selectVersion(1, expected: first, messages: &attempts))
        precondition(attempts[0].selectedAttempt == b && attempts[2].content == "other")
        let selectedFirst = attempts[0]
        precondition(ChatMessageEdits.deleteVersion(1, expected: selectedFirst, messages: &attempts, deleteMessage: { messages, target in messages.removeAll { $0.id == target.id } }))
        precondition(attempts.count == 2 && attempts[1].content == "other")
        print("chat message edit checks passed")
    }
}
