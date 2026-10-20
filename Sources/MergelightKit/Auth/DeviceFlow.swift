import Foundation

/// GitHub OAuth device flow: the app shows a code, the user enters it on github.com.
///
/// Needs the client ID of an OAuth App with device flow enabled. Device flow has no client
/// secret, so the ID can ship in the open-source binary.
public struct DeviceFlow: Sendable {
  public static let scopes = "repo read:org"

  public struct Code: Sendable, Equatable {
    public let userCode: String
    public let verificationURL: URL
    let deviceCode: String
    let interval: Int
    public let expiresAt: Date
  }

  public enum Failure: Error, LocalizedError, Equatable {
    case expired
    case denied
    case server(String)

    public var errorDescription: String? {
      switch self {
      case .expired: "The code expired. Start again."
      case .denied: "Access was denied on GitHub."
      case .server(let message): message
      }
    }
  }

  private let clientID: String
  private let session: URLSession

  public init(clientID: String, session: URLSession = .gitHub) {
    self.clientID = clientID
    self.session = session
  }

  public func start() async throws -> Code {
    struct Response: Decodable {
      let device_code: String
      let user_code: String
      let verification_uri: URL
      let expires_in: Int
      let interval: Int
    }
    let response: Response = try await post(
      "https://github.com/login/device/code", ["client_id": clientID, "scope": Self.scopes])
    return Code(
      userCode: response.user_code, verificationURL: response.verification_uri,
      deviceCode: response.device_code, interval: response.interval,
      expiresAt: .now.addingTimeInterval(TimeInterval(response.expires_in)))
  }

  /// Polls until the user approves, then returns the access token. Cancel the task to stop.
  public func waitForToken(_ code: Code) async throws -> String {
    struct Response: Decodable {
      let access_token: String?
      let error: String?
      let error_description: String?
      let interval: Int?
    }
    var interval = max(code.interval, 5)
    while Date.now < code.expiresAt {
      try await Task.sleep(for: .seconds(interval))
      let response: Response = try await post(
        "https://github.com/login/oauth/access_token",
        [
          "client_id": clientID, "device_code": code.deviceCode,
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
      if let token = response.access_token { return token }
      switch response.error {
      case "authorization_pending": continue
      case "slow_down": interval = response.interval ?? interval + 5
      case "expired_token": throw Failure.expired
      case "access_denied": throw Failure.denied
      default: throw Failure.server(response.error_description ?? response.error ?? "Unknown error")
      }
    }
    throw Failure.expired
  }

  private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw Failure.server("GitHub returned HTTP \(http.statusCode)")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}
