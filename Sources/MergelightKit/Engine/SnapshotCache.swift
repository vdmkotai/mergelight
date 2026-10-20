import Foundation

/// Persists the last successful fetch so the panel and the menu bar count are correct the moment
/// the app launches, before the first network round trip.
public struct SnapshotCache: Sendable {
  private static let formatVersion = 1

  private struct Envelope: Codable {
    let version: Int
    let fetch: DashboardFetch
  }

  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static var defaultURL: URL {
    URL.applicationSupportDirectory
      .appending(path: "Mergelight", directoryHint: .isDirectory)
      .appending(path: "snapshot.json")
  }

  /// Returns nil for a missing, corrupt or outdated file; the cache is only an optimization.
  public func load() -> DashboardFetch? {
    guard let data = try? Data(contentsOf: fileURL),
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      envelope.version == Self.formatVersion
    else { return nil }
    return envelope.fetch
  }

  public func save(_ fetch: DashboardFetch) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(Envelope(version: Self.formatVersion, fetch: fetch))
    try data.write(to: fileURL, options: [.atomic])
  }

  public func clear() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
