// ============================================================================
// AppLocalNotificationCenter.swift
// ============================================================================
// ETOS LLM Studio 统一本地通知中心
//
// 功能特性:
// - 统一接管本地通知 delegate，避免多处覆盖导致路由失效
// - 提供通知权限查询、申请和通用通知投递入口
// - 忽略历史 Daily Pulse 通知，并路由仍支持的通知
// ============================================================================

import Foundation
import Combine

#if canImport(UserNotifications)
import UserNotifications

public extension Notification.Name {
    /// 请求当前设备直接打开反馈页面（可附带工单号）。
    static let requestOpenFeedback = Notification.Name("com.ETOS.feedback.requestOpen")
    /// 请求当前设备直接打开隐藏日记页面。
    static let requestOpenAchievementJournal = Notification.Name("com.ETOS.achievementJournal.requestOpen")
    /// 请求当前设备直接打开检查更新页面。
    static let requestOpenUpdateTimeline = Notification.Name("com.ETOS.updateTimeline.requestOpen")
}

public enum AppLocalNotificationRoute: String, Sendable {
    case dailyPulse
    case feedback
    case achievementJournal
    case updateTimeline
}

private let appLocalNotificationRouteUserInfoKey = "route"
private let appLocalNotificationIssueNumberUserInfoKey = "issue_number"
private let appLocalNotificationAchievementIDUserInfoKey = "achievement_id"
private let appLocalNotificationSuppressWhenForegroundUserInfoKey = "suppress_when_foreground"

private struct AppLocalNotificationPayload: Sendable {
    let route: AppLocalNotificationRoute?
    let issueNumber: Int?
    let suppressWhenForeground: Bool

    init(userInfo: [AnyHashable: Any]) {
        if let routeRawValue = userInfo[appLocalNotificationRouteUserInfoKey] as? String {
            route = AppLocalNotificationRoute(rawValue: routeRawValue)
        } else {
            route = nil
        }
        issueNumber = AppLocalNotificationPayload.parseIssueNumber(from: userInfo)
        suppressWhenForeground = (userInfo[appLocalNotificationSuppressWhenForegroundUserInfoKey] as? Bool)
            ?? (userInfo[appLocalNotificationSuppressWhenForegroundUserInfoKey] as? NSNumber)?.boolValue
            ?? false
    }

    func shouldPresentWhileForeground() -> Bool {
        !suppressWhenForeground
    }

    private static func parseIssueNumber(from userInfo: [AnyHashable: Any]) -> Int? {
        if let intValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? Int {
            return intValue
        }
        if let numberValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = userInfo[appLocalNotificationIssueNumberUserInfoKey] as? String {
            return Int(stringValue)
        }
        return nil
    }
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    @Published public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published public private(set) var pendingRoute: AppLocalNotificationRoute?
    @Published public private(set) var pendingFeedbackIssueNumber: Int?

    private var didConfigure = false
    private nonisolated static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private override init() {
        super.init()
    }

