import ExpoModulesCore
import UIKit

public final class ETOSInputAreaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ETOSInputArea")
    View(ETOSInputAreaView.self) {}
    View(ETOSKeyboardPanelView.self) {
      ViewName("KeyboardPanel")
      Prop("scopeGeneration") { (view: ETOSKeyboardPanelView, value: Int) in
        view.setGeneration(value)
      }
    }

    AsyncFunction("requestKeyboardPanel") { (hostTag: Int, panelTag: Int, inputTag: Int, generation: Int, panel: Bool, height: Double) -> String in
      guard let context = self.appContext,
            let host = context.findView(withTag: hostTag, ofType: ETOSInputAreaView.self),
            let panelView = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self),
            let input = context.findView(withTag: inputTag, ofType: UIView.self),
            host.window != nil, panelView.isDescendant(of: host), input.isDescendant(of: host),
            NSStringFromClass(type(of: input)) == "RCTTextInputComponentView" else { return "targets_unavailable" }
      let candidates = input.subviews.filter { $0 is UITextView || $0 is UITextField }
      guard candidates.count == 1, let backing = candidates.first else { return "input_unsupported" }
      return panelView.switchMode(generation: generation, backing: backing, panel: panel, height: height)
    }.runOnQueue(.main)

    AsyncFunction("dismissKeyboardPanel") { (hostTag: Int, panelTag: Int, inputTag: Int, generation: Int) -> String in
      guard let context = self.appContext,
            let host = context.findView(withTag: hostTag, ofType: ETOSInputAreaView.self),
            let panelView = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self),
            let input = context.findView(withTag: inputTag, ofType: UIView.self),
            host.window != nil, panelView.isDescendant(of: host), input.isDescendant(of: host),
            NSStringFromClass(type(of: input)) == "RCTTextInputComponentView" else { return "targets_unavailable" }
      let candidates = input.subviews.filter { $0 is UITextView || $0 is UITextField }
      guard candidates.count == 1, let backing = candidates.first else { return "input_unsupported" }
      return panelView.dismiss(generation: generation, backing: backing)
    }.runOnQueue(.main)

    // A one-shot, read-only feasibility probe. No view is retained or bound.
    AsyncFunction("probeTargets") { (hostTag: Int, scrollTag: Int, inputTag: Int) -> [String: Any] in
      guard hostTag > 0, scrollTag > 0, inputTag > 0,
            let context = self.appContext,
            let host = context.findView(withTag: hostTag, ofType: ETOSInputAreaView.self),
            let window = host.window else { return ["status": "host_unavailable"] }
      guard let input = context.findView(withTag: inputTag, ofType: UIView.self),
            NSStringFromClass(type(of: input)) == "RCTTextInputComponentView",
            input.isDescendant(of: host), input.window === window else {
        return ["status": "input_unsupported"]
      }
      let inputs = input.subviews.filter { $0 is UITextView || $0 is UITextField }
      guard inputs.count == 1, let backing = inputs.first else {
        return ["status": "input_unsupported"]
      }
      guard let scrollHost = context.findView(withTag: scrollTag, ofType: UIView.self),
            NSStringFromClass(type(of: scrollHost)) == "RCTScrollViewComponentView",
            scrollHost.window === window else { return ["status": "scroll_unsupported"] }
      let scrolls = scrollHost.subviews.compactMap { $0 as? UIScrollView }
      guard scrolls.count == 1, let scroll = scrolls.first, scroll.window === window else {
        return ["status": "scroll_unsupported"]
      }
      var hasKCSVAncestor = false
      var ancestor: UIView? = scrollHost
      while let view = ancestor {
        if NSStringFromClass(type(of: view)).contains("ClippingScrollViewDecoratorView") {
          hasKCSVAncestor = true
          break
        }
        ancestor = view.superview
      }
      return [
        "status": "observed",
        "inputFocused": backing.isFirstResponder,
        "scrollInteracting": scroll.isTracking || scroll.isDragging || scroll.isDecelerating,
        "kcsvAncestor": hasKCSVAncestor
      ]
    }.runOnQueue(.main)
  }
}
