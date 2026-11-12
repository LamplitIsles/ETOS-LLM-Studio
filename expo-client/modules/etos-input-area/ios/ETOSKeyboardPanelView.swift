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

// Isolated candidate. The action traverses UIKit's responder chain; it does
// not walk a view tree. The sender stores the result only for this invocation.
private final class ETOSFocusCapture: NSObject {
  weak var responder: UIResponder?
}

extension UIResponder {
  @objc fileprivate func etos127CaptureFirstResponder(_ sender: Any?) {
    (sender as? ETOSFocusCapture)?.responder = self
  }
}

private func etosFocusProbe(in window: UIWindow) -> (UIResponder?, String) {
  guard window.isKeyWindow, let scene = window.windowScene,
        scene.activationState == .foregroundActive else { return (nil, "window_inactive") }
  let capture = ETOSFocusCapture()
  let handled = UIApplication.shared.sendAction(#selector(UIResponder.etos127CaptureFirstResponder(_:)),
                                                 to: nil, from: capture, for: nil)
  guard handled else { return (nil, "action_unhandled") }
  guard let responder = capture.responder else { return (nil, "capture_missing") }
  guard responder.isFirstResponder else { return (nil, "not_first") }
  guard window.isKeyWindow, window.windowScene === scene,
        scene.activationState == .foregroundActive else { return (nil, "window_inactive") }
  var current: UIResponder? = responder
  var seen = Set<ObjectIdentifier>()
  for _ in 0..<128 {
    guard let node = current else { return (nil, "chain_unresolved") }
    guard seen.insert(ObjectIdentifier(node)).inserted else { return (nil, "chain_unresolved") }
    if let foundWindow = node as? UIWindow { return foundWindow === window ? (responder, "confirmed") : (nil, "other_window") }
    if node is UIApplication { return (nil, "chain_unresolved") }
    current = node.next
  }
  return (nil, "chain_unresolved")
}

private func etosProvedFirstResponder(in window: UIWindow) -> UIResponder? {
  etosFocusProbe(in: window).0
}

private func etosKeyboardGeometry(in window: UIWindow) -> String {
  let frame = window.keyboardLayoutGuide.layoutFrame
  let bottom = window.safeAreaInsets.bottom
  guard frame.width.isFinite, frame.width > 0, frame.height.isFinite,
        bottom.isFinite, frame.height >= max(0, bottom - 1),
        !window.bounds.isEmpty else { return "unavailable" }
  return frame.height > bottom + 1 ? "overlap_possible" : "no_overlap_observed"
}

// Neutral in-window responder, never a text input and never the panel owner.
// Whether UIKit hides the system keyboard on this handoff is device-unverified.
private final class ETOSFocusFenceResponder: UIView {
  override var canBecomeFirstResponder: Bool { window != nil }
  override var inputView: UIView? { nil }
}

private final class ETOSPanelResponder: UIView {
  weak var panel: UIView?
  var onResign: (() -> Void)?
  override var canBecomeFirstResponder: Bool { window != nil }
  override var inputView: UIView? { panel }
  override func resignFirstResponder() -> Bool {
    let wasFirst = isFirstResponder
    let result = super.resignFirstResponder()
    if wasFirst && result { onResign?() }
    return result
  }
}

private final class ETOSPendingHandoff {
  let generation: Int
  let operation: Int
  let destination: Int
  var toPanel: Bool { destination == 0 }
  var closeOnly: Bool { destination == 2 }
  weak var window: UIWindow?
  weak var backing: UIView?
  var startingResign = true
  var sawWillHide = false
  var sawDidHide = false
  var loggedWillShow = false
  var loggedDidShow = false
  var cancelled = false
  var waitingShow = false
  var emittedTerminal = false
  init(generation: Int, operation: Int, destination: Int, window: UIWindow, backing: UIView) {
    self.generation = generation; self.operation = operation; self.destination = destination
    self.window = window; self.backing = backing
  }
}

