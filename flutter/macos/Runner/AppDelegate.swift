import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    var launched = false;
    private var terminationWasRequested = false;

  private var isConnectionManagerLaunch: Bool {
      CommandLine.arguments.dropFirst().contains { argument in
          argument == "--cm" || argument == "--cm-no-ui"
      }
  }

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

  func terminateForUserRequest(stopService: Bool = true) {
      if stopService {
          stopBackgroundService()
      }
      terminationWasRequested = true
      NSApplication.shared.terminate(self)
  }

  private func stopBackgroundService() {
      guard let executablePath = Bundle.main.executablePath else {
          NSLog("[RustDesk] Cannot locate the app executable to stop the background service")
          return
      }
      let task = Process()
      task.executableURL = URL(fileURLWithPath: executablePath)
      task.arguments = ["--quit-service"]
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      do {
          try task.run()
      } catch {
          NSLog("[RustDesk] Failed to stop the background service: %@", error.localizedDescription)
      }
  }

  // The standard NSApplication `terminate:` action is also used by AppKit's
  // automatic-termination path.  This app deliberately cancels that automatic
  // path while its menu-bar/service process is alive, so the Quit menu item
  // must call an explicit user-request action instead.  Otherwise Command-Q
  // is silently cancelled and the foreground app appears impossible to close.
  @IBAction func terminateApplication(_ sender: Any?) {
      terminateForUserRequest()
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
        // A hidden connection manager is started by --server in the user's
        // session. Activating it here moves the user to RustDesk's Space even
        // though its window is immediately hidden. The visible management UI
        // still explicitly focuses itself from Dart when the user opens it.
        if !isConnectionManagerLaunch {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
