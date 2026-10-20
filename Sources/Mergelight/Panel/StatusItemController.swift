import AppKit
import MergelightKit
import Observation

/// The menu bar button. Re-renders only when the summary or style it shows actually changes.
@MainActor
final class StatusItemController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let model: AppModel
  private let onToggle: @MainActor () -> Void
  private let onSettings: @MainActor () -> Void
  private var rendered: NSAttributedString?

  var button: NSStatusBarButton? { item.button }

  init(
    model: AppModel, onToggle: @escaping @MainActor () -> Void,
    onSettings: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.onToggle = onToggle
    self.onSettings = onSettings
    super.init()
    if let button = item.button {
      let icon = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Mergelight")
      icon?.isTemplate = true
      button.image = icon
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(clicked)
      // On mouse down, like system menu extras.
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }
    observe()
    // Staleness depends on the clock, which Observation can't see; re-check once a minute.
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard let self else { return }
        self.render()
      }
    }
  }

  private func observe() {
    withObservationTracking {
      render()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }

  private func render() {
    guard let button = item.button else { return }
    let title = StatusTitle.make(
      summary: model.isSignedIn ? model.dashboard?.menuBar : nil, style: model.settings.menuBarStyle)
    if title != rendered {
      rendered = title
      button.attributedTitle = title
    }
    button.appearsDisabled = !model.isSignedIn || model.isStale
    button.toolTip = tooltip()
  }

  private func tooltip() -> String {
    guard model.isSignedIn else { return "Mergelight: sign in to GitHub" }
    guard let summary = model.dashboard?.menuBar else { return "Mergelight: loading…" }
    var parts = ["\(summary.total) open"]
    if summary.ready > 0 { parts.append("\(summary.ready) ready to merge") }
    if summary.attention > 0 { parts.append("\(summary.attention) need attention") }
    if summary.running > 0 { parts.append("\(summary.running) running CI") }
    if summary.reviewRequests > 0 { parts.append("\(summary.reviewRequests) review requests") }
    if let error = model.lastError { parts.append(error.localizedDescription) }
    return parts.joined(separator: "\n")
  }

  @objc private func clicked() {
    if NSApp.currentEvent?.type == .rightMouseDown {
      showMenu()
    } else {
      onToggle()
    }
  }

  private func showMenu() {
    let menu = NSMenu()
    menu.addItem(ClosureMenuItem("Refresh", key: "r") { [weak self] in self?.model.refreshNow() })
    menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.onSettings() })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem("Quit Mergelight", key: "q") { NSApp.terminate(nil) })
    item.menu = menu
    item.button?.performClick(nil)
    // Detach so the next left click opens the panel instead of the menu.
    item.menu = nil
  }
}

/// Builds the attributed menu bar title for each style.
enum StatusTitle {
  static func make(summary: MenuBarSummary?, style: AppSettings.MenuBarStyle) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let title = NSMutableAttributedString()
    func append(_ text: String, _ color: NSColor? = nil) {
      var attributes: [NSAttributedString.Key: Any] = [.font: font]
      if let color { attributes[.foregroundColor] = color }
      title.append(NSAttributedString(string: text, attributes: attributes))
    }
    func dot(_ count: Int, _ color: NSColor) {
      guard count > 0 else { return }
      if title.length > 0 { append(" ") }
      append("●", color)
      append("\(count)")
    }

    guard let summary else { return title }
    switch style {
    case .count:
      if summary.total > 0 { append("\(summary.total)") }
    case .statusCounts:
      dot(summary.ready, .systemGreen)
      dot(summary.attention, .systemRed)
      dot(summary.running, .systemOrange)
      if title.length == 0 && summary.total > 0 { append("\(summary.total)") }
    case .attentionDot:
      if summary.attention > 0 { append("●", .systemRed) }
    case .readyAndReviews:
      if summary.ready > 0 { append("\(summary.ready) ready") }
      if summary.reviewRequests > 0 {
        if title.length > 0 { append(" · ") }
        append("\(summary.reviewRequests) to review")
      }
    }
    return title
  }
}

@MainActor
final class ClosureMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: key)
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError() }

  @objc private func run() { handler() }
}
