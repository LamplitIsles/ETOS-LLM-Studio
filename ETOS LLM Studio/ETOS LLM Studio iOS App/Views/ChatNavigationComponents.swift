import SwiftUI

struct ChatNavigationBar<Leading: View, Center: View, Trailing: View>: View {
    let leading: Leading
    let center: Center
    let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            leading
            Spacer(minLength: 12)
            center
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ChatNavigationPillSurface<Content: View>: View {
    let content: Content
    let usesLiquidGlass: Bool
    let tint: Color
    let selected: Bool

    var body: some View {
        Group {
            if #available(iOS 26.0, *), usesLiquidGlass {
                content.background(Capsule().fill(tint)).glassEffect(.clear.interactive(), in: Capsule())
            } else {
                content.background(Capsule().fill(.ultraThinMaterial))
            }
        }
        .overlay(Capsule().stroke(selected ? Color.white.opacity(0.35) : Color.white.opacity(0.2), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }
}
