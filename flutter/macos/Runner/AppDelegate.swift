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
        // Sense Remote (H5, MAC-SONRA-15): the Sense icon stays above the maintenance curtain.
        SenseCurtainIcon.shared.start()
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

// Sense Remote (H5, MAC-SONRA-15): the connection must stay visible on the controlled computer
// (workshop CLAUDE.md, Security). The maintenance curtain of ghost mode (`src/sense/curtain_mac.mm`,
// in the `--server` process) covers every screen one level below this; while it is up it posts
// `SenseRemoteCurtain` "on" every second, and "off" at the end. The connection manager (`--cm`)
// then lifts its always-on-top windows (the Sense icon and its card) above the curtain, and puts
// them back when the curtain is gone, or when no "on" came for 3 seconds (server stopped).
//
// Sürüm 11 (tarama-mac M10): every window of the connection manager goes above the curtain,
// whatever its level (a card window_manager put back to "normal" stayed under it), and gets its
// own level back afterwards. An "off" note is only a hint: any process of the session can post
// it, so it puts the windows back only when no "on" came for `offAfter` (the curtain sends "on"
// every second while it is up); otherwise the 3-second rule decides.
final class SenseCurtainIcon {
    static let shared = SenseCurtainIcon()
    private static let noteName = Notification.Name("SenseRemoteCurtain")
    /// The curtain's level (`kCGPopUpMenuWindowLevelKey`) + 1.
    private static let aboveCurtain = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    /// An "off" counts only after this long without an "on" (the curtain sends one per second).
    private static let offAfter: TimeInterval = 1.5
    private var lastOn = Date.distantPast
    private var timer: Timer?
    private var started = false
    /// Level of each lifted window before it was lifted (by window number).
    private var levels: [Int: NSWindow.Level] = [:]

    func start() {
        guard !started, CommandLine.arguments.dropFirst().first == "--cm" else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: SenseCurtainIcon.noteName, object: nil, queue: .main
        ) { [weak self] note in
            self?.update(on: (note.object as? String) == "on")
        }
    }

    private func update(on: Bool) {
        guard on else {
            if Date().timeIntervalSince(lastOn) > SenseCurtainIcon.offAfter {
                restore()
            }
            return
        }
        lastOn = Date()
        lift()
        if timer == nil {
            // window_manager may set "always on top" (floating) again: re-apply meanwhile.
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        if Date().timeIntervalSince(lastOn) > 3 {
            restore()
        } else {
            lift()
        }
    }

    private func lift() {
        for window in NSApplication.shared.windows where window.level != SenseCurtainIcon.aboveCurtain {
            if levels[window.windowNumber] == nil {
                levels[window.windowNumber] = window.level
            }
            window.level = SenseCurtainIcon.aboveCurtain
        }
    }

    private func restore() {
        timer?.invalidate()
        timer = nil
        for window in NSApplication.shared.windows where window.level == SenseCurtainIcon.aboveCurtain {
            window.level = levels[window.windowNumber] ?? .floating
        }
        levels.removeAll()
    }
}
