// ============================================================================
// RoleplayBridgeDispatcher.swift
// ============================================================================
// ETOS LLM Studio
//
// 处理 HTML 卡片的变量、消息及事件动作。
// ============================================================================

import Foundation

public enum RoleplayBridgeNotification {
    public static let completedRequest = Notification.Name("com.ETOS.roleplayBridge.completedRequest")
    public static let sessionIDKey = "sessionID"
    public static let eventNameKey = "eventName"
    public static let requestIDKey = "requestID"
    public static let resultKey = "result"
    public static let errorKey = "error"
}

public enum RoleplayDisplayedMessageBridge {
    public static let variableKey = "__etos_displayed_html"
    public static let didChangeNotification = Notification.Name("com.ETOS.roleplayDisplayedMessage.didChange")

    public static func postDidChange(sessionID: UUID) {
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [RoleplayBridgeNotification.sessionIDKey: sessionID]
        )
    }
}

public enum RoleplayEventBridge {
    public static let didEmitNotification = Notification.Name("com.ETOS.roleplayEvent.didEmit")
    public static let argumentsKey = "arguments"
    public static let sourceKey = "source"
}
