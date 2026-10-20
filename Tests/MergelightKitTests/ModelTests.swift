import Foundation
import Testing

@testable import MergelightKit

@Suite struct CIStatusTests {
  @Test func countsByOutcome() {
    let ci = CIStatus(
      checkRunCounts: ["SUCCESS": 5, "SKIPPED": 2, "FAILURE": 1, "CANCELLED": 1, "QUEUED": 3, "BRAND_NEW": 1],
      statusContextCounts: ["SUCCESS": 1, "EXPECTED": 1, "ERROR": 1], githubRollup: "PENDING")
    #expect(ci.passed == 9)
    #expect(ci.failed == 3)
    #expect(ci.running == 4)
    #expect(ci.rollup == .failure, "one failure turns the row red even while checks still run")
  }

  @Test func fallsBackToGitHubRollupWithoutCounts() {
    #expect(CIStatus(checkRunCounts: [:], statusContextCounts: [:], githubRollup: "SUCCESS").rollup == .success)
    #expect(CIStatus(checkRunCounts: [:], statusContextCounts: [:], githubRollup: nil).rollup == .none)
  }
}

@Suite struct MergeReadinessTests {
  static let cases: [(PullRequest, MergeReadiness)] = [
    (.make(status: .clean), .ready),
    (.make(status: .hasHooks), .ready),
    (.make(status: .unstable, ci: .failing(1, of: 5)), .unstable),
    (.make(status: .unstable, ci: .running(2, of: 5)), .ciRunning),
    (.make(status: .behind), .behind),
    (.make(mergeable: .conflicting, status: .blocked), .conflicts),
    (.make(status: .dirty), .conflicts),
    (.make(isDraft: true, status: .draft), .draft),
    (.make(status: .blocked, autoMerge: .init(method: .squash, enabledAt: nil)), .autoMerge),
    (.make(review: .init(decision: .changesRequested, reviewers: []), status: .blocked, ci: .failing(1, of: 3)), .changesRequested),
    (.make(review: .init(decision: .reviewRequired, reviewers: []), status: .blocked, ci: .failing(1, of: 3)), .ciFailing),
    (.make(review: .init(decision: .reviewRequired, reviewers: []), status: .blocked), .needsReview),
    (.make(status: .blocked, ci: .running(1, of: 3)), .ciRunning),
    (.make(status: .blocked, ci: .passing(3)), .blocked),
    (.make(mergeable: .unknown, status: .unknown), .checking),
    (.make(mergeable: .unknown, status: .unknown, ci: .failing(1, of: 2)), .ciFailing),
  ]

  @Test(arguments: cases)
  func readiness(pr: PullRequest, expected: MergeReadiness) {
    #expect(pr.readiness == expected)
  }

  @Test func mergeability() {
    #expect(PullRequest.make(status: .clean).canMergeNow)
    #expect(PullRequest.make(status: .unstable).canMergeNow)
    #expect(!PullRequest.make(status: .blocked).canMergeNow)
    #expect(!PullRequest.make(mergeable: .unknown, status: .clean).canMergeNow)
    #expect(!PullRequest.make(isDraft: true, status: .clean).canMergeNow)
    #expect(!PullRequest.make(state: .merged, status: .clean).canMergeNow)

  }

  @Test func defaultMergeMethod() {
    let pr = PullRequest.make(allowed: [.squash, .merge], viewerDefault: .merge)
    #expect(pr.defaultMergeMethod(preferred: nil) == .merge)
    #expect(pr.defaultMergeMethod(preferred: .squash) == .squash)
    #expect(pr.defaultMergeMethod(preferred: .rebase) == .merge, "a disallowed preference falls back")
    #expect(PullRequest.make(allowed: [.squash], viewerDefault: .merge).defaultMergeMethod(preferred: nil) == .squash)
  }
}

@Suite struct SectionConfigTests {
  @Test func effectiveQueryAddsDefaults() {
    let section = SectionConfig(name: "x", color: .blue, query: "  is:open   author:@me ")
    #expect(section.effectiveQuery == "is:pr is:open author:@me sort:updated-desc")
  }

