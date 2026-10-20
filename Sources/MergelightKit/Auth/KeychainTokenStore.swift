import Foundation
import Security

/// Stores the GitHub token in the login keychain. Nothing else on disk ever holds it.
public struct KeychainTokenStore: Sendable {
  public enum Failure: Error, LocalizedError {
    case status(OSStatus)
    public var errorDescription: String? {
      switch self {
      case .status(let status):
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
      }
    }
  }

  private let service: String
  private let account: String

  public init(service: String = "io.github.vdmkotai.mergelight", account: String = "github.com") {
    self.service = service
    self.account = account
  }

  private var baseQuery: [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
  }

  public func read() throws -> String? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    case errSecItemNotFound:
      return nil
    default:
      throw Failure.status(status)
    }
  }

  public func write(_ token: String) throws {
    let data = Data(token.utf8)
    let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw Failure.status(update) }

    var attributes = baseQuery
    attributes[kSecValueData] = data
    attributes[kSecAttrLabel] = "Mergelight GitHub token"
    attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    let add = SecItemAdd(attributes as CFDictionary, nil)
    guard add == errSecSuccess else { throw Failure.status(add) }
  }

  public func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure.status(status)
    }
  }
}
