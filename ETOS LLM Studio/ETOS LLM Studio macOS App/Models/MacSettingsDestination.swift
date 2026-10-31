import Foundation

enum MacSettingsDestination: String, Identifiable {
    case display
    case usage, shortcuts, speech, tts, extended
    case general, security, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: NSLocalizedString("背景与视觉", comment: "")
        case .usage: NSLocalizedString("用量统计", comment: "")
        case .shortcuts: NSLocalizedString("快捷指令工具集成", comment: "")
        case .speech: NSLocalizedString("语音输入", comment: "")
        case .tts: NSLocalizedString("语音输出", comment: "")
        case .extended: NSLocalizedString("拓展功能", comment: "")
        case .general: NSLocalizedString("通用", comment: "")
        case .security: NSLocalizedString("安全", comment: "")
        case .about: NSLocalizedString("关于 ETOS LLM Studio", comment: "")
        }
    }
    var symbol: String {
        switch self {
        case .display: "paintpalette"
        case .usage: "chart.bar"
        case .shortcuts: "square.stack.3d.up"
        case .speech: "mic"
        case .tts: "speaker.wave.2"
        case .extended: "square.grid.2x2"
        case .general: "gearshape"
        case .security: "lock.shield"
        case .about: "info.circle"
        }
    }
}
