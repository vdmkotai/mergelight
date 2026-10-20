import MergelightKit
import SwiftUI

/// CI column: ✓ total, a progress ring while running, or the number of failures.
struct CICell: View {
  let ci: CIStatus

  var body: some View {
    Group {
      switch ci.rollup {
      case .none:
        Text("—").foregroundStyle(.tertiary)
      case .success:
        HStack(spacing: 3) {
          Image(systemName: "checkmark.circle.fill")
          Text("\(ci.total)")
        }
        .foregroundStyle(.green)
      case .failure:
        HStack(spacing: 3) {
          Image(systemName: "xmark.circle.fill")
          Text("\(ci.failed) failed")
          if ci.running > 0 { ProgressRing(fraction: fraction).frame(width: 9, height: 9) }
        }
        .foregroundStyle(.red)
      case .pending:
        HStack(spacing: 4) {
          ProgressRing(fraction: fraction).frame(width: 10, height: 10)
          Text("\(ci.finished)/\(ci.total)")
        }
        .foregroundStyle(.orange)
      }
    }
    .font(.system(size: 11, weight: .medium).monospacedDigit())
    .lineLimit(1)
    .help(tooltip)
  }

  private var fraction: Double { ci.total == 0 ? 0 : Double(ci.finished) / Double(ci.total) }

  private var tooltip: String {
    guard ci.rollup != .none else { return "No checks" }
    var parts: [String] = []
    if ci.failed > 0 { parts.append("\(ci.failed) failed") }
    if ci.running > 0 { parts.append("\(ci.running) running") }
    if ci.passed > 0 { parts.append("\(ci.passed) passed") }
    return parts.joined(separator: ", ")
  }
}

struct ProgressRing: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(lineWidth: 2).opacity(0.25)
      Circle()
        .trim(from: 0, to: max(0.06, fraction))
        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
  }
}

/// Review column: up to three reviewer avatars, each with a state badge.
struct ReviewCell: View {
  let review: ReviewSummary
  private let maxShown = 3

  var body: some View {
    if review.reviewers.isEmpty {
      Text(review.decision == .reviewRequired ? "needed" : "—")
        .font(.system(size: 11))
        .foregroundStyle(review.decision == .reviewRequired ? .secondary : .tertiary)
        .help(review.decision == .reviewRequired ? "Review required, nobody requested" : "No reviews")
    } else {
      HStack(spacing: -5) {
        ForEach(review.reviewers.prefix(maxShown)) { reviewer in
          ReviewerAvatar(reviewer: reviewer)
        }
        if review.reviewers.count > maxShown {
          Text("+\(review.reviewers.count - maxShown)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
        }
      }
      .help(review.reviewers.map { "\($0.login): \($0.state.title)" }.joined(separator: "\n"))
    }
  }
}

struct ReviewerAvatar: View {
  let reviewer: ReviewSummary.Reviewer
  var size: CGFloat = 18

  var body: some View {
    AvatarView(url: reviewer.avatarURL, login: reviewer.login, size: size, isTeam: reviewer.isTeam)
      .overlay(Circle().stroke(.background, lineWidth: 1.5))
      .overlay(alignment: .bottomTrailing) {
        ReviewBadge(state: reviewer.state).offset(x: 3, y: 2)
      }
      .padding(.trailing, 2)
  }
}

struct ReviewBadge: View {
  let state: ReviewSummary.ReviewerState

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 6, weight: .black))
      .foregroundStyle(.white)
      .frame(width: 10, height: 10)
      .background(Circle().fill(color))
      .overlay(Circle().stroke(.background, lineWidth: 1))
  }

  private var symbol: String {
    switch state {
    case .approved: "checkmark"
    case .changesRequested: "plusminus"
    case .requested: "ellipsis"
    case .commented: "text.bubble.fill"
    case .dismissed: "xmark"
    }
  }

  private var color: Color {
    switch state {
    case .approved: .green
    case .changesRequested: .red
    case .requested: .gray
    case .commented: .blue
    case .dismissed: .gray
    }
  }
}

extension ReviewSummary.ReviewerState {
  var title: String {
    switch self {
    case .approved: "approved"
    case .changesRequested: "changes requested"
    case .requested: "review requested"
    case .commented: "commented"
    case .dismissed: "dismissed"
    }
  }
}

struct ReadinessPill: View {
  let readiness: MergeReadiness

  var body: some View {
    Text(readiness.title)
      .font(.system(size: 10.5, weight: .semibold))
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .foregroundStyle(readiness.color)
      .background(Capsule().fill(readiness.color.opacity(0.15)))
  }
}
