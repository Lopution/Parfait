import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // The desktop default and floor from lib/app/window/window_geometry.dart
    // (1280x800, 480x640); the saved place replaces this before the first
    // frame, as on Windows.
    self.setContentSize(NSSize(width: 1280, height: 800))
    self.contentMinSize = NSSize(width: 480, height: 640)
    self.center()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
