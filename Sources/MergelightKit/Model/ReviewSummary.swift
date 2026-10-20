import Foundation

/// Who reviewed the PR and what GitHub concludes from it.
public struct ReviewSummary: Hashable, Sendable, Codable {
  public enum Decision: String, Sendable, Codable {
    case approved, changesRequested, reviewRequired
    /// The base branch has no review rule.
    case notRequired
  }

  public enum ReviewerState: String, Sendable, Codable, Comparable {
    case changesRequested, approved, requested, commented, dismissed

    /// Display order: blockers first, then approvals, then people we're still waiting for.
    var rank: Int {
      switch self {
      case .changesRequested: 0
      case .approved: 1
      case .requested: 2
      case .commented: 3
      case .dismissed: 4
      }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
  }

  public struct Reviewer: Hashable, Sendable, Codable, Identifiable {
    /// User login, or `org/team-slug` for a team.
    public let login: String
    public let avatarURL: URL?
    public let state: ReviewerState
    public let isTeam: Bool

    public var id: String { login }
  }

  public let decision: Decision
  public let reviewers: [Reviewer]

  public static let empty = ReviewSummary(decision: .notRequired, reviewers: [])

  public var approvals: Int { reviewers.count { $0.state == .approved } }
  public var changeRequests: Int { reviewers.count { $0.state == .changesRequested } }

  /// Merges latest opinionated reviews with outstanding review requests.
  ///
  /// A re-requested reviewer shows as pending even if they reviewed before, matching GitHub's UI.
  public init(decision: Decision, reviews: [Reviewer], requests: [Reviewer]) {
    var byLogin: [String: Reviewer] = [:]
    var order: [String] = []
    for reviewer in reviews + requests {
      if byLogin[reviewer.login] == nil { order.append(reviewer.login) }
      byLogin[reviewer.login] = reviewer
    }
    let merged = order.compactMap { byLogin[$0] }
    self.init(
      decision: decision,
      reviewers: merged.enumerated()
        .sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }
        .map(\.element))
  }

  public init(decision: Decision, reviewers: [Reviewer]) {
    self.decision = decision
    self.reviewers = reviewers
  }
}
