import Foundation

public struct Viewer: Sendable, Equatable {
  public let login: String
  public let organizations: [String]
}

public struct ClosedPullRequestState: Sendable, Equatable {
  public let id: String
  public let state: PullRequest.State
  public let mergedBy: String?
}

/// The operations the app performs, built on the raw transport.
extension GitHubClient {
  public func viewer() async throws(GitHubError) -> Viewer {
    let (data, _) = try await graphQL(Queries.viewer, as: ViewerDTO.self)
    return Viewer(
      login: data.viewer.login, organizations: data.viewer.organizations.values.map(\.login))
  }

  /// Full refresh: searches every section, then loads each distinct PR once.
  ///
  /// A section whose query GitHub rejects gets an error message and the others still load.
  /// Transport-level failures (offline, bad token, rate limit) fail the whole refresh.
  public func dashboard(sections: [SectionConfig], now: Date = .now) async throws(GitHubError)
    -> DashboardFetch
  {
    let queries = sections.map(\.effectiveQuery)
    let searches = try await concurrentMap(queries, maxConcurrent: 6) { query throws(GitHubError) in
      try await self.searchIDs(query)
    }

    let ids = Self.unique(searches.flatMap { $0.ids })
    let (pullRequests, viewer, rateLimit) = try await self.pullRequests(ids: ids)

    var results: [UUID: SectionResult] = [:]
    for (index, section) in sections.enumerated() {
      let search = searches[index]
      results[section.id] = SectionResult(
        query: queries[index],
        pullRequests: search.ids.compactMap { pullRequests[$0] },
        totalCount: search.totalCount,
        error: search.error)
    }
    return DashboardFetch(
      viewerLogin: viewer, fetchedAt: now, searchedAt: now, rateLimit: rateLimit, results: results)
  }

  /// Status refresh: re-reads the PRs already on the dashboard without searching.
  ///
  /// One cheap request in the common case. Merged or closed PRs come back with their live state
  /// and drop out of the dashboard; deleted or inaccessible ones are removed.
  public func refreshStatuses(of fetch: DashboardFetch, now: Date = .now) async throws(GitHubError)
    -> DashboardFetch
  {
    let ids = fetch.uniquePullRequestIDs
    guard !ids.isEmpty else {
      var unchanged = fetch
      unchanged.fetchedAt = now
      return unchanged
    }
    let (pullRequests, viewer, rateLimit) = try await self.pullRequests(ids: ids)
    var updated = fetch
    updated.viewerLogin = viewer
    updated.fetchedAt = now
    updated.rateLimit = rateLimit ?? fetch.rateLimit
    for (id, result) in fetch.results {
      updated.results[id]?.pullRequests = result.pullRequests.compactMap { pullRequests[$0.id] }
    }
    return updated
  }

  struct SearchOutcome: Sendable {
    var ids: [String]
    var totalCount: Int
    var error: String?
  }

  func searchIDs(_ query: String) async throws(GitHubError) -> SearchOutcome {
    do {
      let (data, errors) = try await graphQL(
        Queries.searchIDs, variables: ["q": .string(query)], as: SearchIDsDTO.self)
      guard let search = data.search else {
        return SearchOutcome(
          ids: [], totalCount: 0,
          error: errors.first?.message ?? "GitHub returned no results for this query.")
      }
      return SearchOutcome(
        ids: search.nodes.compactMap { $0.value?.id }, totalCount: search.issueCount,
        error: errors.first?.message)
    } catch .graphQL(let messages) {
      // An invalid query is the section's problem, not the refresh's.
      return SearchOutcome(ids: [], totalCount: 0, error: messages.joined(separator: "\n"))
    }
  }