public final class ETOSKeyboardPanelView: ExpoView {
  private let inputSurface = PanelInputView(frame: .zero, inputViewStyle: .keyboard)
  private let sequentialOwner = ETOSPanelResponder(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private let focusFence = ETOSFocusFenceResponder(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  let onSequentialHandoff = EventDispatcher()
  private var sequentialPending: ETOSPendingHandoff?
  private var sequentialObservers: [NSObjectProtocol] = []
  private var highestOperation = 0
  private enum KeyboardVisibility { case unknown, changing, visible, hidden }
  private var keyboardVisibility: KeyboardVisibility = .unknown
  private var sequentialEnabled = false
  // Once explicitly abandoned, this native instance cannot dispatch another
  // panel request. UIKit may still be settling an earlier operation.
  private var sequentialAbandoned = false
  private var visibilityObservers: [NSObjectProtocol] = []
  private var lastPanelOwner: (generation: Int, operation: Int)?
  private weak var input: UIView?
  private var mountedChildren: [UIView] = []
  private var generation: Int = -1

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    inputSurface.allowsSelfSizing = true
    sequentialOwner.panel = inputSurface
    sequentialOwner.isAccessibilityElement = false
    sequentialOwner.isUserInteractionEnabled = false
    sequentialOwner.backgroundColor = .clear
    focusFence.isAccessibilityElement = false
    focusFence.isUserInteractionEnabled = false
    focusFence.backgroundColor = .clear
    sequentialOwner.onResign = { [weak self] in self?.sequentialOwnerDidResign() }
  }

  // Explicit opt-in on this particular mounted panel. In release builds this
  // method is unreachable through the module; the original path stays intact.
  func enableSequentialHandoff(generation expected: Int) -> String {
    guard expected == generation, expected >= 0, window != nil else { return "session_changed" }
    guard !sequentialAbandoned else { return "abandoned" }
    guard input == nil, sequentialPending == nil else { return "input_owned_elsewhere" }
    if !sequentialEnabled {
      sequentialEnabled = true
      addSubview(focusFence)
      addSubview(sequentialOwner)
      installVisibilityObservers()
    }
    return "enabled"
  }

  func disableSequentialHandoff(generation expected: Int) -> String {
    guard expected == generation else { return "session_changed" }
    guard sequentialPending == nil else { return "draining" }
    guard !sequentialOwner.isFirstResponder else { return "panel_visible" }
    if focusFence.isFirstResponder && !focusFence.resignFirstResponder() { return "focus_refused" }
    for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
    visibilityObservers.removeAll(); keyboardVisibility = .unknown
    focusFence.removeFromSuperview(); sequentialOwner.removeFromSuperview()
    sequentialEnabled = false; lastPanelOwner = nil
    return "disabled"
  }

  func setGeneration(_ next: Int) {
    if next != generation {
      cancelSequentialHandoff()
      releaseInput()
      if focusFence.isFirstResponder { _ = focusFence.resignFirstResponder() }
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
    cancelSequentialHandoff()
    releaseInput()
    inputSurface.trackOwnedChild(nil, promote: false)
    mountedChildren.removeAll { $0 === childComponentView }
    childComponentView.removeFromSuperview()
    inputSurface.trackOwnedChild(mountedChildren.count == 1 ? mountedChildren[0] : nil, promote: false)
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
    visibilityObservers.removeAll(); keyboardVisibility = .unknown
    if window == nil {
      cancelSequentialHandoff()
      removeSequentialObservers()
      sequentialPending = nil; lastPanelOwner = nil
      if sequentialOwner.isFirstResponder { _ = sequentialOwner.resignFirstResponder() }
      if focusFence.isFirstResponder { _ = focusFence.resignFirstResponder() }
      releaseInput()
    } else if sequentialEnabled {
      installVisibilityObservers()
    }
  }

  // Passive and scoped to the bound screen; no default assumption about a
  // freshly mounted view, hardware keyboard, or unobserved notifications.
  private func installVisibilityObservers() {
    let center = NotificationCenter.default
    func observe(_ name: Notification.Name, _ value: KeyboardVisibility) -> NSObjectProtocol {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard let self, let w = self.window,
              (note.object as? UIScreen) === w.screen else { return }
        self.keyboardVisibility = value
      }
    }
    visibilityObservers = [observe(UIResponder.keyboardWillShowNotification, .changing),
      observe(UIResponder.keyboardWillHideNotification, .changing),
      observe(UIResponder.keyboardDidShowNotification, .visible),
      observe(UIResponder.keyboardDidHideNotification, .hidden)]
  }

  private func sequentialOwnerDidResign() {
    guard sequentialEnabled else { return }
    if let op = sequentialPending {
      if op.toPanel && op.waitingShow && !op.cancelled { cancelSequentialHandoff() }
      return
    }
    guard let owner = lastPanelOwner else { return }
    lastPanelOwner = nil
    emitSequentialEvent(generation: owner.generation, operation: owner.operation, status: "owner_lost")
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
    guard !sequentialAbandoned else { return "handoff_abandoned" }
    guard sequentialPending == nil, !sequentialOwner.isFirstResponder else { return "input_owned_elsewhere" }
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
    guard !sequentialAbandoned else { return "handoff_abandoned" }
    guard sequentialPending == nil, !sequentialOwner.isFirstResponder else { return "input_owned_elsewhere" }
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
  // The focus fence is intentionally strict: after a hide only the window
  // itself, when provably first responder, is treated as a neutral owner.
  // An absent/blocked responder-chain action is UNKNOWN, never an empty focus.
  private func emitSequential(_ op: ETOSPendingHandoff, _ status: String) {
    emitSequentialEvent(generation: op.generation, operation: op.operation, status: status)
  }

  private func emitSequentialEvent(generation: Int, operation: Int, status: String) {
    #if DEBUG
    guard sequentialEnabled else { return }
    onSequentialHandoff(["generation": generation, "operation": operation, "status": status])
    #endif
  }

  private func removeSequentialObservers() {
    for observer in sequentialObservers { NotificationCenter.default.removeObserver(observer) }
    sequentialObservers.removeAll()
  }

  private func stopSequential(_ op: ETOSPendingHandoff, _ status: String) {
    guard sequentialPending === op else { return }
    removeSequentialObservers(); sequentialPending = nil
    if !op.emittedTerminal { op.emittedTerminal = true; emitSequential(op, status) }
    else if op.cancelled { emitSequential(op, "drained") }
  }

  // Cancel never claims focus. While a hide is in flight, quarantine this
  // instance until its real hide arrives; do not accept a second operation.
  func cancelSequentialHandoff() {
    guard let op = sequentialPending else {
      if sequentialOwner.isFirstResponder { _ = sequentialOwner.resignFirstResponder() }
      return
    }
    op.cancelled = true
    if !op.emittedTerminal { op.emittedTerminal = true; emitSequential(op, "cancelled") }
    if op.waitingShow && op.toPanel && sequentialOwner.isFirstResponder {
      // This resign itself can start a new hide. Keep the operation quarantined
      // until that hide is actually observed; do not unlock for a new request.
      op.waitingShow = false
      op.sawWillHide = false; op.sawDidHide = false; op.startingResign = true
      let resigned = sequentialOwner.resignFirstResponder()
      op.startingResign = false
      if !resigned { op.waitingShow = true; return }
      if op.sawDidHide { afterSequentialHide(op) }
    }
    // Otherwise a target show/hide can still be in progress; keep draining.

  }

  func beginSequentialHandoff(generation expected: Int, operation: Int, backing: UIView,
                              destination: Int, height: Double) -> String {
    guard !sequentialAbandoned else { return "abandoned" }
    guard sequentialEnabled else { return "unavailable" }
    guard expected == generation, expected >= 0 else { return "session_changed" }
    guard operation > highestOperation, operation <= 9_007_199_254_740_991 else { return "invalid_operation" }
    guard sequentialPending == nil else { return "busy" }
    guard let boundWindow = window, boundWindow.isKeyWindow,
          backing.window === boundWindow, sequentialOwner.window === boundWindow, focusFence.window === boundWindow,
          mountedChildren.count == 1, mountedChildren[0].superview === inputSurface else { return "targets_unavailable" }
    guard height.isFinite, height >= 1, height <= 1000 else { return "invalid_height" }
    guard (0...2).contains(destination) else { return "invalid_operation" }
    guard backing is UITextView || backing is UITextField else { return "input_unsupported" }
    if let text = backing as? UITextInput, text.markedTextRange != nil { return "composition_active" }
    guard currentInputView(backing) == nil else { return "input_owned_elsewhere" }
    let from: UIResponder = destination == 0 ? backing : sequentialOwner
    let fromKnownHidden = destination == 0 && !from.isFirstResponder
    if fromKnownHidden {
      // Debug single-window experiment for an explicit tap. This is a current
      // geometry observation, not proof that an earlier animation committed.
      guard keyboardVisibility != .visible, keyboardVisibility != .changing else { return "keyboard_state_unknown" }
      let geometry = etosKeyboardGeometry(in: boundWindow)
      guard geometry != "unavailable" else { return "keyboard_state_unknown" }
      guard geometry == "no_overlap_observed" else { return "keyboard_overlap" }
      let current = etosProvedFirstResponder(in: boundWindow)
      // A nil action result cannot distinguish empty focus from interception.
      guard current === boundWindow || current === focusFence else { return "focus_unknown" }
    } else {
      guard from.isFirstResponder else { return "focus_unknown" }
      guard etosProvedFirstResponder(in: boundWindow) === from else { return "focus_unknown" }
      // Avoid changing focus when hardware/initial visibility is unconfirmed:
      // absent events are not proof of a hidden or visible soft keyboard.
      guard keyboardVisibility == .visible else { return "keyboard_state_unknown" }
    }
    inputSurface.panelHeight = CGFloat(height)
    inputSurface.frame = CGRect(x: 0, y: 0, width: boundWindow.bounds.width, height: CGFloat(height))
    highestOperation = operation
    let op = ETOSPendingHandoff(generation: expected, operation: operation, destination: destination,
                                 window: boundWindow, backing: backing)
    sequentialPending = op
    let center = NotificationCenter.default
    sequentialObservers = [
      center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, let w = op.window,
              (note.object as? UIScreen) === w.screen else { return }
        // Only one operation is allowed; cancelled transitions remain gated.
        if !op.sawWillHide { self.emitSequential(op, "will_hide") }
        op.sawWillHide = true
      },
      center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, let w = op.window,
              (note.object as? UIScreen) === w.screen else { return }
        if op.waitingShow { self.stopSequential(op, "focus_unknown"); return }
        if !op.sawDidHide { self.emitSequential(op, "did_hide") }
        op.sawDidHide = true
        if !op.startingResign { self.afterSequentialHide(op) }
      },
      center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, let w = op.window,
              (note.object as? UIScreen) === w.screen else { return }
        if !op.loggedWillShow { op.loggedWillShow = true; self.emitSequential(op, "will_show") }
        if !op.waitingShow { self.cancelSequentialHandoff() }
      },
      center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, op.waitingShow, let w = op.window,
              (note.object as? UIScreen) === w.screen else { return }
        if !op.loggedDidShow { op.loggedDidShow = true; self.emitSequential(op, "did_show") }
        if op.cancelled { self.stopSequential(op, "cancelled"); return }
        let target: UIResponder? = op.toPanel ? self.sequentialOwner : op.backing
        guard let target, self.generation == op.generation, self.window === w,
              etosProvedFirstResponder(in: w) === target else { self.stopSequential(op, "focus_unknown"); return }
        self.stopSequential(op, "shown")
      },
      center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, let view = note.object as? UIView,
              view.window === op.window, view !== op.backing else { return }; self.cancelSequentialHandoff()
      },
      center.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self, weak op] note in
        guard let self, let op, self.sequentialPending === op, let view = note.object as? UIView,
              view.window === op.window, view !== op.backing else { return }; self.cancelSequentialHandoff()
      }
    ]
    if fromKnownHidden {
      op.startingResign = false
      op.waitingShow = true
      lastPanelOwner = (op.generation, op.operation)
      guard sequentialOwner.becomeFirstResponder() else { stopSequential(op, "focus_refused"); return "focus_refused" }
      if sequentialPending === op { emitSequential(op, "target_focused") }
      return "requested"
    }
    // One UIKit focus transfer asks the original first responder to resign.
    // Do not install the panel as the fence's inputView or call reloadInputViews.
    let fenced = focusFence.becomeFirstResponder()
    op.startingResign = false
    guard fenced, focusFence.isFirstResponder,
          etosProvedFirstResponder(in: boundWindow) === focusFence, !op.cancelled else {
      // UIKit may have already started a hide even when the focus handoff
      // fails or a synchronous interruption wins. Do not release the slot.
      cancelSequentialHandoff()
      if op.sawDidHide { afterSequentialHide(op) }
      return "unknown"
    }
    if op.sawDidHide { afterSequentialHide(op) }
    return "requested"
  }

  private func afterSequentialHide(_ op: ETOSPendingHandoff) {
    guard sequentialPending === op else { return }
    if op.cancelled {
      if op.sawWillHide && op.sawDidHide {
        if focusFence.isFirstResponder { _ = focusFence.resignFirstResponder() }
        stopSequential(op, "cancelled")
      }
      return
    }
    guard op.sawWillHide, op.sawDidHide, generation == op.generation,
          let w = op.window, window === w, let backing = op.backing,
          backing.window === w, sequentialOwner.window === w, focusFence.window === w,
          mountedChildren.count == 1, mountedChildren[0].superview === inputSurface else {
      stopSequential(op, "focus_unknown"); return
    }
    // Do not hand off if the fence lost focus to any external responder.
    guard etosProvedFirstResponder(in: w) === focusFence else {
      stopSequential(op, "focus_unknown"); return
    }
    if op.closeOnly {
      // Retain the known, non-text fence while the panel is closed. This lets a
      // later explicit open proceed without guessing an empty responder chain.
      stopSequential(op, "hidden"); return
    }
    op.waitingShow = true
    let target: UIResponder = op.toPanel ? sequentialOwner : backing
    if op.toPanel { lastPanelOwner = (op.generation, op.operation) }
    guard target.becomeFirstResponder() else { stopSequential(op, "focus_refused"); return }
    // This is not a presentation acknowledgement; didShow is still required.
    if sequentialPending === op { emitSequential(op, "target_focused") }
  }

  func cancelSequentialHandoff(generation expected: Int, operation: Int) -> String {
    guard let op = sequentialPending, op.generation == expected, op.operation == operation else { return "not_pending" }
    cancelSequentialHandoff()
    return sequentialPending === op ? "draining" : "cancelled"
  }

  // A pending no-notification/hardware-keyboard case remains unresolved.
  func inspectSequentialHandoff(generation expected: Int, operation: Int) -> String {
    guard let op = sequentialPending, op.generation == expected, op.operation == operation else { return "not_pending" }
    return op.cancelled ? "draining" : "pending_unconfirmed"
  }

  // Explicitly give up the experiment for this native instance. Never move
  // focus and never infer the state of an outstanding UIKit transition.
  func abandonSequentialHandoff(generation expected: Int, operation: Int) -> String {
    guard expected == generation, expected >= 0 else { return "session_changed" }
    guard sequentialEnabled, !sequentialAbandoned else { return "unavailable" }
    guard operation > 0,
          ((sequentialPending?.operation == operation && sequentialPending?.generation == expected) ||
           (lastPanelOwner?.operation == operation && lastPanelOwner?.generation == expected))
    else { return "not_current" }
    sequentialAbandoned = true
    sequentialEnabled = false
    sequentialPending = nil
    lastPanelOwner = nil
    removeSequentialObservers()
    for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
    visibilityObservers.removeAll()
    keyboardVisibility = .unknown
    return "abandoned"
  }

  // A diagnostic snapshot, never proof that a transition is committed.
  func sequentialSnapshot(generation expected: Int, backing: UIView) -> [String: String] {
    guard sequentialEnabled, expected == generation, let w = window,
          backing.window === w else { return ["status": "unavailable"] }
    let (current, focusProbe) = etosFocusProbe(in: w)
    let focus: String
    if current === backing { focus = "composer" }
    else if current === sequentialOwner { focus = "panel" }
    else if current === focusFence { focus = "fence" }
    else if current === w { focus = "window" }
    else if current != nil { focus = "other" }
    else { focus = "unknown" }
    let visibility: String
    switch keyboardVisibility {
    case .unknown: visibility = "unknown"
    case .changing: visibility = "changing"
    case .visible: visibility = "visible"
    case .hidden: visibility = "hidden"
    }
    // Layout is an observation, not a presentation/animation completion signal.
    let geometry = etosKeyboardGeometry(in: w)
    return ["status": "observed", "focus": focus, "focusProbe": focusProbe, "visibility": visibility, "geometry": geometry]
  }

}
