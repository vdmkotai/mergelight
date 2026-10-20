import Foundation

// Wire types for the GraphQL responses. Enum-like fields stay `String` here and are mapped
// leniently in Mapping.swift, so a value GitHub adds later can't break decoding.

struct SearchIDsDTO: Decodable, Sendable {
  struct Search: Decodable, Sendable {
    let issueCount: Int
    let nodes: [Lossy<PullRequestDTO.IDOnly>]
  }
  /// Null when GitHub rejected the query; the reason is in the response's `errors`.
  let search: Search?
}

struct PullRequestsDTO: Decodable, Sendable {
  let viewer: LoginDTO
  let rateLimit: RateLimitDTO?
  let nodes: [Lossy<PullRequestDTO>]
}

struct LoginDTO: Decodable, Sendable { let login: String }

struct RateLimitDTO: Decodable, Sendable {
  let cost: Int
  let remaining: Int
  let limit: Int
  let resetAt: Date
}

struct PullRequestDTO: Decodable, Sendable {
  struct IDOnly: Decodable, Sendable { let id: String }
  struct Actor: Decodable, Sendable {
    let login: String
    let avatarUrl: URL?
  }
  struct Owner: Decodable, Sendable { let login: String }
  struct RepositoryDTO: Decodable, Sendable {
    let id: String
    let name: String
    let url: URL
    let owner: Owner
    let mergeCommitAllowed: Bool
    let squashMergeAllowed: Bool
    let rebaseMergeAllowed: Bool
    let autoMergeAllowed: Bool
    let deleteBranchOnMerge: Bool
    let viewerDefaultMergeMethod: String
  }
  struct AutoMergeDTO: Decodable, Sendable {
    let mergeMethod: String
    let enabledAt: Date?
  }
  struct Review: Decodable, Sendable {
    let state: String
    let author: Actor?
  }
  struct ReviewRequest: Decodable, Sendable {
    let requestedReviewer: RequestedReviewer?
  }
  struct RequestedReviewer: Decodable, Sendable {
    let __typename: String
    let login: String?
    let avatarUrl: URL?
    let slug: String?
    let organization: Owner?
  }
  struct CommitNode: Decodable, Sendable { let commit: Commit }
  struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
  struct Rollup: Decodable, Sendable {
    let state: String?
    let contexts: Contexts
  }
  struct Contexts: Decodable, Sendable {
    let checkRunCountsByState: [StateCount]?
    let statusContextCountsByState: [StateCount]?
  }
  struct StateCount: Decodable, Sendable {
    let state: String
    let count: Int
  }

  let id: String
  let number: Int
  let title: String
  let url: URL
  let state: String
  let isDraft: Bool
  let createdAt: Date
  let updatedAt: Date
  let headRefName: String
  let headRefOid: String
  let baseRefName: String
  let totalCommentsCount: Int?
  let headRepository: IDOnly?
  let author: Actor?
  let repository: RepositoryDTO
  let mergeable: String
  let mergeStateStatus: String
  let reviewDecision: String?
  let autoMergeRequest: AutoMergeDTO?
  let latestOpinionatedReviews: Connection<Review>?
  let reviewRequests: Connection<ReviewRequest>?
  let commits: Connection<CommitNode>
}

struct ViewerDTO: Decodable, Sendable {
  struct Viewer: Decodable, Sendable {
    let login: String
    let organizations: Connection<LoginDTO>
  }
  let viewer: Viewer
}

struct DetailDTO: Decodable, Sendable {
  struct Node: Decodable, Sendable {
    let viewerCanUpdateBranch: Bool?
    let viewerCanEnableAutoMerge: Bool?
    let viewerCanDisableAutoMerge: Bool?
    let viewerCanMergeAsAdmin: Bool?
    let reviewThreads: Connection<Thread>?
    let commits: Connection<CommitNode>?
  }
  struct Thread: Decodable, Sendable { let isResolved: Bool }
  struct CommitNode: Decodable, Sendable { let commit: Commit }
  struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
  struct Rollup: Decodable, Sendable { let contexts: Connection<Context> }
  struct Context: Decodable, Sendable {
    struct CheckSuite: Decodable, Sendable {
      struct App: Decodable, Sendable { let name: String? }
      struct WorkflowRun: Decodable, Sendable {
        struct Workflow: Decodable, Sendable { let name: String? }
        let databaseId: Int?
        let workflow: Workflow?
      }
      let app: App?
      let workflowRun: WorkflowRun?
    }
    let __typename: String
    // CheckRun
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: String?
    let startedAt: Date?
    let completedAt: Date?
    let checkSuite: CheckSuite?
    // StatusContext
    let context: String?
    let state: String?
    let targetUrl: String?
    // Both
    let isRequired: Bool?
  }
  let node: Node?
}

struct StatesDTO: Decodable, Sendable {
  struct Node: Decodable, Sendable {
    let id: String
    let state: String
    let mergedBy: LoginDTO?
  }
  let nodes: [Lossy<Node>]
}

/// Mutations return payloads we don't need; only success or errors matter.
struct IgnoredPayload: Decodable, Sendable {
  init(from decoder: any Decoder) throws {}
}
