import MergelightKit
import SwiftUI

enum Layout {
  static let panelWidth: CGFloat = 580
  static let ciColumn: CGFloat = 74
  static let reviewColumn: CGFloat = 76
  static let mergeColumn: CGFloat = 106
  static let rowInset: CGFloat = 8
}

extension SectionColor {
  var color: Color {
    switch self {
    case .blue: .blue
    case .green: .green
    case .orange: .orange
    case .purple: .purple
    case .pink: .pink
    case .teal: .teal
    case .yellow: .yellow
    case .red: .red
    case .gray: .gray
    }
  }
}

extension MergeReadiness {
  var color: Color {
    switch self {
    case .ready: .green
    case .unstable, .behind, .ciRunning: .orange
    case .autoMerge: .purple
    case .changesRequested, .ciFailing, .conflicts: .red
    case .needsReview, .blocked, .draft, .checking: .secondary
    }
  }
}

extension Date {
  /// "now", "5m", "2h", "3d", "4w", "5mo", "1y".
  func compactAge(now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(self))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
    case ..<(86_400 * 30): return "\(Int(seconds / (86_400 * 7)))w"
    case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
    default: return "\(Int(seconds / (86_400 * 365)))y"
    }
  }
}

extension TimeInterval {
  /// "38s", "4m 12s", "1h 3m".
  var compactDuration: String {
    let total = Int(self.rounded())
    if total < 60 { return "\(total)s" }
    if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
    return "\(total / 3600)h \(total % 3600 / 60)m"
  }
}

/// Section color strip on the left of a row.
struct ColorStrip: View {
  let color: Color
  var body: some View {
    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
  }
}

/// Round avatar with an initials fallback, loaded through the shared cache.
struct AvatarView: View {
  let url: URL?
  let login: String
  var size: CGFloat = 18
  var isTeam = false
  @State private var image: NSImage?

  init(url: URL?, login: String, size: CGFloat = 18, isTeam: Bool = false) {
    self.url = url
    self.login = login
    self.size = size
    self.isTeam = isTeam
    _image = State(initialValue: url.flatMap { AvatarCache.shared.cached($0) })
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high)
      } else if isTeam {
        Image(systemName: "person.2.fill")
          .font(.system(size: size * 0.45))
          .frame(width: size, height: size)
          .background(Color.secondary.opacity(0.3))
      } else {
        Text(login.prefix(2).uppercased())
          .font(.system(size: size * 0.42, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: size, height: size)
          .background(Color(hue: Self.hue(login), saturation: 0.55, brightness: 0.7))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .task(id: url) {
      guard let url, image == nil else { return }
      image = await AvatarCache.shared.image(for: url)
    }
  }

  private static func hue(_ login: String) -> Double {
    Double(login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
  }
}
