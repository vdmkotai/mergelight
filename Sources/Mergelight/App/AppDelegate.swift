import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = AppModel()
  private var statusItem: StatusItemController?
  private var panel: PanelController?
  private var settingsWindow: SettingsWindowController?

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if isAnotherInstanceRunning() {
      NSApp.terminate(nil)
      return
    }

    let settingsWindow = SettingsWindowController(model: model)
    self.settingsWindow = settingsWindow
    let openSettings: @MainActor () -> Void = { [weak self] in
      self?.panel?.close()
      self?.settingsWindow?.show()
    }
    let panel = PanelController(model: model, onSettings: openSettings)
    self.panel = panel
    statusItem = StatusItemController(
      model: model,
      onToggle: { [weak self] in
        guard let button = self?.statusItem?.button else { return }
        self?.panel?.toggle(from: button)
      },
      onSettings: openSettings)
    model.start()

    #if DEBUG
      // Development aids: `.build/debug/Mergelight -SignInWithGitHubCLI YES -OpenPanelOnLaunch YES`.
      if UserDefaults.standard.bool(forKey: "SignInWithGitHubCLI") {
        Task { await model.signInWithGitHubCLI() }
      }
      if UserDefaults.standard.bool(forKey: "OpenPanelOnLaunch"), let button = statusItem?.button {
        Task {
          try? await Task.sleep(for: .seconds(1))
          panel.show(from: button)
        }
      }
    #endif
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.saveSettingsNow()
  }

  /// A second copy quits right away; the running one keeps its state.
  private func isAnotherInstanceRunning() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .filter { $0 != .current }
    return !others.isEmpty
  }
}
