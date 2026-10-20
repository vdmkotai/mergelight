import Foundation

/// Thin transport over GitHub's GraphQL and REST APIs.
///
/// Stateless and `Sendable`: requests and JSON decoding run off the main actor, and the app keeps a
/// single instance per token.
public struct GitHubClient: Sendable {
  public static let apiURL = URL(string: "https://api.github.com")!

  private let token: String
  private let session: URLSession

  public init(token: String, session: URLSession = .gitHub) {
    self.token = token
    self.session = session
  }

  /// Runs a GraphQL operation and returns `data` together with any partial errors.
  ///
  /// GitHub can answer with both: the dashboard query keeps working when one section's search is
  /// invalid, and the caller attributes each error to its alias.
  @concurrent
  public func graphQL<Response: Decodable & Sendable>(
    _ query: String, variables: [String: GraphQLVariable] = [:], as type: Response.Type
  ) async throws(GitHubError) -> (data: Response, errors: [GraphQLError]) {
    var request = makeRequest(path: "graphql", method: "POST")
    request.httpBody = try encode(GraphQLRequestBody(query: query, variables: variables))
    let data = try await send(request)

    let envelope: GraphQLEnvelope<Response>
    do {
      envelope = try JSONDecoder.gitHub.decode(GraphQLEnvelope<Response>.self, from: data)
    } catch {
      throw .decoding(String(describing: error))
    }
    let errors = envelope.errors ?? []
    guard let payload = envelope.data else {
      if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw .rateLimited(resetAt: nil) }
      throw .graphQL(errors.map(\.message))
    }
    return (payload, errors)
  }

  /// Fire-and-check REST call for endpoints GraphQL doesn't cover.
  @concurrent
  public func rest(_ method: String, _ path: String, body: [String: String]? = nil)
    async throws(GitHubError)
  {
    var request = makeRequest(path: path, method: method)
    if let body { request.httpBody = try encode(body) }
    _ = try await send(request)
  }

  // MARK: - Plumbing

  private func makeRequest(path: String, method: String) -> URLRequest {
    var request = URLRequest(url: Self.apiURL.appending(path: path))
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
  }

  private func encode(_ value: some Encodable) throws(GitHubError) -> Data {
    do { return try JSONEncoder().encode(value) } catch { throw .decoding(String(describing: error)) }
  }

  private func send(_ request: URLRequest) async throws(GitHubError) -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw GitHubError(error)
    } catch {
      throw .network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw .network("No HTTP response") }
    switch http.statusCode {
    case 200..<300:
      return data
    case 401:
      throw .unauthorized
    case 403, 429:
      if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
        || http.value(forHTTPHeaderField: "retry-after") != nil
      {
        // Secondary limits send retry-after (seconds); primary ones send the reset epoch.
        let retryAfter = http.value(forHTTPHeaderField: "retry-after")
          .flatMap(TimeInterval.init).map { Date.now.addingTimeInterval($0) }
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
          .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        throw .rateLimited(resetAt: retryAfter ?? reset)
      }
      throw .http(status: http.statusCode, message: Self.message(from: data))
    default:
      throw .http(status: http.statusCode, message: Self.message(from: data))
    }
  }

  private static func message(from data: Data) -> String {
    struct Body: Decodable { let message: String? }
    return (try? JSONDecoder().decode(Body.self, from: data))?.message ?? ""
  }
}

extension URLSession {
  /// No disk cache, short timeouts: stale API data is worse than a quick retry.
  public static let gitHub: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = [
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "Mergelight",
    ]
    return URLSession(configuration: configuration)
  }()
}

extension JSONDecoder {
  static let gitHub: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