  /// Loads PRs by ID in parallel batches, returning them keyed by ID.
  func pullRequests(ids: [String]) async throws(GitHubError)
    -> (pullRequests: [String: PullRequest], viewer: String, rateLimit: RateLimit?)
  {
    if ids.isEmpty {
      // Still need the viewer and rate limit; ask for an empty batch.
      let (data, _) = try await graphQL(
        Queries.pullRequests, variables: ["ids": .strings([])], as: PullRequestsDTO.self)
      return ([:], data.viewer.login, data.rateLimit.map(RateLimit.init))
    }
    let batches = stride(from: 0, to: ids.count, by: Queries.nodesBatchSize).map {
      Array(ids[$0..<min($0 + Queries.nodesBatchSize, ids.count)])
    }
    let responses = try await concurrentMap(batches, maxConcurrent: 4) { batch throws(GitHubError) in
      try await self.graphQL(
        Queries.pullRequests, variables: ["ids": .strings(batch)], as: PullRequestsDTO.self
      ).data
    }

    var pullRequests: [String: PullRequest] = [:]
    for response in responses {
      for dto in response.nodes.compactMap(\.value) {
        pullRequests[dto.id] = PullRequest(dto)
      }
    }
    // Report the lowest remaining budget and the total cost of this refresh.
    let limits = responses.compactMap(\.rateLimit)
    let rateLimit = limits.min { $0.remaining < $1.remaining }.map {
      RateLimit(
        remaining: $0.remaining, limit: $0.limit, resetAt: $0.resetAt,
        cost: limits.reduce(0) { $0 + $1.cost })
    }
    return (pullRequests, responses[0].viewer.login, rateLimit)
  }

  static func unique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }

  public func detail(pullRequestID: String) async throws(GitHubError) -> PullRequestDetail {
    let (data, _) = try await graphQL(
      Queries.detail, variables: ["id": .string(pullRequestID)], as: DetailDTO.self)
    guard let node = data.node else { throw .graphQL(["Pull request not found."]) }
    return PullRequestDetail(node)
  }

  public func states(of ids: [String]) async throws(GitHubError) -> [ClosedPullRequestState] {
    guard !ids.isEmpty else { return [] }
    let (data, _) = try await graphQL(
      Queries.states, variables: ["ids": .strings(ids)], as: StatesDTO.self)
    return data.nodes.compactMap(\.value).map {
      ClosedPullRequestState(
        id: $0.id, state: PullRequest.State(gitHub: $0.state), mergedBy: $0.mergedBy?.login)
    }
  }

  // MARK: Mutations

  public func merge(_ pr: PullRequest, method: MergeMethod) async throws(GitHubError) {
    try await mutate(
      Queries.merge,
      ["id": .string(pr.id), "method": .string(method.rawValue), "oid": .string(pr.headRefOid)])
  }

  public func enableAutoMerge(_ pr: PullRequest, method: MergeMethod) async throws(GitHubError) {
    try await mutate(
      Queries.enableAutoMerge,
      ["id": .string(pr.id), "method": .string(method.rawValue), "oid": .string(pr.headRefOid)])
  }

  public func disableAutoMerge(_ pr: PullRequest) async throws(GitHubError) {
    try await mutate(Queries.disableAutoMerge, ["id": .string(pr.id)])
  }

  public func updateBranch(_ pr: PullRequest) async throws(GitHubError) {
    try await mutate(Queries.updateBranch, ["id": .string(pr.id), "oid": .string(pr.headRefOid)])
  }

  public func markReadyForReview(_ pr: PullRequest) async throws(GitHubError) {
    try await mutate(Queries.markReady, ["id": .string(pr.id)])
  }

  /// Re-runs only the failed jobs of each GitHub Actions run.
  public func rerunFailedJobs(_ pr: PullRequest, runIDs: [Int]) async throws(GitHubError) {
    for runID in runIDs {
      try await rest(
        "POST", "repos/\(pr.repository.nameWithOwner)/actions/runs/\(runID)/rerun-failed-jobs")
    }
  }

  public func deleteBranch(_ pr: PullRequest) async throws(GitHubError) {
    try await rest("DELETE", "repos/\(pr.repository.nameWithOwner)/git/refs/heads/\(pr.headRefName)")
  }

  private func mutate(_ document: String, _ variables: [String: GraphQLVariable])
    async throws(GitHubError)
  {
    let (_, errors) = try await graphQL(document, variables: variables, as: IgnoredPayload.self)
    if !errors.isEmpty { throw .graphQL(errors.map(\.message)) }
  }
}
