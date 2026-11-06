import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  // The close button (and ⌘W) only hides the window, so tasks keep running;
  // ⌘Q quits. The Dock icon brings it back (AppDelegate).
  override func performClose(_ sender: Any?) {
    orderOut(sender)
  }
}
