import AppKit
import SwiftUI

/// Hosts the settings in a regular window. While it's open the app shows in the Dock and the app
/// switcher, like any window you can Cmd-Tab back to.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private var window: NSWindow?

  init(model: AppModel) {
    self.model = model
  }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
    window.title = "Mergelight Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    return window
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
