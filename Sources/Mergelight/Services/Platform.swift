import AppKit
import ServiceManagement

enum LoginItem {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}

enum AppInfo {
  /// Client ID of the OAuth App used for "Sign in with GitHub". Set at build time via the
  /// `GITHUB_CLIENT_ID` variable of scripts/build-app.sh; empty hides the option.
  static var gitHubClientID: String? {
    let value = Bundle.main.object(forInfoDictionaryKey: "MergelightGitHubClientID") as? String
    return value?.isEmpty == false ? value : nil
  }

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }
}

/// Small avatar images, shared by every row. Memory cache plus the URL cache on disk.
@MainActor
final class AvatarCache {
  static let shared = AvatarCache()

  private let memory = NSCache<NSURL, NSImage>()
  private var inFlight: [URL: Task<NSImage?, Never>] = [:]
  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.urlCache = URLCache(
      memoryCapacity: 2 << 20, diskCapacity: 20 << 20,
      directory: URL.cachesDirectory.appending(path: "Mergelight/Avatars"))
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: configuration)
  }()

  func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

  func image(for url: URL) async -> NSImage? {
    if let image = cached(url) { return image }
    if let task = inFlight[url] { return await task.value }
    let task = Task { [session] () -> NSImage? in
      guard let (data, _) = try? await session.data(from: url) else { return nil }
      return NSImage(data: data)
    }
    inFlight[url] = task
    let image = await task.value
    inFlight[url] = nil
    if let image { memory.setObject(image, forKey: url as NSURL) }
    return image
  }
}
