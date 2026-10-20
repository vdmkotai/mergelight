import Foundation

/// A user-defined group of pull requests: a GitHub search query with a name, color and position.
///
/// Sections are evaluated top to bottom and a PR lands in the first section that matches it, so a
/// broad catch-all section can sit below narrower ones.
public struct SectionConfig: Codable, Hashable, Identifiable, Sendable {
  public enum Tab: String, Codable, CaseIterable, Sendable, Identifiable {
    case mine, review
    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .mine: "Mine"
      case .review: "To review"
      }
    }
  }

  public enum RepoFilterMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case all, include, exclude
    public var id: String { rawValue }
    public var title: String {
      switch self {
      case .all: "All repositories"
      case .include: "Only listed repositories"
      case .exclude: "All except listed"
      }
    }
  }

  public var id: UUID
  public var name: String
  public var color: SectionColor
  /// GitHub search syntax, e.g. `is:pr is:open author:@me org:acme`.
  public var query: String
  public var tab: Tab
  public var repoFilterMode: RepoFilterMode
  /// `owner/name` entries used by `repoFilterMode`.
  public var repos: [String]
  public var isEnabled: Bool
  public var hideWhenEmpty: Bool
  public var countsInMenuBar: Bool

  public init(
    id: UUID = UUID(), name: String, color: SectionColor, query: String, tab: Tab = .mine,
    repoFilterMode: RepoFilterMode = .all, repos: [String] = [], isEnabled: Bool = true,
    hideWhenEmpty: Bool = false, countsInMenuBar: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.query = query
    self.tab = tab
    self.repoFilterMode = repoFilterMode
    self.repos = repos
    self.isEnabled = isEnabled
    self.hideWhenEmpty = hideWhenEmpty
    self.countsInMenuBar = countsInMenuBar ?? (tab == .mine)
  }

  /// Valid `owner/name` entries; anything else would turn into a broken search qualifier.
  public var normalizedRepos: [String] {
    repos.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { entry in
        let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
      }
  }

  /// The query actually sent to GitHub: user text plus the repo filter and sane defaults.
  public var effectiveQuery: String {
    var terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let lowered = Set(terms.map { $0.lowercased() })
    if !lowered.contains("is:pr") && !lowered.contains("type:pr") {
      terms.insert("is:pr", at: 0)
    }
    if !lowered.contains(where: { $0.hasPrefix("sort:") }) {
      terms.append("sort:updated-desc")
    }
    let repos = normalizedRepos
    switch repoFilterMode {
    case .all: break
    case .include: terms += repos.map { "repo:\($0)" }
    case .exclude: terms += repos.map { "-repo:\($0)" }
    }
    return terms.joined(separator: " ")
  }

  /// The same search on github.com, for the "more on GitHub" link.
  public var webSearchURL: URL {
    var components = URLComponents(string: "https://github.com/pulls")!
    components.queryItems = [URLQueryItem(name: "q", value: effectiveQuery)]
    return components.url!
  }

  // Settings written by older versions may lack newer keys; fall back to defaults instead of
  // throwing away the user's sections.
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = c.value(.name, default: "Section")
    color = c.value(.color, default: .blue)
    query = c.value(.query, default: "is:pr is:open author:@me")
    tab = c.value(.tab, default: .mine)
    repoFilterMode = c.value(.repoFilterMode, default: .all)
    repos = c.value(.repos, default: [])
    isEnabled = c.value(.isEnabled, default: true)
    hideWhenEmpty = c.value(.hideWhenEmpty, default: false)
    countsInMenuBar = c.value(.countsInMenuBar, default: tab == .mine)
  }
}

public enum SectionColor: String, Codable, CaseIterable, Sendable, Identifiable {
  case blue, green, orange, purple, pink, teal, yellow, red, gray
  public var id: String { rawValue }
}

extension KeyedDecodingContainer {
  /// Decodes a key leniently: missing, null or unrecognised values become `fallback`.
  func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
    ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
  }
}

/// Sections a fresh install starts with, built from the viewer's organizations.
public enum DefaultSections {
  public static func make(login: String, organizations: [String]) -> [SectionConfig] {
    let orgColors: [SectionColor] = [.blue, .purple, .orange, .teal, .pink, .yellow]
    var sections: [SectionConfig] = []
    for (index, org) in organizations.enumerated() {
      sections.append(
        SectionConfig(
          name: org, color: orgColors[index % orgColors.count],
          query: "is:pr is:open author:@me archived:false org:\(org)", hideWhenEmpty: true))
    }
    sections.append(
      SectionConfig(
        name: "Personal", color: .green,
        query: "is:pr is:open author:@me archived:false user:\(login)"))
    // Catches PRs to other people's repos, e.g. open-source contributions.
    sections.append(
      SectionConfig(
        name: "Elsewhere", color: .gray, query: "is:pr is:open author:@me archived:false",
        hideWhenEmpty: true))
    sections.append(
      SectionConfig(
        name: "Review requests", color: .yellow,
        query: "is:pr is:open archived:false draft:false review-requested:@me", tab: .review))
    return sections
  }
}
