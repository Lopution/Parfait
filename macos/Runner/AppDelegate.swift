import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override init() {
    super.init()
    self.addApplicationLifecycleDelegate(MacosIntentBridge.shared)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
