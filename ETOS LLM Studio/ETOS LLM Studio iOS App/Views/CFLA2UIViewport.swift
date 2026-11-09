import SwiftUI
import Combine

/// Shared with independently hosted message cells, whose builders outlive
/// the timeline view value that first created them.
@MainActor
final class CFLA2UIViewport: ObservableObject {
    @Published private(set) var height: CGFloat = 0

    func update(height: CGFloat) {
        guard self.height != height else { return }
        self.height = height
    }
}
