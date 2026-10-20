import Foundation
import Testing

@testable import MergelightKit

@Suite struct DashboardTests {
  let work = SectionConfig(name: "Work", color: .blue, query: "org:acme")
  let all = SectionConfig(name: "All", color: .gray, query: "author:@me", hideWhenEmpty: true)
  let review = SectionConfig(name: "Review", color: .yellow, query: "review-requested:@me", tab: .review)

  func fetch(_ results: [SectionConfig: [PullRequest]], total: Int? = nil) -> DashboardFetch {
    DashboardFetch(
      viewerLogin: "octo", fetchedAt: .distantPast, rateLimit: nil,
      results: Dictionary(uniqueKeysWithValues: results.map { config, prs in
        (config.id, SectionResult(query: config.effectiveQuery, pullRequests: prs, totalCount: total ?? prs.count))
      }))
  }

  @Test func firstMatchingSectionWinsWithinATab() {
    let a = PullRequest.make(id: "a")
    let b = PullRequest.make(id: "b")
    let dashboard = Dashboard(fetch: fetch([work: [a], all: [a, b], review: [a]]), configs: [work, all, review])
    #expect(dashboard.sections.map { $0.pullRequests.map(\.id) } == [["a"], ["b"], ["a"]],
      "dedup is per tab: a PR can be mine and awaiting my review at once")
  }

  @Test func dropsClosedExcludedAndOptionallyDrafts() {
    let prs = [
      PullRequest.make(id: "open"), .make(id: "merged", state: .merged), .make(id: "closed", state: .closed),
      .make(id: "mergedHere"), .make(id: "draft", isDraft: true),
    ]
    let withDrafts = Dashboard(fetch: fetch([work: prs]), configs: [work], excluding: ["mergedHere"])
    #expect(withDrafts.sections[0].pullRequests.map(\.id) == ["open", "draft"])
    let noDrafts = Dashboard(fetch: fetch([work: prs]), configs: [work], excluding: ["mergedHere"], showDrafts: false)
    #expect(noDrafts.sections[0].pullRequests.map(\.id) == ["open"])
  }

  @Test func staleResultsForEditedQueriesAreIgnored() {
    var edited = work
    edited.query = "org:initech"
    let dashboard = Dashboard(fetch: fetch([work: [.make()]]), configs: [edited])
    #expect(dashboard.sections[0].isLoading)
    #expect(dashboard.sections[0].pullRequests.isEmpty)
  }

  @Test func visibilityAndMoreCount() {
    let dashboard = Dashboard(fetch: fetch([work: [.make()], all: []], total: 51), configs: [work, all])
    #expect(dashboard.sections[0].moreCount == 50)
    #expect(dashboard.sections[0].isVisible)
    #expect(!dashboard.sections[1].isVisible, "empty section with hideWhenEmpty")

    var disabled = all
    disabled.isEnabled = false
    #expect(Dashboard(fetch: fetch([work: []]), configs: [work, disabled]).sections.count == 1)
  }

  @Test func failedSearchKeepsPreviousPullRequests() {
    let previous = fetch([work: [.make(id: "a"), .make(id: "b")], all: [.make(id: "c")]])
    var current = fetch([work: [], all: [.make(id: "d")]])
    current.results[work.id]?.error = "Timeout"
    current.results[work.id]?.totalCount = 0
    let merged = current.carryingOver(from: previous)
    #expect(merged.results[work.id]?.pullRequests.map(\.id) == ["a", "b"])
    #expect(merged.results[work.id]?.totalCount == 2)
    #expect(merged.results[work.id]?.error == "Timeout", "the error still shows")
    #expect(merged.results[all.id]?.pullRequests.map(\.id) == ["d"], "healthy sections take new data")

    var edited = work
    edited.query = "org:initech"
    var otherQuery = fetch([edited: []])
    otherQuery.results[edited.id]?.error = "Timeout"
    #expect(otherQuery.carryingOver(from: previous).results[edited.id]?.pullRequests.isEmpty == true,
      "results for a different query are never carried over")
  }

  @Test func menuBarSummaryCountsUniquePullRequests() {
    let ready = PullRequest.make(id: "ready", ci: .passing(3))
    let failing = PullRequest.make(id: "failing", status: .blocked, ci: .failing(1, of: 3))
    let running = PullRequest.make(id: "running", status: .blocked, ci: .running(1, of: 3))
    let conflicted = PullRequest.make(id: "conflicted", mergeable: .conflicting, status: .dirty)
    let toReview = PullRequest.make(id: "review")
    var hidden = all
    hidden.countsInMenuBar = false
    let dashboard = Dashboard(
      fetch: fetch([work: [ready, failing, running], hidden: [conflicted], review: [toReview, ready]]),
      configs: [work, hidden, review])

    #expect(dashboard.menuBar == MenuBarSummary(total: 3, ready: 1, attention: 1, running: 1, reviewRequests: 2))
    #expect(dashboard.hasActivity)
    #expect(dashboard.sections[0].summary.text == "1 ready · 1 failing · 1 running")
  }
}

