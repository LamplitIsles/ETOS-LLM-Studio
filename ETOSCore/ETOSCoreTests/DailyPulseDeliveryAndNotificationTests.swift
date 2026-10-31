// ============================================================================
// DailyPulseDeliveryAndNotificationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 每日脉冲历史状态与本地通知路由测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore
#if canImport(UserNotifications)
import UserNotifications
#endif

@Suite("每日脉冲历史状态与通知测试")
struct DailyPulseDeliveryAndNotificationTests {

#if canImport(UserNotifications)
    @Test("未宿主单元测试不会访问系统通知中心")
    @MainActor
    func unhostedUnitTestsDoNotAccessSystemNotificationCenter() async {
        let center = AppLocalNotificationCenter.shared
        #expect(await center.requestAuthorizationIfNeeded() == false)
        #expect(await center.refreshAuthorizationStatus() == .denied)
    }

    @MainActor
    @Test("历史 Pulse 通知操作被忽略且不会覆盖待处理的反馈路由")
    func historicalPulseActionsAreIgnored() {
        let center = AppLocalNotificationCenter.shared
        _ = center.consumePendingRoute()
        _ = center.consumePendingFeedbackIssueNumber()
        center.handleNotificationResponseUserInfo(
            ["route": "feedback", "issue_number": 42],
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )
        let payload: [AnyHashable: Any] = [
            "route": "dailyPulse", "kind": "card", "dayKey": "2026-10-08",
            "runID": UUID().uuidString, "cardID": UUID().uuidString
        ]
        for action in [UNNotificationDefaultActionIdentifier, "dailyPulse.action.open", "dailyPulse.action.like",
                       "dailyPulse.action.save", "dailyPulse.action.continue", "dailyPulse.action.task", "unknown"] {
            center.handleNotificationResponseUserInfo(payload, actionIdentifier: action)
            #expect(center.pendingRoute == .feedback)
        }
        #expect(center.consumePendingRoute() == .feedback)
        #expect(center.consumePendingFeedbackIssueNumber() == 42)
    }

    @Test("反馈通知路由能识别目标 userInfo")
    func feedbackNotificationRouteDetection() {
        let userInfo: [AnyHashable: Any] = [
            "route": "feedback",
            "issue_number": 12345
        ]

        #expect(AppLocalNotificationCenter.notificationTargetsFeedback(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationTargetsFeedback(userInfo: ["route": "dailyPulse"]))
    }

#endif
}
