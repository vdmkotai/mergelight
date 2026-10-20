import Foundation
import Testing
import os

@testable import MergelightKit

enum Fixture {
  static func data(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}

extension PullRequest {
  /// Builds a PR with sensible defaults; tests override only what they assert on.
  static func make(
    id: String = "PR_1", number: Int = 1, state: State = .open, isDraft: Bool = false,
    headRefOid: String = "abc", review: ReviewSummary = .empty,
    mergeable: MergeInfo.Mergeable = .mergeable, status: MergeInfo.Status = .clean,
    ci: CIStatus = .none, autoMerge: MergeInfo.AutoMerge? = nil, viewerCanMergeAsAdmin: Bool = false,
    allowed: [MergeMethod] = [.squash, .merge], viewerDefault: MergeMethod = .merge
  ) -> PullRequest {
    PullRequest(
      id: id, number: number, title: "PR \(number)",
      url: URL(string: "https://github.com/acme/api/pull/\(number)")!, state: state,
      isDraft: isDraft, createdAt: .distantPast, updatedAt: .distantPast,
      author: Person(login: "octo", avatarURL: nil), headRefName: "feature/\(number)",
      headRefOid: headRefOid, baseRefName: "main", isCrossRepository: false,
      repository: Repository(
        id: "R_1", owner: "acme", name: "api", url: URL(string: "https://github.com/acme/api")!,
        allowedMergeMethods: allowed, viewerDefaultMergeMethod: viewerDefault,
        autoMergeAllowed: true, deletesBranchOnMerge: false),
      ci: ci, review: review,
      merge: MergeInfo(mergeable: mergeable, status: status, autoMerge: autoMerge),
      commentCount: 0)
  }
}

extension CIStatus {
  static func passing(_ n: Int) -> CIStatus { CIStatus(rollup: .success, passed: n, failed: 0, running: 0) }
  static func failing(_ n: Int, of total: Int) -> CIStatus {
    CIStatus(rollup: .failure, passed: total - n, failed: n, running: 0)
  }
  static func running(_ n: Int, of total: Int) -> CIStatus {
    CIStatus(rollup: .pending, passed: total - n, failed: 0, running: n)
  }
}

extension ReviewSummary.Reviewer {
  static func user(_ login: String, _ state: ReviewSummary.ReviewerState) -> Self {
    Self(login: login, avatarURL: nil, state: state, isTeam: false)
  }
}

/// Serves canned responses to a `GitHubClient`, keyed per test so parallel tests don't collide.
final class StubURLProtocol: URLProtocol {
  struct Stub: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data
  }

  typealias Responder = @Sendable (_ request: URLRequest, _ body: [String: Any]) -> Stub

  private static let stubs = OSAllocatedUnfairLock<[String: Responder]>(initialState: [:])
  private static let requests = OSAllocatedUnfairLock<[String: [URLRequest]]>(initialState: [:])
  private static let header = "X-Stub-ID"

  /// A session whose every request is answered with `stub`.
  static func session(_ stub: Stub) -> (URLSession, id: String) {
    session { _, _ in stub }
  }

  /// A session that answers each request via `responder`, which gets the decoded JSON body.
  static func session(_ responder: @escaping Responder) -> (URLSession, id: String) {
    let id = UUID().uuidString
    stubs.withLock { $0[id] = responder }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [header: id]
    return (URLSession(configuration: configuration), id)
  }

  static func recordedRequests(_ id: String) -> [URLRequest] { requests.withLock { $0[id] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: Self.header) ?? ""
    var recorded = request
    // URLSession moves bodies into a stream before protocols see them.
    if recorded.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        guard read > 0 else { break }
        data.append(buffer, count: read)
      }
      stream.close()
      recorded.httpBody = data
    }
    let finished = recorded
    Self.requests.withLock { $0[id, default: []].append(finished) }

    guard let responder = Self.stubs.withLock({ $0[id] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let json = finished.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let stub = responder(finished, json ?? [:])
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
