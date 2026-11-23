import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      dummy_method_to_enforce_bundling()
    // https://github.com/leanflutter/window_manager/issues/214
    return false
  }
    
    override func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if (launched) {
            handle_applicationShouldOpenUntitledFile();
        }
        return true
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        launched = true;
        NSApplication.shared.activate(ignoringOtherApps: true);
    }

    // Sense Remote (D3f): the app menu's "Sense Remote Hakkında" opens the Sense About page in
    // the main window (Dart: `sense/platform/sense_mac_menu.dart`), not the standard panel.
    @IBAction func senseShowAbout(_ sender: Any?) {
        guard let window = NSApplication.shared.windows.first(where: { $0 is MainFlutterWindow }),
              let controller = window.contentViewController as? FlutterViewController else {
            return
        }
        FlutterMethodChannel(
            name: "org.rustdesk.rustdesk/sense_menu",
            binaryMessenger: controller.engine.binaryMessenger
        ).invokeMethod("showAbout", arguments: nil)
    }
}
