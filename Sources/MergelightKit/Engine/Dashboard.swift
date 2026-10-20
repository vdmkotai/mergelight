import Foundation

/// Raw result of one dashboard refresh, exactly as GitHub returned it.
///
/// This is what gets cached to disk. Everything the UI shows is derived from it by
/// `Dashboard.init(fetch:configs:...)`, so display settings apply without another request.
public struct DashboardFetch: Codable, Sendable, Equatable {
  public var viewerLogin: String
  /// Last time PR fields were refreshed (full or status refresh).
  public var fetchedAt: Date
  /// Last time section membership was searched (full refresh only).
  public var searchedAt: Date
  public var rateLimit: RateLimit?
  public var results: [UUID: SectionResult]

  public init(
    viewerLogin: String, fetchedAt: Date, searchedAt: Date? = nil, rateLimit: RateLimit?,
    results: [UUID: SectionResult]
  ) {
    self.viewerLogin = viewerLogin
    self.fetchedAt = fetchedAt
    self.searchedAt = searchedAt ?? fetchedAt
    self.rateLimit = rateLimit
    self.results = results
  }

  /// Keeps the last good PR list of a section whose search failed in this fetch.
  ///
  /// GitHub search times out now and then. Without this, the section would flash empty, the menu
  /// bar count would dip, and the next good fetch would look like a wave of new PRs.
  public func carryingOver(from previous: DashboardFetch?) -> DashboardFetch {
    guard let previous else { return self }
    var merged = self
    for (id, result) in results where result.error != nil {
      guard let old = previous.results[id], old.query == result.query else { continue }
      merged.results[id]?.pullRequests = old.pullRequests
      merged.results[id]?.totalCount = old.totalCount
    }
    return merged
  }

  /// Every PR across sections, once.
  public var uniquePullRequestIDs: [String] {
    var seen = Set<String>()
    return results.values.flatMap(\.pullRequests).map(\.id).filter { seen.insert($0).inserted }
  }
}

public struct SectionResult: Codable, Sendable, Equatable {
  /// The effective query this result answers; a stale result is dropped once the query changes.
  public var query: String
  public var pullRequests: [PullRequest]
  /// GitHub's total match count, which can exceed the page we fetched.
  public var totalCount: Int
  public var error: String?
}

public struct RateLimit: Codable, Sendable, Equatable {
  public var remaining: Int
  public var limit: Int
  public var resetAt: Date
  public var cost: Int
}

/// What the panel and the menu bar render.
public struct Dashboard: Sendable, Equatable {
  public struct Section: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let color: SectionColor
    public let tab: SectionConfig.Tab
    public let pullRequests: [PullRequest]
    /// Matches GitHub has beyond the fetched page.
    public let moreCount: Int
    public let error: String?
    /// No result for the current query yet (new or edited section).
    public let isLoading: Bool
    public let hideWhenEmpty: Bool
    public let countsInMenuBar: Bool
    public let webSearchURL: URL

    public var isVisible: Bool {
      !(hideWhenEmpty && pullRequests.isEmpty && error == nil && !isLoading)
    }

    public var summary: SectionSummary { SectionSummary(pullRequests) }

