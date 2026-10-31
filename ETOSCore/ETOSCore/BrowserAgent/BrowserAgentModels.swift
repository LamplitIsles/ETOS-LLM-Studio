import Foundation

public enum BrowserAgentDataProfile: String, Codable, CaseIterable, Sendable {
    /// 每个新标签页使用临时网站数据，退出进程后不会保留登录态。
    case sessionIsolated = "session_isolated"
    /// 使用系统默认网站数据仓，允许不同会话复用用户明确选择保留的登录态。
    case persistentShared = "persistent_shared"

    public var displayName: String {
        switch self {
        case .sessionIsolated:
            return NSLocalizedString("会话隔离", comment: "Browser Agent isolated data profile")
        case .persistentShared:
            return NSLocalizedString("持久共享登录态", comment: "Browser Agent persistent data profile")
        }
    }
}
