import Foundation

/// Per-check detail for an expanded row. Loaded on demand, never for the whole list.
public struct PullRequestDetail: Sendable, Equatable {
  public struct Check: Identifiable, Hashable, Sendable {
    public enum Outcome: Int, Sendable, Comparable {
      // Raw values give the display order.
      case failed, running, passed, neutral, skipped
      public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String
    public let name: String
    /// Workflow name for GitHub Actions checks, app name for other check runs.
    public let group: String?
    public let outcome: Outcome
    public let url: URL?
    public let isRequired: Bool
    public let duration: TimeInterval?
    /// Set for GitHub Actions runs; used to re-run failed jobs.
    public let workflowRunID: Int?

    public var displayName: String {
      guard let group, !group.isEmpty, group != name else { return name }
      return "\(group) / \(name)"
    }
  }

  /// What the viewer may do. GitHub computes these slowly, so they're fetched per expanded row
  /// rather than for the whole list.
  public struct Permissions: Sendable, Equatable {
    public let canUpdateBranch: Bool
    public let canEnableAutoMerge: Bool
    public let canDisableAutoMerge: Bool
    public let canMergeAsAdmin: Bool

    public static let none = Permissions(
      canUpdateBranch: false, canEnableAutoMerge: false, canDisableAutoMerge: false,
      canMergeAsAdmin: false)
  }

  public let checks: [Check]
  public let unresolvedThreads: Int
  public let permissions: Permissions

  public init(checks: [Check], unresolvedThreads: Int, permissions: Permissions = .none) {
    self.checks = checks.enumerated()
      .sorted { ($0.element.outcome, $0.offset) < ($1.element.outcome, $1.offset) }
      .map(\.element)
    self.unresolvedThreads = unresolvedThreads
    self.permissions = permissions
  }

  /// Admins can push a blocked PR through; offered only behind the confirmation dialog.
  public func canMergeAsAdmin(_ pr: PullRequest) -> Bool {
    permissions.canMergeAsAdmin && pr.state == .open && !pr.isDraft && !pr.canMergeNow
      && pr.merge.mergeable == .mergeable
  }

  public func checks(_ outcome: Check.Outcome) -> [Check] { checks.filter { $0.outcome == outcome } }

  /// Distinct GitHub Actions runs that contain a failed job.
  public var failedWorkflowRunIDs: [Int] {
    var seen = Set<Int>()
    return checks.compactMap { check in
      guard check.outcome == .failed, let id = check.workflowRunID, seen.insert(id).inserted else {
        return nil
      }
      return id
    }
  }
}
