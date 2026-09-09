import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
    private var terminationWasRequested = false;

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      // RustDesk keeps its connection manager alive while its main window is
      // hidden. AppKit may otherwise treat the window-less menu-bar process as
      // idle and terminate it automatically.
      if terminationWasRequested {
          return .terminateNow
      }
      NSLog("[RustDesk] Ignoring automatic termination while the service is active")
      return .terminateCancel
  }

  func terminateForUserRequest() {
      terminationWasRequested = true
      NSApplication.shared.terminate(self)
  }

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
        // RustDesk is a menu-bar application and intentionally has periods
        // without a visible window. Keep AppKit from terminating the process
        // during those periods while the tray/IPC service is still active.
        ProcessInfo.processInfo.disableAutomaticTermination("RustDesk menu bar service")
        NSApplication.shared.activate(ignoringOtherApps: true);
    }
}
