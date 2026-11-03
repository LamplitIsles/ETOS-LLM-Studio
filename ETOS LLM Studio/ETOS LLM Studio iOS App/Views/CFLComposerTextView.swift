#if os(iOS)
import SwiftUI
import UIKit

/// A multiline composer whose return key submits instead of inserting a newline.
struct CFLComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let focus: Binding<Bool>
    let font: UIFont
    let maximumHeight: CGFloat
    let hardwareReturnSends: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.font = font
        view.text = text
        view.returnKeyType = .send
        view.delegate = context.coordinator
        view.onHardwareSubmit = { context.coordinator.parent.onSubmit() }
        view.accessibilityLabel = NSLocalizedString("Message", comment: "聊天输入框占位文本")
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        context.coordinator.parent = self
        if view.text != text && view.markedTextRange == nil {
            view.text = text
        }
        view.font = font
        view.hardwareReturnSends = hardwareReturnSends
        view.refreshPlaceholder()
        view.setNeedsLayout()
        if focus.wrappedValue && !view.isFirstResponder && view.window != nil {
            view.becomeFirstResponder()
        } else if !focus.wrappedValue && view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InputView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.fittingHeight(width: width, maximum: maximumHeight))
    }

    static func dismantleUIView(_ view: InputView, coordinator: Coordinator) {
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CFLComposerTextView
        init(parent: CFLComposerTextView) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focus.wrappedValue { parent.focus.wrappedValue = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focus.wrappedValue { parent.focus.wrappedValue = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
            (textView as? InputView)?.refreshPlaceholder()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            if (textView as? InputView)?.insertingHardwareNewline == true { return true }
            guard replacement == "\n", textView.markedTextRange == nil else { return true }
            parent.onSubmit()
            return false
        }
    }

    final class InputView: UITextView {
        var hardwareReturnSends = false
        var insertingHardwareNewline = false
        var onHardwareSubmit: () -> Void = {}
        private let placeholder = UILabel()

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            placeholder.text = NSLocalizedString("Message", comment: "聊天输入框占位文本")
            placeholder.textColor = .placeholderText
            placeholder.isUserInteractionEnabled = false
            placeholder.isAccessibilityElement = false
            addSubview(placeholder)
        }

        required init?(coder: NSCoder) { nil }

        func refreshPlaceholder() {
            placeholder.font = font
            placeholder.isHidden = !text.isEmpty
        }

        func fittingHeight(width: CGFloat, maximum: CGFloat) -> CGFloat {
            let measured = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let insets = textContainerInset.top + textContainerInset.bottom
            let minimum = max(44, (font?.lineHeight ?? 20) + 16)
            return ceil(max(minimum, min(max(minimum, maximum), measured - insets + 16)))
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard presses.count == 1, let key = presses.first?.key,
                  key.keyCode == .keyboardReturnOrEnter, markedTextRange == nil else {
                super.pressesBegan(presses, with: event)
                return
            }
            let flags = key.modifierFlags
            var modifiers: EventModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if ChatComposerHardwareKeyboardReturnAction.resolve(
                returnSendsMessage: hardwareReturnSends, modifiers: modifiers
            ) == .send {
                onHardwareSubmit()
            } else {
                insertingHardwareNewline = true
                insertText("\n")
                insertingHardwareNewline = false
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let multiline = bounds.height > max(44, (font?.lineHeight ?? 20) + 16) + 0.5
            let top = multiline ? CGFloat(8) : max(0, (bounds.height - (font?.lineHeight ?? 20)) / 2)
            let inset = UIEdgeInsets(top: top, left: 0, bottom: multiline ? 8 : top, right: 0)
            if textContainerInset != inset { textContainerInset = inset }
            placeholder.frame = CGRect(x: 0, y: top, width: bounds.width,
                                       height: font?.lineHeight ?? 20)
        }
    }
}
#endif
