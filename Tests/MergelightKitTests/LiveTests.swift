import Foundation
import Testing

@testable import MergelightKit

/// Hits the real API with the default sections. Opt-in, read-only:
/// `MERGELIGHT_LIVE_TOKEN=$(gh auth token) swift test --filter LiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MERGELIGHT_LIVE_TOKEN"] != nil))
struct LiveTests {
  let client = GitHubClient(token: ProcessInfo.processInfo.environment["MERGELIGHT_LIVE_TOKEN"] ?? "")

  @Test func defaultDashboardLoads() async throws {
    let viewer = try await client.viewer()
    let sections = DefaultSections.make(login: viewer.login, organizations: viewer.organizations)
    let started = ContinuousClock.now
    let fetch = try await client.dashboard(sections: sections)
    let elapsed = ContinuousClock.now - started

    let dashboard = Dashboard(fetch: fetch, configs: sections)
    for section in dashboard.sections {
      #expect(section.error == nil, "\(section.name): \(section.error ?? "")")
      print("[live] \(section.name): \(section.pullRequests.count) PRs, more: \(section.moreCount)")
    }
    print("[live] menu bar: \(dashboard.menuBar)")
    print("[live] cost: \(fetch.rateLimit?.cost ?? -1), remaining: \(fetch.rateLimit?.remaining ?? -1), took \(elapsed)")

    let statusStarted = ContinuousClock.now
    let refreshed = try await client.refreshStatuses(of: fetch)
    print("[live] status refresh: cost \(refreshed.rateLimit?.cost ?? -1), took \(ContinuousClock.now - statusStarted)")
    #expect(Dashboard(fetch: refreshed, configs: sections).menuBar.total == dashboard.menuBar.total)

    if let pr = dashboard.pullRequests(in: .mine).first {
      let detail = try await client.detail(pullRequestID: pr.id)
      print("[live] detail of first PR: \(detail.checks.count) checks, \(detail.failedWorkflowRunIDs.count) failed runs")
    }
  }
}