@Suite struct SnapshotDiffTests {
  let mine = SectionConfig(name: "Mine", color: .blue, query: "author:@me")
  let review = SectionConfig(name: "Review", color: .yellow, query: "review-requested:@me", tab: .review)

  func dashboard(mine minePRs: [PullRequest], review reviewPRs: [PullRequest] = []) -> Dashboard {
    let results = [
      mine.id: SectionResult(query: mine.effectiveQuery, pullRequests: minePRs, totalCount: minePRs.count),
      review.id: SectionResult(query: review.effectiveQuery, pullRequests: reviewPRs, totalCount: reviewPRs.count),
    ]
    return Dashboard(
      fetch: DashboardFetch(viewerLogin: "octo", fetchedAt: .now, rateLimit: nil, results: results),
      configs: [mine, review])
  }

  func events(_ old: [PullRequest], _ new: [PullRequest]) -> [PullRequestEvent] {
    SnapshotDiff.events(from: dashboard(mine: old), to: dashboard(mine: new))
  }

  @Test func ciTransitions() {
    let running = PullRequest.make(status: .blocked, ci: .running(2, of: 5))
    let failed = PullRequest.make(status: .blocked, ci: .failing(1, of: 5))
    let passed = PullRequest.make(ci: .passing(5))
    #expect(events([running], [failed]) == [.ciFailed(failed)])
    #expect(events([running], [passed]) == [.ciPassed(passed)])
    #expect(events([failed], [failed]).isEmpty, "no repeat for an already failing PR")
    #expect(events([passed], [passed]).isEmpty)
  }

  @Test func newPushDoesNotCompareAcrossCommits() {
    let oldPassed = PullRequest.make(headRefOid: "old", ci: .passing(5))
    let newFailed = PullRequest.make(headRefOid: "new", status: .blocked, ci: .failing(1, of: 5))
    #expect(events([oldPassed], [newFailed]).isEmpty)
    let newRunning = PullRequest.make(headRefOid: "old", ci: .running(1, of: 5))
    #expect(events([newRunning], [newFailed]) == [.ciFailed(newFailed)], "pending -> failed always counts")
  }

  @Test func reviewTransitions() {
    let before = PullRequest.make(review: .init(decision: .reviewRequired, reviewers: [.user("alice", .requested)]))
    let after = PullRequest.make(
      review: .init(decision: .changesRequested, reviewers: [.user("bob", .changesRequested), .user("alice", .approved)]))
    #expect(events([before], [after]) == [.approved(after, by: ["alice"]), .changesRequested(after, by: ["bob"])])
  }

  @Test func conflictsAndDisappearance() {
    let clean = PullRequest.make(id: "a")
    let conflicted = PullRequest.make(id: "a", mergeable: .conflicting, status: .dirty)
    #expect(events([clean], [conflicted]) == [.conflicts(conflicted)])
    #expect(events([clean], []) == [.disappeared(clean)])
  }

