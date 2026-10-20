import Foundation

/// GitHub's own view of whether the PR can be merged.
public struct MergeInfo: Hashable, Sendable, Codable {
  public enum Mergeable: String, Sendable, Codable {
    case mergeable, conflicting
    /// GitHub computes mergeability lazily; right after a push it reports unknown for a few seconds.
    case unknown
  }

  /// `MergeStateStatus` from the GraphQL API.
  public enum Status: String, Sendable, Codable {
    case behind, blocked, clean, dirty, draft, hasHooks, unknown, unstable
  }

  public struct AutoMerge: Hashable, Sendable, Codable {
    public let method: MergeMethod
    public let enabledAt: Date?
  }

  public let mergeable: Mergeable
  public let status: Status
  public let autoMerge: AutoMerge?
}

/// The one-word answer to "what's stopping this PR?", shown as the pill in the Merge column.
public enum MergeReadiness: String, Hashable, Sendable, CaseIterable {
  case ready
  /// Mergeable, but some non-required checks failed.
  case unstable
  case autoMerge
  case ciRunning
  case needsReview
  case changesRequested
  case ciFailing
  case behind
  case conflicts
  /// Blocked by a rule we can't name (e.g. required signatures, deployments).
  case blocked
  case draft
  /// GitHub hasn't computed mergeability yet.
  case checking

  public init(_ pr: PullRequest) {
    let merge = pr.merge
    let ci = pr.ci
    if pr.isDraft {
      self = .draft
    } else if merge.autoMerge != nil {
      self = .autoMerge
    } else if merge.mergeable == .conflicting || merge.status == .dirty {
      self = .conflicts
    } else {
      switch merge.status {
      case .clean, .hasHooks:
        self = .ready
      case .unstable:
        self = ci.running > 0 ? .ciRunning : .unstable
      case .behind:
        self = .behind
      case .blocked:
        if pr.review.decision == .changesRequested {
          self = .changesRequested
        } else if ci.failed > 0 {
          self = .ciFailing
        } else if pr.review.decision == .reviewRequired {
          self = .needsReview
        } else if ci.running > 0 {
          self = .ciRunning
        } else {
          self = .blocked
        }
      case .draft:
        self = .draft
      case .dirty:
        self = .conflicts
      case .unknown:
        if ci.failed > 0 {
          self = .ciFailing
        } else if ci.running > 0 {
          self = .ciRunning
        } else {
          self = .checking
        }
      }
    }
  }

  /// States that need the author to do something.
  public var needsAttention: Bool {
    switch self {
    case .ciFailing, .changesRequested, .conflicts: true
    default: false
    }
  }

  public var title: String {
    switch self {
    case .ready: "Ready"
    case .unstable: "Unstable"
    case .autoMerge: "Auto-merge"
    case .ciRunning: "CI running"
    case .needsReview: "Needs review"
    case .changesRequested: "Changes req."
    case .ciFailing: "CI failing"
    case .behind: "Behind"
    case .conflicts: "Conflicts"
    case .blocked: "Blocked"
    case .draft: "Draft"
    case .checking: "Checking…"
    }
  }
}
