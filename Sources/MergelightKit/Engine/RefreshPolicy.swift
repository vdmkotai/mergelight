import Foundation

/// Decides when the next background refresh happens and what kind it is.
///
/// Two kinds keep the menu bar count honest without burning API budget:
/// - a *status* refresh re-reads known PRs (one or two cheap requests). Merges, closes, CI and
///   reviews show up here, because node state is live while search results lag.
/// - a *full* refresh also re-runs every section's search, to discover new PRs and review requests.
///   It runs every `searchInterval`, on demand, and whenever the panel opens on old data.
public struct RefreshPolicy: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case full, status
  }

  /// Cadence while the panel is open: what you look at should be fresh.
  public static let visibleInterval: TimeInterval = 10
  /// Cadence while CI runs or mergeability is being computed.
  public static let activeInterval: TimeInterval = 15
  public static let maxBackoff: TimeInterval = 300
  /// Below this many remaining points, wait for the window to reset.
  public static let rateLimitFloor = 50

  public var baseInterval: TimeInterval

  public init(baseInterval: TimeInterval) {
    self.baseInterval = baseInterval
  }

  /// How long section membership may go unsearched in the background.
  public var searchInterval: TimeInterval { max(baseInterval * 2, 60) }

  /// Membership older than this is refreshed when the panel opens.
  public static let searchStalenessOnOpen: TimeInterval = 20
  /// Statuses older than this are refreshed when the panel opens.
  public static let statusStalenessOnOpen: TimeInterval = 5

  public func kind(searchedAt: Date?, now: Date = .now) -> Kind {
    guard let searchedAt else { return .full }
    return now.timeIntervalSince(searchedAt) >= searchInterval ? .full : .status
  }

  /// What to do when the user opens the panel, if anything.
  public func kindOnPanelOpen(searchedAt: Date?, fetchedAt: Date?, now: Date = .now) -> Kind? {
    guard let searchedAt, let fetchedAt else { return .full }
    if now.timeIntervalSince(searchedAt) >= Self.searchStalenessOnOpen { return .full }
    if now.timeIntervalSince(fetchedAt) >= Self.statusStalenessOnOpen { return .status }
    return nil
  }

  public func nextDelay(
    hasActivity: Bool, panelVisible: Bool, consecutiveFailures: Int, rateLimit: RateLimit?,
    now: Date = .now
  ) -> TimeInterval {
    if let rateLimit, rateLimit.remaining < Self.rateLimitFloor {
      return max(rateLimit.resetAt.timeIntervalSince(now) + 5, baseInterval)
    }
    if consecutiveFailures > 0 {
      let exponent = Double(min(consecutiveFailures - 1, 6))
      return min(max(baseInterval, 15) * pow(2, exponent), max(Self.maxBackoff, baseInterval))
    }
    var delay = baseInterval
    if hasActivity { delay = min(delay, Self.activeInterval) }
    if panelVisible { delay = min(delay, Self.visibleInterval) }
    return delay
  }
}