  @Test func newReviewRequests() {
    let old = dashboard(mine: [], review: [.make(id: "r1")])
    let r2 = PullRequest.make(id: "r2")
    let new = dashboard(mine: [], review: [.make(id: "r1"), r2])
    #expect(SnapshotDiff.events(from: old, to: new) == [.reviewRequested(r2)])
  }
}

@Suite struct RefreshPolicyTests {
  let policy = RefreshPolicy(baseInterval: 60)
  let now = Date(timeIntervalSince1970: 1_000)

  @Test func cadence() {
    #expect(policy.nextDelay(hasActivity: false, panelVisible: false, consecutiveFailures: 0, rateLimit: nil) == 60)
    #expect(policy.nextDelay(hasActivity: true, panelVisible: false, consecutiveFailures: 0, rateLimit: nil) == 15)
    #expect(policy.nextDelay(hasActivity: true, panelVisible: true, consecutiveFailures: 0, rateLimit: nil) == 10)
    #expect(RefreshPolicy(baseInterval: 5).nextDelay(hasActivity: false, panelVisible: true, consecutiveFailures: 0, rateLimit: nil) == 5)
  }

  @Test func refreshKind() {
    #expect(policy.searchInterval == 120)
    #expect(RefreshPolicy(baseInterval: 15).searchInterval == 60)
    #expect(policy.kind(searchedAt: nil, now: now) == .full)
    #expect(policy.kind(searchedAt: now.addingTimeInterval(-119), now: now) == .status)
    #expect(policy.kind(searchedAt: now.addingTimeInterval(-120), now: now) == .full)
  }

  @Test func panelOpen() {
    #expect(policy.kindOnPanelOpen(searchedAt: nil, fetchedAt: nil, now: now) == .full)
    #expect(policy.kindOnPanelOpen(searchedAt: now.addingTimeInterval(-30), fetchedAt: now, now: now) == .full)
    #expect(policy.kindOnPanelOpen(searchedAt: now.addingTimeInterval(-10), fetchedAt: now.addingTimeInterval(-6), now: now) == .status)
    #expect(policy.kindOnPanelOpen(searchedAt: now.addingTimeInterval(-10), fetchedAt: now.addingTimeInterval(-2), now: now) == nil)
  }

  @Test func backoff() {
    let delays = (1...9).map {
      policy.nextDelay(hasActivity: true, panelVisible: true, consecutiveFailures: $0, rateLimit: nil)
    }
    #expect(delays == [60, 120, 240, 300, 300, 300, 300, 300, 300])
  }

  @Test func waitsForRateLimitReset() {
    let low = RateLimit(remaining: 10, limit: 5000, resetAt: now.addingTimeInterval(600), cost: 1)
    #expect(policy.nextDelay(hasActivity: true, panelVisible: true, consecutiveFailures: 0, rateLimit: low, now: now) == 605)
    let fine = RateLimit(remaining: 4000, limit: 5000, resetAt: now.addingTimeInterval(600), cost: 1)
    #expect(policy.nextDelay(hasActivity: false, panelVisible: false, consecutiveFailures: 0, rateLimit: fine, now: now) == 60)
  }
}

@Suite struct SnapshotCacheTests {
  @Test func roundTripAndCorruption() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "mergelight-tests-\(UUID().uuidString)/snapshot.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let cache = SnapshotCache(fileURL: url)
    #expect(cache.load() == nil)

    let fetch = DashboardFetch(
      viewerLogin: "octo", fetchedAt: Date(timeIntervalSince1970: 42), rateLimit: nil,
      results: [UUID(): SectionResult(query: "is:pr", pullRequests: [.make(ci: .running(1, of: 2))], totalCount: 1)])
    try cache.save(fetch)
    #expect(cache.load() == fetch)

    try Data("garbage".utf8).write(to: url)
    #expect(cache.load() == nil)
  }
}
