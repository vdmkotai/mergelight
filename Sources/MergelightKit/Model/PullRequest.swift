import Foundation

/// An open pull request as the app shows it: one value per row, rebuilt on every refresh.
///
/// Fields mirror what the dashboard query fetches. Anything that needs per-check detail lives in
/// `PullRequestDetail` and is loaded only when a row is expanded.
public struct PullRequest: Identifiable, Hashable, Sendable, Codable {
  public enum State: String, Sendable, Codable { case open, closed, merged }

  /// GraphQL node ID; stable across refreshes and accepted by every mutation.
  public let id: String
  public let number: Int
  public let title: String
  public let url: URL
  public let state: State
  public let isDraft: Bool
  public let createdAt: Date
  public let updatedAt: Date
  public let author: Person?
  public let headRefName: String
  /// The head commit the statuses below belong to. Sent with merges so GitHub rejects the merge
  /// if someone pushed after the row was rendered.
  public let headRefOid: String
  public let baseRefName: String
  /// True when the head branch lives in a fork; its branch can't be deleted from the base repo.
  public let isCrossRepository: Bool
  public let repository: Repository
  public let ci: CIStatus
  public let review: ReviewSummary
  public let merge: MergeInfo
  public let commentCount: Int

  public var readiness: MergeReadiness { MergeReadiness(self) }

  /// Whether GitHub would accept a merge right now without admin rights.
  public var canMergeNow: Bool {
    guard state == .open, !isDraft, merge.autoMerge == nil, merge.mergeable == .mergeable else {
      return false
    }
    switch merge.status {
    case .clean, .hasHooks, .unstable: return true
    case .behind, .blocked, .dirty, .draft, .unknown: return false
    }
  }

  /// Merge method to preselect: the user's override if the repo allows it, else what GitHub
  /// remembers as this user's last method in this repo.
  public func defaultMergeMethod(preferred: MergeMethod?) -> MergeMethod {
    let allowed = repository.allowedMergeMethods
    if let preferred, allowed.contains(preferred) { return preferred }
    if allowed.contains(repository.viewerDefaultMergeMethod) {
      return repository.viewerDefaultMergeMethod
    }
    return allowed.first ?? .merge
  }
}

public struct Person: Hashable, Sendable, Codable {
  public let login: String
  public let avatarURL: URL?
}

public struct Repository: Hashable, Sendable, Codable {
  public let id: String
  public let owner: String
  public let name: String
  public let url: URL
  public let allowedMergeMethods: [MergeMethod]
  public let viewerDefaultMergeMethod: MergeMethod
  public let autoMergeAllowed: Bool
  /// Repo setting "Automatically delete head branches". When on, the app never deletes branches.
  public let deletesBranchOnMerge: Bool

  public var nameWithOwner: String { "\(owner)/\(name)" }
}

public enum MergeMethod: String, CaseIterable, Sendable, Codable, Identifiable {
  case merge = "MERGE"
  case squash = "SQUASH"
  case rebase = "REBASE"

  public var id: String { rawValue }

  public var shortTitle: String {
    switch self {
    case .merge: "Merge"
    case .squash: "Squash"
    case .rebase: "Rebase"
    }
  }

  public var actionTitle: String {
    switch self {
    case .merge: "Create a merge commit"
    case .squash: "Squash and merge"
    case .rebase: "Rebase and merge"
    }
  }
}