    public func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        guard !Self.isRunningUnitTests else { return }
        UNUserNotificationCenter.current().delegate = self
        Task {
            await refreshAuthorizationStatus()
        }
    }

    @discardableResult
    public func refreshAuthorizationStatus() async -> UNAuthorizationStatus {
        guard !Self.isRunningUnitTests else {
            authorizationStatus = .denied
            return .denied
        }
        configureIfNeeded()
        let settings = await currentNotificationSettings()
        authorizationStatus = settings.authorizationStatus
        return settings.authorizationStatus
    }

    @discardableResult
    public func requestAuthorizationIfNeeded(
        options: UNAuthorizationOptions = [.alert, .sound, .badge]
    ) async -> Bool {
        guard !Self.isRunningUnitTests else { return false }
        configureIfNeeded()
        let status = await refreshAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().requestAuthorization(options: options) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            _ = await refreshAuthorizationStatus()
            return granted
        @unknown default:
            return false
        }
    }

    @discardableResult
    public func addNotificationRequest(_ request: UNNotificationRequest) async -> Bool {
        guard !Self.isRunningUnitTests else { return false }
        configureIfNeeded()
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// 通知正文不包含服务端响应或存储凭据。
    @discardableResult
    public func postSnapshotUploadFinishedNotification(operationID: UUID, succeeded: Bool) async -> Bool {
        guard await requestAuthorizationIfNeeded() else { return false }
        let content = UNMutableNotificationContent()
        content.title = succeeded
            ? NSLocalizedString("云备份已完成", comment: "云备份成功通知标题")
            : NSLocalizedString("云备份失败", comment: "云备份失败通知标题")
        content.body = succeeded
            ? NSLocalizedString("快照已上传到 S3/R2。", comment: "云备份成功通知正文")
            : NSLocalizedString("快照未能上传。请返回快照备份页面查看详情并重试。", comment: "云备份失败通知正文")
        content.sound = .default
        content.threadIdentifier = "com.ETOS.snapshot.upload"
        return await addNotificationRequest(UNNotificationRequest(
            identifier: "com.ETOS.snapshot.upload.\(operationID.uuidString)",
            content: content,
            trigger: nil
        ))
    }

    public func removePendingRequests(withIdentifiers identifiers: [String]) {
        guard !Self.isRunningUnitTests, !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removePendingRequests(withIdentifierPrefixes prefixes: [String]) async {
        guard !Self.isRunningUnitTests, !prefixes.isEmpty else { return }
        let requests = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
        let identifiers = requests
            .map(\.identifier)
            .filter { identifier in
                prefixes.contains { prefix in identifier.hasPrefix(prefix) }
            }
        removePendingRequests(withIdentifiers: identifiers)
    }

    public func removeDeliveredRequests(withIdentifiers identifiers: [String]) {
        guard !Self.isRunningUnitTests, !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func removeDeliveredRequests(withIdentifierPrefixes prefixes: [String]) async {
        guard !Self.isRunningUnitTests, !prefixes.isEmpty else { return }
        let notifications = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications)
            }
        }
        let identifiers = notifications
            .map(\.request.identifier)
            .filter { identifier in
                prefixes.contains { prefix in identifier.hasPrefix(prefix) }
            }
        removeDeliveredRequests(withIdentifiers: identifiers)
    }

    public nonisolated static func notificationTargetsFeedback(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.feedback.rawValue
    }

    public nonisolated static func notificationTargetsAchievementJournal(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.achievementJournal.rawValue
    }

    public nonisolated static func notificationTargetsUpdateTimeline(userInfo: [AnyHashable: Any]) -> Bool {
        guard let route = userInfo[appLocalNotificationRouteUserInfoKey] as? String else { return false }
        return route == AppLocalNotificationRoute.updateTimeline.rawValue
    }

    public nonisolated static func updateTimelineUserInfo() -> [AnyHashable: Any] {
        [
            appLocalNotificationRouteUserInfoKey: AppLocalNotificationRoute.updateTimeline.rawValue
        ]
    }

    public nonisolated static func notificationShouldPresentWhileForeground(
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        AppLocalNotificationPayload(userInfo: userInfo)
            .shouldPresentWhileForeground()
    }

    public nonisolated static func achievementJournalUserInfo(achievementID: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            appLocalNotificationRouteUserInfoKey: AppLocalNotificationRoute.achievementJournal.rawValue
        ]
        if let achievementID, !achievementID.isEmpty {
            info[appLocalNotificationAchievementIDUserInfoKey] = achievementID
        }
        return info
    }

    public func consumePendingRoute() -> AppLocalNotificationRoute? {
        let route = pendingRoute
        pendingRoute = nil
        return route
    }

    public func consumePendingFeedbackIssueNumber() -> Int? {
        let issueNumber = pendingFeedbackIssueNumber
        pendingFeedbackIssueNumber = nil
        return issueNumber
    }

    private func openFeedbackFromNotification(payload: AppLocalNotificationPayload) {
        pendingRoute = .feedback
        pendingFeedbackIssueNumber = payload.issueNumber
        NotificationCenter.default.post(name: .requestOpenFeedback, object: nil)
    }

    private func openAchievementJournalFromNotification() {
        pendingRoute = .achievementJournal
        NotificationCenter.default.post(name: .requestOpenAchievementJournal, object: nil)
    }

    private func openUpdateTimelineFromNotification() {
        pendingRoute = .updateTimeline
        NotificationCenter.default.post(name: .requestOpenUpdateTimeline, object: nil)
    }

    func handleNotificationResponseUserInfo(
        _ userInfo: [AnyHashable: Any],
        actionIdentifier: String
    ) {
        let payload = AppLocalNotificationPayload(userInfo: userInfo)
        handleNotificationResponsePayload(payload, actionIdentifier: actionIdentifier)
    }

    private func handleNotificationResponsePayload(
        _ payload: AppLocalNotificationPayload,
        actionIdentifier: String
    ) {
        if payload.route == .dailyPulse {
            return
        } else if payload.route == .feedback {
            openFeedbackFromNotification(payload: payload)
        } else if payload.route == .achievementJournal {
            openAchievementJournalFromNotification()
        } else if payload.route == .updateTimeline {
            openUpdateTimelineFromNotification()
        }
    }

    private func currentNotificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

}

extension AppLocalNotificationCenter: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = AppLocalNotificationPayload(userInfo: notification.request.content.userInfo)
        guard payload.shouldPresentWhileForeground() else { return [] }
#if os(iOS) || os(macOS)
        return [.banner, .list, .sound]
#elseif os(watchOS)
        if #available(watchOS 8.0, *) {
            return [.banner, .list, .sound]
        } else {
            return [.sound]
        }
#else
        return [.sound]
#endif
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = AppLocalNotificationPayload(userInfo: response.notification.request.content.userInfo)
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor [payload, actionIdentifier] in
            AppLocalNotificationCenter.shared.handleNotificationResponsePayload(
                payload,
                actionIdentifier: actionIdentifier
            )
        }
        completionHandler()
    }
}
#else
public extension Notification.Name {
    static let requestOpenFeedback = Notification.Name("com.ETOS.feedback.requestOpen")
    static let requestOpenAchievementJournal = Notification.Name("com.ETOS.achievementJournal.requestOpen")
    static let requestOpenUpdateTimeline = Notification.Name("com.ETOS.updateTimeline.requestOpen")
}

@MainActor
public final class AppLocalNotificationCenter: NSObject, ObservableObject {
    public static let shared = AppLocalNotificationCenter()

    private override init() {
        super.init()
    }
}
#endif
