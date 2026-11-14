import ExpoModulesCore
import UIKit

// Experimental inputView surface: Fabric mounts its child into an owned UIKit
// container, so UIKit can present the container without moving the RN child.
private final class PanelInputView: UIInputView {
  private weak var ownedChild: UIView?

  // Only move the view this panel owns; never inspect or modify UIKit siblings.
  func trackOwnedChild(_ child: UIView?, promote: Bool) {
    ownedChild = child
    if promote { promoteOwnedChild() }
  }

  private func promoteOwnedChild() {
    guard let child = ownedChild, let currentWindow = window,
          child.superview === self, child.window === currentWindow else { return }
    bringSubviewToFront(child)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    promoteOwnedChild()
  }

  var panelHeight: CGFloat = 0 {
    didSet { invalidateIntrinsicContentSize() }
  }
  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: panelHeight)
  }
}

public final class ETOSKeyboardPanelView: ExpoView {
  private let inputSurface = PanelInputView(frame: .zero, inputViewStyle: .keyboard)
  private weak var input: UIView?
  private var mountedChildren: [UIView] = []
  private var generation: Int = -1

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    inputSurface.allowsSelfSizing = true
  }

  func setGeneration(_ next: Int) {
    if next != generation {
      releaseInput()
      generation = next
    }
  }

  public override func mountChildComponentView(_ childComponentView: UIView, index: Int) {
    mountedChildren.insert(childComponentView, at: index)
    // Fabric indices refer to owned children, not UIKit's private siblings.
    if index > 0 {
      inputSurface.insertSubview(childComponentView, aboveSubview: mountedChildren[index - 1])
    } else if mountedChildren.count > 1 {
      inputSurface.insertSubview(childComponentView, belowSubview: mountedChildren[1])
    } else {
      inputSurface.addSubview(childComponentView)
    }
    inputSurface.trackOwnedChild(mountedChildren.count == 1 ? childComponentView : nil, promote: true)
  }

  public override func unmountChildComponentView(_ childComponentView: UIView, index: Int) {
    releaseInput()
    inputSurface.trackOwnedChild(nil, promote: false)
    mountedChildren.removeAll { $0 === childComponentView }
    childComponentView.removeFromSuperview()
    inputSurface.trackOwnedChild(mountedChildren.count == 1 ? mountedChildren[0] : nil, promote: false)
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      releaseInput()
    }
  }

  private func currentInputView(_ view: UIView) -> UIView? {
    if let text = view as? UITextView { return text.inputView }
    if let text = view as? UITextField { return text.inputView }
    return nil
  }

  private func setInputView(_ value: UIView?, on view: UIView) -> Bool {
    if let text = view as? UITextView { text.inputView = value; return true }
    if let text = view as? UITextField { text.inputView = value; return true }
    return false
  }

  private func releaseInput() {
    guard let view = input else { return }
    input = nil
    // Do not overwrite an inputView which RN or another owner replaced.
    if currentInputView(view) === inputSurface {
      _ = setInputView(nil, on: view)
      if view.isFirstResponder { view.reloadInputViews() }
    }
  }

  func dismiss(generation expected: Int, backing: UIView) -> String {
    guard expected == generation, expected >= 0, window != nil else { return "session_changed" }
    guard backing.window === window else { return "targets_unavailable" }
    guard backing is UITextView || backing is UITextField else { return "input_unsupported" }
    let current = currentInputView(backing)
    guard current == nil || current === inputSurface else { return "input_owned_elsewhere" }
    let owned = current === inputSurface
    if owned { _ = setInputView(nil, on: backing) }
    if input === backing { input = nil }
    // Do not resign a different responder, such as the sticker search sheet.
    if backing.isFirstResponder && !backing.resignFirstResponder() {
      if owned { _ = setInputView(inputSurface, on: backing); input = backing }
      return "dismiss_refused"
    }
    return "requested"
  }

  func switchMode(generation expected: Int, backing: UIView, panel: Bool, height: Double) -> String {
    guard expected == generation, expected >= 0, window != nil else { return "session_changed" }
    guard height.isFinite, height >= 1, height <= 1000 else { return "invalid_height" }
    guard mountedChildren.count == 1, mountedChildren[0].superview === inputSurface else { return "targets_unavailable" }
    guard backing.window === window else { return "targets_unavailable" }
    if let previous = input, previous !== backing { releaseInput() }
    let current = currentInputView(backing)
    guard current == nil || current === inputSurface else { return "input_owned_elsewhere" }
    guard backing is UITextView || backing is UITextField else { return "input_unsupported" }
    inputSurface.panelHeight = CGFloat(height)
    inputSurface.frame = CGRect(x: 0, y: 0, width: window?.bounds.width ?? 0, height: CGFloat(height))
    let wasFocused = backing.isFirstResponder
    guard setInputView(panel ? inputSurface : nil, on: backing) else { return "input_unsupported" }
    if wasFocused {
      backing.reloadInputViews()
    } else if !backing.becomeFirstResponder() {
      _ = setInputView(current, on: backing)
      return "input_not_focused"
    }
    input = panel ? backing : nil
    // This acknowledges the request only, not UIKit presentation or animation.
    return "requested"
  }
}
