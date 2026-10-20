import Foundation
import Testing

@testable import MergelightKit

/// A fake GitHub GraphQL endpoint backed by the fixture PRs.
struct FakeGitHub: Sendable {
  /// Search query -> matching PR IDs. A missing query is answered as an invalid search.
  var searches: [String: [String]]
  /// Pretend GitHub knows more matches than it returns.
  var issueCounts: [String: Int] = [:]
  /// PR node JSON by ID.
  var pullRequests: [String: Data]

  static func fromFixtures(searches: [String: [String]], issueCounts: [String: Int] = [:]) throws -> FakeGitHub {
    let object = try JSONSerialization.jsonObject(with: Fixture.data("pull_requests"))
    let prs = try #require(object as? [String: Any])
    return FakeGitHub(
      searches: searches, issueCounts: issueCounts,
      pullRequests: try prs.mapValues { try JSONSerialization.data(withJSONObject: $0) })
  }

  /// Copies a fixture PR under a new ID with some fields replaced.
  mutating func setPullRequest(_ id: String, from source: String, _ changes: [String: Any] = [:]) throws {
    let data = try #require(pullRequests[source])
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["id"] = id
    object.merge(changes) { _, new in new }
    pullRequests[id] = try JSONSerialization.data(withJSONObject: object)
  }

