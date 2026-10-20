import Foundation

public enum GitHubError: Error, Equatable, Sendable, LocalizedError {
  /// Token missing, revoked or expired.
  case unauthorized
  case rateLimited(resetAt: Date?)
  /// No connection; the app keeps showing cached data and retries quietly.
  case offline
  case network(String)
  case http(status: Int, message: String)
  case graphQL([String])
  case decoding(String)

  public var errorDescription: String? {
    switch self {
    case .unauthorized:
      "GitHub rejected the token. Sign in again."
    case .rateLimited(let resetAt):
      if let resetAt {
        "GitHub rate limit reached. Resumes at \(resetAt.formatted(date: .omitted, time: .shortened))."
      } else {
        "GitHub rate limit reached."
      }
    case .offline:
      "You're offline."
    case .network(let message):
      message
    case .http(let status, let message):
      message.isEmpty ? "GitHub returned HTTP \(status)." : message
    case .graphQL(let messages):
      messages.joined(separator: "\n")
    case .decoding(let message):
      "Unexpected response from GitHub: \(message)"
    }
  }

  init(_ error: URLError) {
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff:
      self = .offline
    default:
      self = .network(error.localizedDescription)
    }
  }
}
