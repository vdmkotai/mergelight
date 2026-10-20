import Foundation

/// Something that changed between two refreshes and may deserve a notification.
public enum PullRequestEvent: Equatable, Sendable {
  case ciFailed(PullRequest)
  case ciPassed(PullRequest)
  case approved(PullRequest, by: [String])
  case changesRequested(PullRequest, by: [String])
  case conflicts(PullRequest)
  case reviewRequested(PullRequest)
  /// Left the "mine" tab. The caller asks GitHub whether it was merged or closed.
  case disappeared(PullRequest)

  public var pullRequest: PullRequest {
    switch self {
    case .ciFailed(let pr), .ciPassed(let pr), .approved(let pr, _), .changesRequested(let pr, _),
      .conflicts(let pr), .reviewRequested(let pr), .disappeared(let pr):
      pr
    }
  }
}

public enum SnapshotDiff {
  /// Compares two dashboards built from the same section configuration.
  ///
  /// Only transitions count: a PR that was already failing doesn't notify again, and a PR seen for
  /// the first time doesn't notify at all except as a new review request.
  public static func events(from old: Dashboard, to new: Dashboard) -> [PullRequestEvent] {
    var events: [PullRequestEvent] = []

    let oldMine = Dictionary(old.pullRequests(in: .mine).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let newMine = new.pullRequests(in: .mine)
    let newMineIDs = Set(newMine.map(\.id))

    for pr in newMine {
      guard let before = oldMine[pr.id] else { continue }
      events += transitions(from: before, to: pr)
    }
    for (id, pr) in oldMine where !newMineIDs.contains(id) {
      events.append(.disappeared(pr))
    }

    let oldReviewIDs = Set(old.pullRequests(in: .review).map(\.id))
    for pr in new.pullRequests(in: .review) where !oldReviewIDs.contains(pr.id) {
      events.append(.reviewRequested(pr))
    }
    return events
  }

  static func transitions(from old: PullRequest, to new: PullRequest) -> [PullRequestEvent] {
    var events: [PullRequestEvent] = []

    // A new push resets checks; compare like with like.
    if old.headRefOid == new.headRefOid || old.ci.rollup == .pending {
      if old.ci.rollup != .failure && new.ci.rollup == .failure {
        events.append(.ciFailed(new))
      } else if old.ci.rollup == .pending && new.ci.rollup == .success {
        events.append(.ciPassed(new))
      }
    }

    let oldStates = Dictionary(old.review.reviewers.map { ($0.login, $0.state) }, uniquingKeysWith: { a, _ in a })
    func newly(_ state: ReviewSummary.ReviewerState) -> [String] {
      new.review.reviewers.filter { $0.state == state && oldStates[$0.login] != state }.map(\.login)
    }
    let approvers = newly(.approved)
    if !approvers.isEmpty { events.append(.approved(new, by: approvers)) }
    let blockers = newly(.changesRequested)
    if !blockers.isEmpty { events.append(.changesRequested(new, by: blockers)) }

    let wasConflicting = old.merge.mergeable == .conflicting || old.merge.status == .dirty
    let isConflicting = new.merge.mergeable == .conflicting || new.merge.status == .dirty
    if !wasConflicting && isConflicting { events.append(.conflicts(new)) }

    return events
  }
}
