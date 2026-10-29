import Foundation
import Combine

extension AppToolKind {
    var builtInDescriptionPromptID: BuiltInPromptID? {
        switch self {
        case .showWidget: .showWidgetToolDescription
        case .getSystemTime: .getSystemTimeToolDescription
        default: nil
        }
    }
}

public enum ToolDescriptionTarget: Identifiable {
    case builtIn(BuiltInPromptID)

    public var id: String {
        switch self {
        case .builtIn(let id): "built-in-\(id.rawValue)"
        }
    }
}

struct ToolDescriptionRow: Identifiable {
    let target: ToolDescriptionTarget
    let title: String
    let isCustomized: Bool
    var id: String { target.id }
}

struct ToolDescriptionGroup: Identifiable {
    let id: String
    let title: String
    let rows: [ToolDescriptionRow]
}

/// 编辑草稿与持久化快照分开：向导只改草稿，原生保存才会影响后续请求。
@MainActor
final class ToolDescriptionEditorModel: ObservableObject {
    let target: ToolDescriptionTarget
    @Published var draft = ""
    @Published var usesDefault = true
    @Published private(set) var title = ""
    @Published private(set) var defaultDescription = ""
    @Published private(set) var inputSchema: JSONValue = .null
    @Published private(set) var isLoaded = false
    @Published private(set) var isSaving = false
    @Published private(set) var statusText: String?

    init(target: ToolDescriptionTarget) { self.target = target }

    func load() async {
        switch target {
        case .builtIn(let id):
            let snapshot = await Task.detached(priority: .utility) { BuiltInPromptStore.snapshot(for: id) }.value
            title = snapshot.title
            defaultDescription = snapshot.defaultTemplate
            draft = snapshot.currentTemplate
            usesDefault = !snapshot.isCustomized
        }
        isLoaded = true
    }

    func save() async {
        guard isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        switch target {
        case .builtIn(let id):
            let draft = draft
            let usesDefault = usesDefault
            let saved = await Task.detached(priority: .utility) {
                usesDefault ? BuiltInPromptStore.resetTemplate(for: id) : BuiltInPromptStore.saveTemplate(draft, for: id)
            }.value
            guard saved else {
                statusText = NSLocalizedString("保存失败", comment: "")
                return
            }
        }
        await load()
        statusText = NSLocalizedString("已保存提示词设置。", comment: "")
    }
}
