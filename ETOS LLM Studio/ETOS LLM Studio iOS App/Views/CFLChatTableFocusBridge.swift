#if os(iOS)
import SwiftUI
import UIKit

/// Observes the library's own table gestures without replacing its delegate or
/// cancelling touches on message links, menus, or media controls.
struct CFLChatTableFocusBridge: UIViewRepresentable {
    let focus: Binding<Bool>
    var onDismiss: () -> Void = {}

    func makeUIView(context: Context) -> Observer {
        let view = Observer()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Observer, context: Context) {
        view.dismiss = { focus.wrappedValue = false; onDismiss() }
        view.attachIfNeeded()
    }

    static func dismantleUIView(_ view: Observer, coordinator: ()) {
        view.detach()
    }

    final class Observer: UIView, UIGestureRecognizerDelegate {
        var dismiss: () -> Void = {}
        private weak var table: UITableView?
        private var tap: UITapGestureRecognizer?
        private var previouslyBounced = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else { DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() } }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard window != nil, table == nil else { return }
            var ancestor = superview
            while let current = ancestor {
                if let found = findTable(in: current) {
                    table = found
                    previouslyBounced = found.alwaysBounceVertical
                    found.alwaysBounceVertical = true
                    let recognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
                    recognizer.cancelsTouchesInView = false
                    recognizer.delegate = self
                    found.addGestureRecognizer(recognizer)
                    found.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
                    tap = recognizer
                    return
                }
                ancestor = current.superview
            }
        }

        func detach() {
            if let table {
                if let tap { table.removeGestureRecognizer(tap) }
                table.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
                table.alwaysBounceVertical = previouslyBounced
            }
            tap = nil
            table = nil
        }

        private func findTable(in view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            for child in view.subviews where child !== self {
                if let table = findTable(in: child) { return table }
            }
            return nil
        }

        @objc private func tapped() { dismiss() }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            if abs(translation.y) > 2 && abs(translation.y) > abs(translation.x) { dismiss() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
