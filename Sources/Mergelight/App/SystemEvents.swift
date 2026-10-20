import AppKit
import Network

/// Wake-from-sleep and network-restored signals, delivered on the main actor. Lives as long as
/// the app, so it never unregisters.
@MainActor
final class SystemEvents {
  private var observers: [NSObjectProtocol] = []
  private let pathMonitor = NWPathMonitor()
  private var wasOnline = true

  init(onWake: @escaping @MainActor () -> Void, onNetworkRestored: @escaping @MainActor () -> Void) {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { onWake() }
      })

    pathMonitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      Task { @MainActor in
        guard let self else { return }
        let restored = online && !self.wasOnline
        self.wasOnline = online
        if restored { onNetworkRestored() }
      }
    }
    pathMonitor.start(queue: .global(qos: .utility))
  }
}