    /// The same section showing only `pullRequests`, e.g. the matches of a text filter.
    public func filtered(to pullRequests: [PullRequest]) -> Section {
      Section(
        id: id, name: name, color: color, tab: tab, pullRequests: pullRequests, moreCount: 0,
        error: nil, isLoading: false, hideWhenEmpty: hideWhenEmpty, countsInMenuBar: countsInMenuBar,
        webSearchURL: webSearchURL)
    }
  }

  public let viewerLogin: String
  public let fetchedAt: Date
  public let rateLimit: RateLimit?
  public let sections: [Section]

  /// Derives the visible dashboard.
  ///
  /// - Only open PRs survive. GitHub's search index lags a merge by up to a minute, but the node
  ///   fields it returns are live, so a PR merged in the browser drops out on the next refresh.
  /// - `excluding` hides PRs this app just merged or closed, before GitHub catches up.
  /// - Within a tab, a PR shows only in the first section that matched it.
  public init(
    fetch: DashboardFetch, configs: [SectionConfig], excluding: Set<String> = [],
    showDrafts: Bool = true
  ) {
    var seen: [SectionConfig.Tab: Set<String>] = [:]
    sections = configs.filter(\.isEnabled).map { config in
      let result = fetch.results[config.id].flatMap { $0.query == config.effectiveQuery ? $0 : nil }
      var pullRequests: [PullRequest] = []
      for pr in result?.pullRequests ?? [] {
        guard pr.state == .open, !excluding.contains(pr.id), showDrafts || !pr.isDraft else {
          continue
        }
        guard seen[config.tab, default: []].insert(pr.id).inserted else { continue }
        pullRequests.append(pr)
      }
      return Section(
        id: config.id,
        name: config.name,
        color: config.color,
        tab: config.tab,
        pullRequests: pullRequests,
        moreCount: result.map { max(0, $0.totalCount - $0.pullRequests.count) } ?? 0,
        error: result?.error,
        isLoading: result == nil,
        hideWhenEmpty: config.hideWhenEmpty,
        countsInMenuBar: config.countsInMenuBar,
        webSearchURL: config.webSearchURL)
    }
    viewerLogin = fetch.viewerLogin
    fetchedAt = fetch.fetchedAt
    rateLimit = fetch.rateLimit
  }

  public func sections(in tab: SectionConfig.Tab) -> [Section] {
    sections.filter { $0.tab == tab }
  }

  /// Unique PRs per tab, for diffing and counting.
  public func pullRequests(in tab: SectionConfig.Tab) -> [PullRequest] {
    sections(in: tab).flatMap(\.pullRequests)
  }

  public var menuBar: MenuBarSummary { MenuBarSummary(self) }

  /// True while something is changing on GitHub's side, so refreshing sooner pays off.
  public var hasActivity: Bool {
    sections.contains { section in
      section.pullRequests.contains { pr in
        // Auto-merge alone isn't activity: it can wait days for a review.
        pr.ci.rollup == .pending || pr.merge.mergeable == .unknown
      }
    }
  }
}

public struct SectionSummary: Equatable, Sendable {
  public let ready: Int
  public let failing: Int
  public let running: Int

  init(_ pullRequests: [PullRequest]) {
    ready = pullRequests.count { $0.readiness == .ready }
    failing = pullRequests.count { $0.ci.rollup == .failure }
    running = pullRequests.count { $0.ci.rollup == .pending }
  }

  public var text: String {
    var parts: [String] = []
    if ready > 0 { parts.append("\(ready) ready") }
    if failing > 0 { parts.append("\(failing) failing") }
    if running > 0 { parts.append("\(running) running") }
    return parts.joined(separator: " · ")
  }
}

/// Numbers for the status item.
public struct MenuBarSummary: Equatable, Sendable {
  /// Open PRs in sections that count toward the menu bar.
  public let total: Int
  public let ready: Int
  /// Failed CI, requested changes or conflicts.
  public let attention: Int
  public let running: Int
  public let reviewRequests: Int

  public init(total: Int, ready: Int, attention: Int, running: Int, reviewRequests: Int) {
    self.total = total
    self.ready = ready
    self.attention = attention
    self.running = running
    self.reviewRequests = reviewRequests
  }

  init(_ dashboard: Dashboard) {
    var ids = Set<String>()
    var counted: [PullRequest] = []
    for section in dashboard.sections where section.countsInMenuBar {
      for pr in section.pullRequests where ids.insert(pr.id).inserted { counted.append(pr) }
    }
    total = counted.count
    ready = counted.count { $0.readiness == .ready }
    attention = counted.count { $0.ci.rollup == .failure || $0.readiness.needsAttention }
    running = counted.count { $0.ci.rollup == .pending }
    reviewRequests = Set(dashboard.pullRequests(in: .review).map(\.id)).count
  }
}