  @Test func effectiveQueryKeepsUserChoices() {
    let section = SectionConfig(name: "x", color: .blue, query: "type:pr sort:created-asc")
    #expect(section.effectiveQuery == "type:pr sort:created-asc")
  }

  @Test func repoFilter() {
    var section = SectionConfig(
      name: "x", color: .blue, query: "is:pr", repoFilterMode: .include,
      repos: ["acme/api", " acme/web ", "not a repo", "acme/", "a/b/c"])
    #expect(section.effectiveQuery == "is:pr sort:updated-desc repo:acme/api repo:acme/web")
    section.repoFilterMode = .exclude
    #expect(section.effectiveQuery == "is:pr sort:updated-desc -repo:acme/api -repo:acme/web")
    section.repoFilterMode = .all
    #expect(section.effectiveQuery == "is:pr sort:updated-desc")
  }

  @Test func webSearchURLEncodesQuery() {
    let section = SectionConfig(name: "x", color: .blue, query: "is:pr org:acme")
    #expect(section.webSearchURL.absoluteString == "https://github.com/pulls?q=is:pr%20org:acme%20sort:updated-desc")
  }

  @Test func defaultSections() {
    let sections = DefaultSections.make(login: "octo", organizations: ["acme", "initech"])
    #expect(sections.map(\.name) == ["acme", "initech", "Personal", "Elsewhere", "Review requests"])
    #expect(sections.map(\.tab) == [.mine, .mine, .mine, .mine, .review])
    #expect(sections.map(\.countsInMenuBar) == [true, true, true, true, false])
    #expect(sections[2].query.contains("user:octo"))
    #expect(Set(sections.map(\.id)).count == sections.count)
  }
}

@Suite struct SettingsDecodingTests {
  @Test func missingAndUnknownKeysFallBackToDefaults() throws {
    let id = UUID()
    let json = """
      {"refreshInterval": 5, "menuBarStyle": "fromTheFuture", "mergeConfirmation": "oneClick",
       "sections": [{"id": "\(id.uuidString)", "name": "Acme", "query": "org:acme", "tab": "nope"}],
       "notifications": {"ciPassed": false}}
      """
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.refreshInterval == 15, "clamped to the allowed range")
    #expect(settings.menuBarStyle == .statusCounts)
    #expect(settings.mergeConfirmation == .oneClick)
    #expect(settings.deleteBranchAfterMerge)
    #expect(settings.notifications.ciPassed == false)
    #expect(settings.notifications.ciFailed)
    let section = try #require(settings.sections.only)
    #expect(section.id == id)
    #expect(section.tab == .mine)
    #expect(section.countsInMenuBar)
    #expect(section.color == .blue)
  }

  @Test func roundTrips() throws {
    var settings = AppSettings(sections: DefaultSections.make(login: "octo", organizations: ["acme"]))
    settings.preferredMergeMethod = .rebase
    settings.collapsedSectionIDs = [settings.sections[0].id]
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
  }

  @Test func refetchOnlyWhenQueriesChange() {
    let base = AppSettings(sections: DefaultSections.make(login: "octo", organizations: ["acme"]))
    var cosmetic = base
    cosmetic.sections[0].name = "Renamed"
    cosmetic.sections[0].color = .pink
    cosmetic.showDrafts = false
    #expect(!cosmetic.requiresRefetch(comparedTo: base))

    var query = base
    query.sections[0].repos = ["acme/api"]
    query.sections[0].repoFilterMode = .include
    #expect(query.requiresRefetch(comparedTo: base))

    var disabled = base
    disabled.sections[1].isEnabled = false
    #expect(disabled.requiresRefetch(comparedTo: base))
  }

  @Test func membershipChanges() {
    let base = AppSettings(sections: DefaultSections.make(login: "octo", organizations: ["acme"]))
    var renamed = base
    renamed.sections[0].name = "Renamed"
    renamed.menuBarStyle = .count
    #expect(!renamed.changesMembership(comparedTo: base))
    var moved = base
    moved.sections[0].tab = .review
    #expect(moved.changesMembership(comparedTo: base))
    #expect(!moved.requiresRefetch(comparedTo: base))
    var drafts = base
    drafts.showDrafts = false
    #expect(drafts.changesMembership(comparedTo: base))
  }
}
