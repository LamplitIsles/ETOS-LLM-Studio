import ETOSCore
import SwiftUI

struct MacAppLockOverlayModifier: ViewModifier {
    @ObservedObject private var appLock = AppLockManager.shared

    func body(content: Content) -> some View {
        content.overlay { if appLock.state == .locked { AppLockOverlayView() } }
    }
}