  func respond(_ body: [String: Any]) -> StubURLProtocol.Stub {
    let query = body["query"] as? String ?? ""
    let variables = body["variables"] as? [String: Any] ?? [:]
    let response: [String: Any]
    if query.hasPrefix("query Search") {
      let q = variables["q"] as? String ?? ""
      if let ids = searches[q] {
        // Issues come back as empty objects from a `... on PullRequest` selection.
        let nodes: [[String: Any]] = ids.map { $0 == "ISSUE" ? [:] : ["id": $0] }
        response = ["data": ["search": ["issueCount": issueCounts[q] ?? ids.count, "nodes": nodes]]]
      } else {
        response = [
          "data": ["search": NSNull()],
          "errors": [["message": "Invalid search: \(q)", "type": "INVALID", "path": ["search"]]],
        ]
      }
    } else if query.hasPrefix("query PullRequests") {
      let ids = variables["ids"] as? [String] ?? []
      response = [
        "data": [
          "viewer": ["login": "octo"],
          "rateLimit": ["cost": 1, "remaining": 4990 - ids.count, "limit": 5000, "resetAt": "2026-10-20T10:00:00Z"],
          "nodes": ids.map { id -> Any in
            pullRequests[id].flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
          },
        ]
      ]
    } else {
      return .init(status: 400, body: Data(#"{"message":"unexpected query"}"#.utf8))
    }
    return .init(body: try! JSONSerialization.data(withJSONObject: response))
  }

  func client() -> (GitHubClient, id: String) {
    let (session, id) = StubURLProtocol.session { _, body in respond(body) }
    return (GitHubClient(token: "t0ken", session: session), id)
  }
}

@Suite struct GitHubClientTests {
  let acme = SectionConfig(name: "Acme", color: .blue, query: "is:open author:@me org:acme")
  let all = SectionConfig(name: "All", color: .green, query: "is:pr is:open author:@me sort:created-asc")
  let broken = SectionConfig(name: "Broken", color: .red, query: "is:pr involves:nobody")

  func fake() throws -> FakeGitHub {
    try .fromFixtures(
      searches: [
        acme.effectiveQuery: ["PR_ready", "PR_failing", "ISSUE", "PR_auto"],
        all.effectiveQuery: ["PR_ready", "PR_draft", "PR_merged", "PR_weird", "PR_gone"],
      ],
      issueCounts: [all.effectiveQuery: 60])
  }

  @Test func fullRefreshSearchesInParallelThenLoadsEachPullRequestOnce() async throws {
    let (client, id) = try fake().client()
    let fetch = try await client.dashboard(sections: [acme, all, broken], now: Date(timeIntervalSince1970: 7))
    let requests = StubURLProtocol.recordedRequests(id)
    let bodies = try requests.map(jsonBody)

    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken" })
    let searchQueries = bodies.filter { ($0["query"] as? String)?.hasPrefix("query Search") == true }
      .compactMap { ($0["variables"] as? [String: Any])?["q"] as? String }
    #expect(Set(searchQueries) == [acme.effectiveQuery, all.effectiveQuery, broken.effectiveQuery])
    #expect(bodies.allSatisfy { !(($0["query"] as? String) ?? "").contains("org:acme") },
      "user input travels as variables, never inside the document")

    let nodeBatches = bodies.filter { ($0["query"] as? String)?.hasPrefix("query PullRequests") == true }
      .compactMap { ($0["variables"] as? [String: Any])?["ids"] as? [String] }
    #expect(nodeBatches.flatMap { $0 }.sorted() == ["PR_auto", "PR_draft", "PR_failing", "PR_gone", "PR_merged", "PR_ready", "PR_weird"],
      "each PR is loaded once even when several sections match it")

    #expect(fetch.viewerLogin == "octo")
    #expect(fetch.searchedAt == Date(timeIntervalSince1970: 7))
    #expect(fetch.results[acme.id]?.pullRequests.map(\.id) == ["PR_ready", "PR_failing", "PR_auto"])
    #expect(fetch.results[all.id]?.pullRequests.map(\.id) == ["PR_ready", "PR_draft", "PR_merged", "PR_weird"],
      "PR_gone has no node (deleted or no access) and is dropped")
    #expect(fetch.results[all.id]?.totalCount == 60)
    #expect(fetch.results[broken.id]?.pullRequests.isEmpty == true)
    #expect(fetch.results[broken.id]?.error?.hasPrefix("Invalid search") == true)
  }

  @Test func statusRefreshReadsKnownPullRequestsWithoutSearching() async throws {
    let (client, _) = try fake().client()
    let full = try await client.dashboard(sections: [acme], now: Date(timeIntervalSince1970: 1))

    var changed = try fake()
    try changed.setPullRequest("PR_failing", from: "PR_failing", ["state": "MERGED"])
    changed.pullRequests["PR_auto"] = nil
    changed.searches = [:]  // any search would now fail
    let (statusClient, id) = changed.client()

    let refreshed = try await statusClient.refreshStatuses(of: full, now: Date(timeIntervalSince1970: 2))
    let queries = try StubURLProtocol.recordedRequests(id).map(jsonBody).compactMap { $0["query"] as? String }
    #expect(queries.allSatisfy { $0.hasPrefix("query PullRequests") })
    #expect(refreshed.searchedAt == Date(timeIntervalSince1970: 1))
    #expect(refreshed.fetchedAt == Date(timeIntervalSince1970: 2))

    let prs = try #require(refreshed.results[acme.id]?.pullRequests)
    #expect(prs.map(\.id) == ["PR_ready", "PR_failing"])
    #expect(prs[1].state == .merged)
    let dashboard = Dashboard(fetch: refreshed, configs: [acme])
    #expect(dashboard.pullRequests(in: .mine).map(\.id) == ["PR_ready"], "merged elsewhere -> gone from the count")
  }

  @Test func mapsPullRequestFields() async throws {
    let (client, _) = try fake().client()
    let fetch = try await client.dashboard(sections: [acme, all])
    let prs = fetch.results.values.flatMap(\.pullRequests)
    func pr(_ id: String) throws -> PullRequest { try #require(prs.first { $0.id == id }) }

    let ready = try pr("PR_ready")
    #expect(ready.ci == CIStatus(rollup: .success, passed: 15, failed: 0, running: 0))
    #expect(ready.readiness == .ready)
    #expect(ready.canMergeNow)
    #expect(ready.review.decision == .approved)
    #expect(ready.repository.allowedMergeMethods == [.squash, .merge])
    #expect(!ready.isCrossRepository)

    let failing = try pr("PR_failing")
    #expect(failing.ci == CIStatus(rollup: .failure, passed: 10, failed: 2, running: 2))
    #expect(failing.readiness == .changesRequested)
    #expect(failing.review.reviewers.map(\.login) == ["bob", "alice", "carol", "acme/platform"])
    #expect(failing.review.reviewers.map(\.state) == [.changesRequested, .requested, .requested, .requested],
      "alice was re-requested, so her earlier approval no longer counts")
    #expect(failing.review.reviewers.last?.isTeam == true)

    let draft = try pr("PR_draft")
    #expect(draft.isCrossRepository)
    #expect(draft.ci == .none)
    #expect(draft.readiness == .draft)
    #expect(draft.repository.deletesBranchOnMerge)

    #expect(try pr("PR_merged").state == .merged)
    #expect(try pr("PR_auto").readiness == .autoMerge)
    #expect(try pr("PR_auto").merge.autoMerge?.method == .squash)

    let weird = try pr("PR_weird")
    #expect(weird.merge.status == .unknown)
    #expect(weird.merge.mergeable == .unknown)
    #expect(weird.review.decision == .notRequired)
  }

  @Test func batchesLargeNodeRequests() async throws {
    var fake = try fake()
    let ids = (0..<23).map { "PR_\($0)" }
    for id in ids { try fake.setPullRequest(id, from: "PR_ready") }
    fake.searches = [acme.effectiveQuery: ids]
    let (client, id) = fake.client()
    let fetch = try await client.dashboard(sections: [acme])
    #expect(fetch.results[acme.id]?.pullRequests.map(\.id) == ids, "order follows the search, not the batches")
    #expect(StubURLProtocol.recordedRequests(id).count == 1 + 3)
    #expect(fetch.rateLimit?.cost == 3)
    #expect(fetch.rateLimit?.remaining == 4980)
  }

  @Test func decodesDetail() async throws {
    let (session, _) = StubURLProtocol.session(.init(body: try Fixture.data("detail")))
    let detail = try await GitHubClient(token: "t", session: session).detail(pullRequestID: "PR_1")

    #expect(detail.unresolvedThreads == 2)
    #expect(detail.checks.map(\.outcome) == [.failed, .failed, .failed, .running, .passed, .skipped])
    #expect(detail.checks.first?.displayName == "CI / Tests")
    #expect(detail.checks.first?.isRequired == true)
    #expect(detail.checks.first?.duration == 252)
    #expect(detail.failedWorkflowRunIDs == [11, 12])
    #expect(detail.checks.first { $0.name == "Deploy preview" }?.url == nil, "empty URL is not a link")
    #expect(detail.permissions.canMergeAsAdmin)
    #expect(detail.canMergeAsAdmin(.make(status: .blocked)))
    #expect(!detail.canMergeAsAdmin(.make(status: .clean)), "no admin path when a normal merge works")
    #expect(!detail.canMergeAsAdmin(.make(mergeable: .conflicting, status: .dirty)))
  }

  static let httpCases: [(Int, [String: String], GitHubError)] = [
    (401, [:], .unauthorized),
    (403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "0"], .rateLimited(resetAt: Date(timeIntervalSince1970: 0))),
    (502, [:], .http(status: 502, message: "Bad gateway")),
  ]

  @Test(arguments: httpCases)
  func transportErrorsFailTheWholeRefresh(status: Int, headers: [String: String], expected: GitHubError) async throws {
    let body = Data(#"{"message":"Bad gateway"}"#.utf8)
    let (session, _) = StubURLProtocol.session(.init(status: status, headers: headers, body: body))
    await #expect(throws: expected) {
      try await GitHubClient(token: "t", session: session).dashboard(sections: [acme, all])
    }
  }

  @Test func surfacesMutationErrors() async throws {
    let body = Data(#"{"data":{"mergePullRequest":null},"errors":[{"message":"Head branch was modified"}]}"#.utf8)
    let (session, _) = StubURLProtocol.session(.init(body: body))
    await #expect(throws: GitHubError.graphQL(["Head branch was modified"])) {
      try await GitHubClient(token: "t", session: session).merge(.make(), method: .squash)
    }
  }
}

func jsonBody(_ request: URLRequest) throws -> [String: Any] {
  let body = try #require(request.httpBody)
  return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
