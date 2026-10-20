import AppKit
import SwiftUI

/// The dropdown under the status item: a borderless, non-activating panel hosting SwiftUI.
///
/// The hosting view is created once and kept alive, so reopening is instant and scroll position
/// and hover state survive. The panel follows the SwiftUI content's size.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private let panel: MenuPanel
  private var outsideClickMonitor: Any?
  private var lastClosed = Date.distantPast
  private weak var anchor: NSStatusBarButton?

  init(model: AppModel, onSettings: @escaping @MainActor () -> Void) {
    self.model = model
    panel = MenuPanel()
    super.init()

    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true

    let root = PanelView(
      model: model, onSettings: onSettings,
      onSizeChange: { [weak self] size in self?.contentSizeChanged(size) })
    let hosting = NSHostingView(rootView: root)
    hosting.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: effect.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
    ])
    panel.contentView = effect
    panel.delegate = self
    panel.onEscape = { [weak self] in
      guard let self else { return }
      if self.model.mergeDraft != nil {
        self.model.mergeDraft = nil
      } else {
        self.close()
      }
    }
  }

  var isVisible: Bool { panel.isVisible }

  func toggle(from button: NSStatusBarButton) {
    // A click on the status item first resigns the panel (closing it), then lands here.
    if isVisible {
      close()
    } else if Date.now.timeIntervalSince(lastClosed) > 0.25 {
      show(from: button)
    }
  }

  func show(from button: NSStatusBarButton) {
    guard !panel.isVisible else { return }
    anchor = button
    if let window = button.window, let screen = window.screen ?? NSScreen.main {
      let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
      model.panelMaxHeight = max(320, buttonFrame.minY - 6 - screen.visibleFrame.minY - 8)
    }
    reposition(size: panel.frame.size)
    button.highlight(true)
    panel.makeKeyAndOrderFront(nil)
    model.panelVisible = true

    outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
  }

  func close() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
    anchor?.highlight(false)
    lastClosed = .now
    model.panelVisible = false
    model.mergeDraft = nil
    if let monitor = outsideClickMonitor {
      NSEvent.removeMonitor(monitor)
      outsideClickMonitor = nil
    }
  }

  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  private func contentSizeChanged(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
    guard rounded != panel.frame.size else { return }
    reposition(size: rounded)
  }

  /// Pins the panel's top edge under the status item and keeps it on screen.
  private func reposition(size: CGSize) {
    guard let button = anchor, let window = button.window else {
      panel.setContentSize(size)
      return
    }
    let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
    var x = buttonFrame.midX - size.width / 2
    x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
    let y = max(buttonFrame.minY - 6 - size.height, visible.minY)
    panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    panel.invalidateShadow()
  }
}

final class MenuPanel: NSPanel {
  var onEscape: (() -> Void)?

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .statusBar
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    animationBehavior = .utilityWindow
  }

  override var canBecomeKey: Bool { true }

  override func cancelOperation(_ sender: Any?) { onEscape?() }
}
