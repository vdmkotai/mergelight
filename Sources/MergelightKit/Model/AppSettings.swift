import Foundation

/// Everything the user can configure, persisted as one JSON blob.
public struct AppSettings: Codable, Equatable, Sendable {
  public enum MenuBarStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Icon and the number of open PRs.
    case count
    /// Icon with colored ready / failing / running counters.
    case statusCounts
    /// Icon only, with a dot when something needs attention.
    case attentionDot
    /// "2 ready" plus the number of review requests.
    case readyAndReviews

    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .count: "Pull request count"
      case .statusCounts: "Ready · failing · running"
      case .attentionDot: "Icon with attention dot"
      case .readyAndReviews: "Ready to merge · review requests"
      }
    }
  }

  public enum MergeConfirmation: String, Codable, CaseIterable, Sendable, Identifiable {
    case dialog, oneClick
    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .dialog: "Always confirm in a dialog"
      case .oneClick: "Merge in one click"
      }
    }
  }

  public var sections: [SectionConfig]
  /// Login the sections were created for. Signing in as someone else regenerates the defaults,
  /// since they embed the login and the organizations.
  public var sectionsOwner: String?
  /// Seconds between background refreshes while nothing is in flight.
  public var refreshInterval: Double
  public var menuBarStyle: MenuBarStyle
  public var mergeConfirmation: MergeConfirmation
  /// nil means "use the method GitHub remembers for this repo".
  public var preferredMergeMethod: MergeMethod?
  /// Delete the head branch after merging, unless the repo already does it.
  public var deleteBranchAfterMerge: Bool
  public var showDrafts: Bool
  public var notifications: NotificationSettings
  public var collapsedSectionIDs: Set<UUID>

  public static let refreshIntervalRange: ClosedRange<Double> = 15...600

  public init(sections: [SectionConfig] = []) {
    self.sections = sections
    sectionsOwner = nil
    refreshInterval = 30
    menuBarStyle = .statusCounts
    mergeConfirmation = .dialog
    preferredMergeMethod = nil
    deleteBranchAfterMerge = true
    showDrafts = true
    notifications = NotificationSettings()
    collapsedSectionIDs = []
  }

  public init(from decoder: any Decoder) throws {
    let defaults = AppSettings()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    sections = c.value(.sections, default: defaults.sections)
    sectionsOwner = c.value(.sectionsOwner, default: defaults.sectionsOwner)
    refreshInterval = c.value(.refreshInterval, default: defaults.refreshInterval)
      .clamped(to: Self.refreshIntervalRange)
    menuBarStyle = c.value(.menuBarStyle, default: defaults.menuBarStyle)
    mergeConfirmation = c.value(.mergeConfirmation, default: defaults.mergeConfirmation)
    preferredMergeMethod = c.value(.preferredMergeMethod, default: defaults.preferredMergeMethod)
    deleteBranchAfterMerge = c.value(.deleteBranchAfterMerge, default: defaults.deleteBranchAfterMerge)
    showDrafts = c.value(.showDrafts, default: defaults.showDrafts)
    notifications = c.value(.notifications, default: defaults.notifications)
    collapsedSectionIDs = c.value(.collapsedSectionIDs, default: defaults.collapsedSectionIDs)
  }

  /// Changes that require new data from GitHub, as opposed to re-filtering what we have.
  public func requiresRefetch(comparedTo other: AppSettings) -> Bool {
    func fetchKey(_ s: AppSettings) -> [String] {
      s.sections.filter(\.isEnabled).map { "\($0.id)|\($0.effectiveQuery)" }
    }
    return fetchKey(self) != fetchKey(other)
  }

  /// Changes that move PRs between tabs or in and out of view. Diffing across such a change would
  /// report every moved PR as new or gone, so the notification baseline is reset instead.
  public func changesMembership(comparedTo other: AppSettings) -> Bool {
    func key(_ s: AppSettings) -> [String] {
      s.sections.filter(\.isEnabled).map { "\($0.id)|\($0.effectiveQuery)|\($0.tab.rawValue)" }
        + ["drafts=\(s.showDrafts)"]
    }
    return key(self) != key(other)
  }
}

public struct NotificationSettings: Codable, Equatable, Sendable {
  public var ciFailed = true
  public var ciPassed = true
  public var approved = true
  public var changesRequested = true
  public var conflicts = true
  public var merged = true
  public var reviewRequested = true

  public init() {}

  public var anyEnabled: Bool {
    ciFailed || ciPassed || approved || changesRequested || conflicts || merged || reviewRequested
  }

  public init(from decoder: any Decoder) throws {
    let defaults = NotificationSettings()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ciFailed = c.value(.ciFailed, default: defaults.ciFailed)
    ciPassed = c.value(.ciPassed, default: defaults.ciPassed)
    approved = c.value(.approved, default: defaults.approved)
    changesRequested = c.value(.changesRequested, default: defaults.changesRequested)
    conflicts = c.value(.conflicts, default: defaults.conflicts)
    merged = c.value(.merged, default: defaults.merged)
    reviewRequested = c.value(.reviewRequested, default: defaults.reviewRequested)
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
