import ExpoModulesCore
import UIKit

// Child mounting follows expo-glass-effect's GlassContainer (MIT; see
// EXPO-LICENSE). React/Fabric remains responsible for child order and layout.
public final class ETOSInputAreaView: ExpoView {
  private let childContainer = UIView()

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    childContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(childContainer)
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    childContainer.frame = bounds
  }

  public override func mountChildComponentView(_ childComponentView: UIView, index: Int) {
    childContainer.insertSubview(childComponentView, at: index)
  }

  public override func unmountChildComponentView(_ childComponentView: UIView, index: Int) {
    childComponentView.removeFromSuperview()
  }
}
