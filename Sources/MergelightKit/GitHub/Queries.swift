import Foundation

/// GraphQL documents. Kept as plain strings next to the DTOs that decode them.
enum Queries {
  /// Fields for one row. Check and review lists are capped: the row shows counts and a few avatars.
  static let pullRequestFragment = """
    fragment Row on PullRequest {
      id number title url state isDraft createdAt updatedAt
      headRefName headRefOid baseRefName totalCommentsCount
      headRepository { id }
      author { login avatarUrl(size: 48) }
      repository {
        id name url owner { login }
        mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed autoMergeAllowed
        deleteBranchOnMerge viewerDefaultMergeMethod
      }
      mergeable mergeStateStatus reviewDecision
      autoMergeRequest { mergeMethod enabledAt }
      latestOpinionatedReviews(first: 10, writersOnly: true) {
        nodes { state author { login avatarUrl(size: 48) } }
      }
      reviewRequests(first: 10) {
        nodes { requestedReviewer {
          __typename
          ... on User { login avatarUrl(size: 48) }
          ... on Bot { login avatarUrl(size: 48) }
          ... on Mannequin { login avatarUrl(size: 48) }
          ... on Team { slug organization { login } }
        } }
      }
      commits(last: 1) { nodes { commit { statusCheckRollup {
        state
        contexts(first: 0) {
          checkRunCountsByState { state count }
          statusContextCountsByState { state count }
        }
      } } } }
    }
    """

  static let searchPageSize = 50

  /// Phase one of a full refresh: which PRs match a section. IDs only, so GitHub skips the
  /// expensive per-PR fields. Each section is its own request because GitHub runs aliased searches
  /// one after another, while separate requests run in parallel.
  static let searchIDs = """
    query Search($q: String!) {
      search(query: $q, type: ISSUE, first: \(searchPageSize)) {
        issueCount
        nodes { ... on PullRequest { id } }
      }
    }
    """

  /// Phase two, and the whole of a status refresh: current state of known PRs.
  ///
  /// `state` is live even when the search index lags, so a PR merged anywhere disappears on the
  /// next status refresh.
  static let pullRequests = """
    query PullRequests($ids: [ID!]!) {
      viewer { login }
      rateLimit { cost remaining limit resetAt }
      nodes(ids: $ids) { ...Row }
    }
    \(pullRequestFragment)
    """

  /// Upper bound of IDs per `nodes` request; GitHub computes merge state per PR, so smaller
  /// parallel batches finish sooner than one big one.
  static let nodesBatchSize = 10

  static let viewer = """
    query Viewer {
      viewer { login organizations(first: 100) { nodes { login } } }
    }
    """

  static let detail = """
    query Detail($id: ID!) {
      node(id: $id) { ... on PullRequest {
        viewerCanUpdateBranch viewerCanEnableAutoMerge viewerCanDisableAutoMerge viewerCanMergeAsAdmin
        reviewThreads(first: 100) { nodes { isResolved } }
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun {
            name status conclusion detailsUrl startedAt completedAt isRequired(pullRequestId: $id)
            checkSuite { app { name } workflowRun { databaseId workflow { name } } }
          }
          ... on StatusContext { context state targetUrl isRequired(pullRequestId: $id) }
        } } } } } }
      } }
    }
    """

  /// Final state of PRs that dropped out of the dashboard, to tell merged from closed.
  static let states = """
    query States($ids: [ID!]!) {
      nodes(ids: $ids) { ... on PullRequest { id state mergedBy { login } } }
    }
    """

  static let merge = """
    mutation Merge($id: ID!, $method: PullRequestMergeMethod!, $oid: GitObjectID!) {
      mergePullRequest(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $oid}) {
        pullRequest { id state }
      }
    }
    """

  static let enableAutoMerge = """
    mutation EnableAutoMerge($id: ID!, $method: PullRequestMergeMethod!, $oid: GitObjectID!) {
      enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method, expectedHeadOid: $oid}) {
        pullRequest { id }
      }
    }
    """

  static let disableAutoMerge = """
    mutation DisableAutoMerge($id: ID!) {
      disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } }
    }
    """

  static let updateBranch = """
    mutation UpdateBranch($id: ID!, $oid: GitObjectID!) {
      updatePullRequestBranch(input: {pullRequestId: $id, expectedHeadOid: $oid}) { pullRequest { id } }
    }
    """

  static let markReady = """
    mutation MarkReady($id: ID!) {
      markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { id } }
    }
    """
}
