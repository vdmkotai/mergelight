import Foundation

// DTO -> domain. Every enum-ish string has a fallback, so new GitHub values degrade to "unknown".

extension PullRequest {
  init(_ dto: PullRequestDTO) {
    let rollup = dto.commits.values.last?.commit.statusCheckRollup
    func counts(_ list: [PullRequestDTO.StateCount]?) -> [String: Int] {
      Dictionary((list ?? []).map { ($0.state, $0.count) }, uniquingKeysWith: +)
    }

    self.init(
      id: dto.id,
      number: dto.number,
      title: dto.title,
      url: dto.url,
      state: State(gitHub: dto.state),
      isDraft: dto.isDraft,
      createdAt: dto.createdAt,
      updatedAt: dto.updatedAt,
      author: dto.author.map { Person(login: $0.login, avatarURL: $0.avatarUrl) },
      headRefName: dto.headRefName,
      headRefOid: dto.headRefOid,
      baseRefName: dto.baseRefName,
      isCrossRepository: dto.headRepository?.id != dto.repository.id,
      repository: Repository(dto.repository),
      ci: CIStatus(
        checkRunCounts: counts(rollup?.contexts.checkRunCountsByState),
        statusContextCounts: counts(rollup?.contexts.statusContextCountsByState),
        githubRollup: rollup?.state),
      review: ReviewSummary(dto),
      merge: MergeInfo(
        mergeable: MergeInfo.Mergeable(rawValue: dto.mergeable.lowercased()) ?? .unknown,
        status: MergeInfo.Status(gitHub: dto.mergeStateStatus),
        autoMerge: dto.autoMergeRequest.map {
          MergeInfo.AutoMerge(method: MergeMethod(rawValue: $0.mergeMethod) ?? .merge, enabledAt: $0.enabledAt)
        }),
      commentCount: dto.totalCommentsCount ?? 0)
  }
}

extension PullRequest.State {
  init(gitHub value: String) {
    switch value {
    case "MERGED": self = .merged
    case "CLOSED": self = .closed
    default: self = .open
    }
  }
}

extension MergeInfo.Status {
  init(gitHub value: String) {
    switch value {
    case "BEHIND": self = .behind
    case "BLOCKED": self = .blocked
    case "CLEAN": self = .clean
    case "DIRTY": self = .dirty
    case "DRAFT": self = .draft
    case "HAS_HOOKS": self = .hasHooks
    case "UNSTABLE": self = .unstable
    default: self = .unknown
    }
  }
}

extension Repository {
  init(_ dto: PullRequestDTO.RepositoryDTO) {
    var allowed: [MergeMethod] = []
    if dto.squashMergeAllowed { allowed.append(.squash) }
    if dto.mergeCommitAllowed { allowed.append(.merge) }
    if dto.rebaseMergeAllowed { allowed.append(.rebase) }
    self.init(
      id: dto.id,
      owner: dto.owner.login,
      name: dto.name,
      url: dto.url,
      allowedMergeMethods: allowed,
      viewerDefaultMergeMethod: MergeMethod(rawValue: dto.viewerDefaultMergeMethod) ?? allowed.first ?? .merge,
      autoMergeAllowed: dto.autoMergeAllowed,
      deletesBranchOnMerge: dto.deleteBranchOnMerge)
  }
}

extension ReviewSummary {
  init(_ dto: PullRequestDTO) {
    let decision: Decision =
      switch dto.reviewDecision {
      case "APPROVED": .approved
      case "CHANGES_REQUESTED": .changesRequested
      case "REVIEW_REQUIRED": .reviewRequired
      default: .notRequired
      }

    let reviews: [Reviewer] = (dto.latestOpinionatedReviews?.values ?? []).compactMap { review in
      guard let author = review.author else { return nil }
      let state: ReviewerState? =
        switch review.state {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "COMMENTED": .commented
        case "DISMISSED": .dismissed
        default: nil
        }
      return state.map {
        Reviewer(login: author.login, avatarURL: author.avatarUrl, state: $0, isTeam: false)
      }
    }

    let requests: [Reviewer] = (dto.reviewRequests?.values ?? []).compactMap { request in
      guard let reviewer = request.requestedReviewer else { return nil }
      if reviewer.__typename == "Team", let slug = reviewer.slug {
        let login = reviewer.organization.map { "\($0.login)/\(slug)" } ?? slug
        return Reviewer(login: login, avatarURL: nil, state: .requested, isTeam: true)
      }
      guard let login = reviewer.login else { return nil }
      return Reviewer(login: login, avatarURL: reviewer.avatarUrl, state: .requested, isTeam: false)
    }

    self.init(decision: decision, reviews: reviews, requests: requests)
  }
}

extension PullRequestDetail {
  init(_ node: DetailDTO.Node) {
    let contexts = node.commits?.values.last?.commit.statusCheckRollup?.contexts.values ?? []
    let checks = contexts.enumerated().compactMap { index, context -> Check? in
      switch context.__typename {
      case "CheckRun":
        guard let name = context.name else { return nil }
        let duration = context.startedAt.flatMap { start in
          context.completedAt.map { $0.timeIntervalSince(start) }
        }
        return Check(
          id: "run-\(index)-\(name)",
          name: name,
          group: context.checkSuite?.workflowRun?.workflow?.name ?? context.checkSuite?.app?.name,
          outcome: Self.outcome(status: context.status, conclusion: context.conclusion),
          url: context.detailsUrl.flatMap(URL.init(string:)),
          isRequired: context.isRequired ?? false,
          duration: duration.map { max(0, $0) },
          workflowRunID: context.checkSuite?.workflowRun?.databaseId)
      case "StatusContext":
        guard let name = context.context else { return nil }
        let outcome: Check.Outcome =
          switch CIStatus.statusContextOutcome(context.state ?? "") {
          case .failed: .failed
          case .running: .running
          case .passed: .passed
          }
        return Check(
          id: "status-\(index)-\(name)", name: name, group: nil, outcome: outcome,
          url: context.targetUrl.flatMap(URL.init(string:)), isRequired: context.isRequired ?? false,
          duration: nil, workflowRunID: nil)
      default:
        return nil
      }
    }
    let unresolved = node.reviewThreads?.values.count { !$0.isResolved } ?? 0
    self.init(
      checks: checks, unresolvedThreads: unresolved,
      permissions: Permissions(
        canUpdateBranch: node.viewerCanUpdateBranch ?? false,
        canEnableAutoMerge: node.viewerCanEnableAutoMerge ?? false,
        canDisableAutoMerge: node.viewerCanDisableAutoMerge ?? false,
        canMergeAsAdmin: node.viewerCanMergeAsAdmin ?? false))
  }

  static func outcome(status: String?, conclusion: String?) -> Check.Outcome {
    guard status == "COMPLETED" else { return .running }
    switch conclusion {
    case "SUCCESS": return .passed
    case "NEUTRAL": return .neutral
    case "SKIPPED", "STALE": return .skipped
    case .some(let value) where CIStatus.checkRunOutcome(value) == .failed: return .failed
    default: return .neutral
    }
  }
}
