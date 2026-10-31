import SwiftUI

enum ChatTimelineInteraction {
    /// 非流式尺寸变化交给 SwiftUI；流式期间由 UIKit 单独动画真实滚动偏移，避免双重吸底。
    nonisolated static func chatSizeChangeScrollAnchor(
        keepsBottomPinned: Bool,
        isStreaming: Bool,
        isStreamingViewportFollowing: Bool = false
    ) -> UnitPoint? {
        keepsBottomPinned && !isStreaming && !isStreamingViewportFollowing ? .bottom : nil
    }

    /// 用户手势与离底导航永远优先于自动吸底；静止时只有真正回到底部才重新接管。
    nonisolated static func resolvedBottomPinIntent(
        currentIntent: Bool,
        distanceToBottom: CGFloat,
        arrivalTolerance: CGFloat,
        isUserInteracting: Bool,
        isLayoutSettling: Bool,
        isNavigatingAwayFromBottom: Bool = false
    ) -> Bool {
        if isUserInteracting || isNavigatingAwayFromBottom {
            return false
        }
        if currentIntent {
            return true
        }
        return !isLayoutSettling && distanceToBottom <= arrivalTolerance
    }

    nonisolated static func shouldRevealScrollNavigationForEdgeSwipe(
        startLocationX: CGFloat,
        viewportWidth: CGFloat,
        translation: CGSize,
        edgeActivationWidth: CGFloat = ChatTimelineEdgePanController.activationWidth,
        minimumHorizontalDistance: CGFloat = 14
    ) -> Bool {
        guard viewportWidth > 0,
              startLocationX >= viewportWidth - edgeActivationWidth,
              translation.width <= -minimumHorizontalDistance else {
            return false
        }
        return abs(translation.width) > abs(translation.height) * 1.2
    }
}
