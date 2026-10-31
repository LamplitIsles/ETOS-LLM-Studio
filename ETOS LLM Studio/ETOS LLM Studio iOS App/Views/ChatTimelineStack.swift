import SwiftUI

/// The shared ETOS timeline layout; each conversation supplies its own rows.
struct ChatTimelineStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            Color.clear.frame(height: 8).id(ChatScrollTargetID.top)
            content
            Color.clear.frame(height: 8).id(ChatScrollTargetID.bottom)
        }
        .scrollTargetLayout()
        .coordinateSpace(.named(ChatHistoryAnchorLayout.coordinateSpaceName))
    }
}
