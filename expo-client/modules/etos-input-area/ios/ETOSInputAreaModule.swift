import ExpoModulesCore
import ImageIO
import UIKit

private let stickerOpacityQueue = DispatchQueue(label: "run.lamplit.etos.sticker-opacity", qos: .utility)

// JS rejects animation and enforces the same bounds before calling this method.
// ImageIO independently verifies type, dimensions and a completely decoded frame.
private func classifyStaticImageOpacity(_ data: Data, _ contentType: String, _ width: Int, _ height: Int) -> String {
  let types = ["image/png": "public.png", "image/jpeg": "public.jpeg", "image/webp": "org.webmproject.webp"]
  guard let expected = types[contentType], !data.isEmpty, data.count <= 8_000_000,
        width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 4_000_000,
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let sourceType = CGImageSourceGetType(source) as String?, sourceType == expected,
        CGImageSourceGetCount(source) == 1,
        CGImageSourceGetStatus(source) == .statusComplete,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
        (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == width,
        (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == height,
        let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
        image.width == width, image.height == height else { return "unknown" }
  var bytes = Data(count: width * height * 4)
  return bytes.withUnsafeMutableBytes { buffer -> String in
    guard let address = buffer.baseAddress,
          let color = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: address, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: color,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return "unknown" }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    let pixels = buffer.bindMemory(to: UInt8.self)
    for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] != 255 { return "transparent" }
    return "opaque"
  }
}

public final class ETOSInputAreaModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ETOSInputArea")
    AsyncFunction("classifyStaticImageOpacity") { (data: Data, contentType: String, width: Int, height: Int) -> String in
      classifyStaticImageOpacity(data, contentType, width, height)
    }.runOnQueue(stickerOpacityQueue)
    View(ETOSInputAreaView.self) {}
    // Availability is not activation; every panel must explicitly opt in.
    Function("supportsSequentialHandoff") {
      #if DEBUG
      return true
      #else
      return false
      #endif
    }
    View(ETOSKeyboardPanelView.self) {
      ViewName("KeyboardPanel")
      Events("onSequentialHandoff")
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

    AsyncFunction("enableSequentialHandoff") { (panelTag: Int, generation: Int) -> String in
      #if DEBUG
      guard let panel = self.appContext?.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self) else { return "targets_unavailable" }
      return panel.enableSequentialHandoff(generation: generation)
      #else
      return "unavailable"
      #endif
    }.runOnQueue(.main)

    AsyncFunction("disableSequentialHandoff") { (panelTag: Int, generation: Int) -> String in
      #if DEBUG
      guard let panel = self.appContext?.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self) else { return "targets_unavailable" }
      return panel.disableSequentialHandoff(generation: generation)
      #else
      return "unavailable"
      #endif
    }.runOnQueue(.main)

    AsyncFunction("beginSequentialHandoff") { (hostTag: Int, panelTag: Int, inputTag: Int, generation: Int, operation: Int, destination: Int, height: Double) -> String in
      #if DEBUG
      guard let context = self.appContext,
            let host = context.findView(withTag: hostTag, ofType: ETOSInputAreaView.self),
            let panel = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self),
            let input = context.findView(withTag: inputTag, ofType: UIView.self),
            host.window != nil, panel.isDescendant(of: host), input.isDescendant(of: host),
            NSStringFromClass(type(of: input)) == "RCTTextInputComponentView" else { return "targets_unavailable" }
      let candidates = input.subviews.filter { $0 is UITextView || $0 is UITextField }
      guard candidates.count == 1, let backing = candidates.first else { return "input_unsupported" }
      return panel.beginSequentialHandoff(generation: generation, operation: operation, backing: backing, destination: destination, height: height)
      #else
      return "unavailable"
      #endif
    }.runOnQueue(.main)

    AsyncFunction("snapshotSequentialHandoff") { (hostTag: Int, panelTag: Int, inputTag: Int, generation: Int) -> [String: String] in
      #if DEBUG
      guard let context = self.appContext,
            let host = context.findView(withTag: hostTag, ofType: ETOSInputAreaView.self),
            let panel = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self),
            let input = context.findView(withTag: inputTag, ofType: UIView.self),
            host.window != nil, panel.isDescendant(of: host), input.isDescendant(of: host),
            NSStringFromClass(type(of: input)) == "RCTTextInputComponentView" else { return ["status": "unavailable"] }
      let candidates = input.subviews.filter { $0 is UITextView || $0 is UITextField }
      guard candidates.count == 1, let backing = candidates.first else { return ["status": "unavailable"] }
      return panel.sequentialSnapshot(generation: generation, backing: backing)
      #else
      return ["status": "unavailable"]
      #endif
    }.runOnQueue(.main)

    AsyncFunction("cancelSequentialHandoff") { (panelTag: Int, generation: Int, operation: Int) -> String in
      guard let context = self.appContext,
            let panel = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self) else { return "not_pending" }
      return panel.cancelSequentialHandoff(generation: generation, operation: operation)
    }.runOnQueue(.main)

    AsyncFunction("inspectSequentialHandoff") { (panelTag: Int, generation: Int, operation: Int) -> String in
      guard let context = self.appContext,
            let panel = context.findView(withTag: panelTag, ofType: ETOSKeyboardPanelView.self) else { return "not_pending" }
      return panel.inspectSequentialHandoff(generation: generation, operation: operation)
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
