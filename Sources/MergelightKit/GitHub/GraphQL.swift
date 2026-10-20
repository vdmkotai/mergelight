import Foundation

public enum GraphQLVariable: Encodable, Sendable, Equatable {
  case string(String)
  case strings([String])

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .strings(let values): try container.encode(values)
    }
  }
}

struct GraphQLRequestBody: Encodable {
  let query: String
  let variables: [String: GraphQLVariable]
}

struct GraphQLEnvelope<Payload: Decodable>: Decodable {
  let data: Payload?
  let errors: [GraphQLError]?
}

public struct GraphQLError: Decodable, Sendable, Equatable {
  public let message: String
  public let type: String?
  /// First path element; for the dashboard query this is the section alias (`s0`, `s1`, ...).
  public let rootField: String?

  enum CodingKeys: String, CodingKey { case message, type, path }

  private enum PathElement: Decodable {
    case key(String)
    case index(Int)
    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let int = try? container.decode(Int.self) { self = .index(int) } else {
        self = .key(try container.decode(String.self))
      }
    }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    message = try c.decode(String.self, forKey: .message)
    type = try c.decodeIfPresent(String.self, forKey: .type)
    let path = (try? c.decodeIfPresent([PathElement].self, forKey: .path)) ?? nil
    if case .key(let key) = path?.first { rootField = key } else { rootField = nil }
  }

  public init(message: String, type: String? = nil, rootField: String? = nil) {
    self.message = message
    self.type = type
    self.rootField = rootField
  }
}

/// Decodes array elements one by one so a single odd node (an Issue in a PR search, a deleted
/// author, a value GitHub added last week) drops that element instead of the whole response.
struct Lossy<Element: Decodable>: Decodable {
  let value: Element?
  init(from decoder: any Decoder) throws {
    value = try? Element(from: decoder)
  }
}

struct Connection<Node: Decodable>: Decodable {
  let nodes: [Lossy<Node>]?
  var values: [Node] { nodes?.compactMap(\.value) ?? [] }
}

struct DynamicKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

extension Lossy: Sendable where Element: Sendable {}
extension Connection: Sendable where Node: Sendable {}
