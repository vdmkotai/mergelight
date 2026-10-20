import MergelightKit
import SwiftUI

/// Expanded row: individual checks, reviewers and the actions that need per-PR permissions.
struct PullRequestDetailView: View {
  let pr: PullRequest
  let model: AppModel
  @State private var showPassed = false

  private var state: AppModel.DetailState? { model.details[pr.id] }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let detail = state?.detail {
        HStack(alignment: .top, spacing: 16) {
          checks(detail).frame(maxWidth: .infinity, alignment: .leading)
          reviewers(detail).frame(width: 190, alignment: .leading)
        }
        actions(detail)
      } else if case .failed(let message, _) = state {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          Text(message).foregroundStyle(.secondary).lineLimit(2)
          Spacer()
          Button("Retry") { model.loadDetail(pr, force: true) }.controlSize(.small)
        }
        .font(.system(size: 12))
      } else {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading checks…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
  }

  // MARK: Checks

  private func checks(_ detail: PullRequestDetail) -> some View {
    let failed = detail.checks(.failed)
    let running = detail.checks(.running)
    let rest = detail.checks.filter { $0.outcome != .failed && $0.outcome != .running }
    return VStack(alignment: .leading, spacing: 3) {
      Header(text: checksTitle(detail))
      if detail.checks.isEmpty {
        Text("No checks on the latest commit").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ForEach(failed + running) { CheckRow(check: $0, model: model) }
      if !rest.isEmpty {
        Button {
          showPassed.toggle()
        } label: {
          HStack(spacing: 4) {
            Image(systemName: showPassed ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
            Text("\(rest.count) passed or skipped")
          }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        if showPassed {
          ForEach(rest) { CheckRow(check: $0, model: model) }
        }
      }
    }
  }

  private func checksTitle(_ detail: PullRequestDetail) -> String {
    var parts: [String] = []
    let failed = detail.checks(.failed).count
    let running = detail.checks(.running).count
    let passed = detail.checks.count - failed - running
    if passed > 0 { parts.append("\(passed) passed") }
    if failed > 0 { parts.append("\(failed) failed") }
    if running > 0 { parts.append("\(running) running") }
    return parts.isEmpty ? "Checks" : "Checks · " + parts.joined(separator: ", ")
  }

  // MARK: Reviewers

  private func reviewers(_ detail: PullRequestDetail) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Header(text: reviewTitle)
      if pr.review.reviewers.isEmpty {
        Text("No reviewers").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ForEach(pr.review.reviewers) { reviewer in
        HStack(spacing: 6) {
          ReviewerAvatar(reviewer: reviewer, size: 16)
          Text(reviewer.login).font(.system(size: 12)).lineLimit(1)
          Spacer(minLength: 4)
          Text(reviewer.state.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      if detail.unresolvedThreads > 0 {
        Label("\(detail.unresolvedThreads) unresolved thread\(detail.unresolvedThreads == 1 ? "" : "s")",
          systemImage: "bubble.left.and.exclamationmark.bubble.right")
          .font(.system(size: 11))
          .foregroundStyle(.orange)
          .padding(.top, 2)
      }
    }
  }

  private var reviewTitle: String {
    switch pr.review.decision {
    case .approved: "Reviews · approved"
    case .changesRequested: "Reviews · changes requested"
    case .reviewRequired: "Reviews · required"
    case .notRequired: "Reviews"
    }
  }

  // MARK: Actions

  @ViewBuilder private func actions(_ detail: PullRequestDetail) -> some View {
    let permissions = detail.permissions
    HStack(spacing: 6) {
      if !detail.failedWorkflowRunIDs.isEmpty {
        Button("Re-run failed", systemImage: "arrow.clockwise") { model.rerunFailedChecks(pr) }
          .tint(.red)
      }
      if pr.merge.status == .behind && permissions.canUpdateBranch {
        Button("Update branch", systemImage: "arrow.triangle.merge") { model.updateBranch(pr) }
      }
      if pr.isDraft {
        Button("Ready for review", systemImage: "eye") { model.markReady(pr) }
      }
      if pr.merge.autoMerge != nil && permissions.canDisableAutoMerge {
        Button("Disable auto-merge", systemImage: "bolt.slash") { model.setAutoMerge(pr, enabled: false) }
      } else if pr.merge.autoMerge == nil && permissions.canEnableAutoMerge && pr.repository.autoMergeAllowed
        && !pr.canMergeNow && !pr.isDraft
      {
        Button("Auto-merge", systemImage: "bolt") { model.setAutoMerge(pr, enabled: true) }
          .help("Merge automatically once requirements are met")
      }
      if detail.canMergeAsAdmin(pr) {
        Button("Merge as admin…", systemImage: "exclamationmark.shield") {
          model.requestMerge(pr, asAdmin: true)
        }
        .help("Bypass branch protection")
      }
      Spacer()
      Button("Open PR", systemImage: "arrow.up.right.square") { model.open(pr) }
    }
    .controlSize(.small)
    .disabled(model.busy[pr.id] != nil)
  }
}

private struct Header: View {
  let text: String
  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.4)
      .foregroundStyle(.tertiary)
      .padding(.bottom, 2)
  }
}

private struct CheckRow: View {
  let check: PullRequestDetail.Check
  let model: AppModel

  var body: some View {
    Button {
      if let url = check.url { model.open(url) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol).foregroundStyle(color).frame(width: 12)
        Text(check.displayName).lineLimit(1).truncationMode(.middle)
        if check.isRequired {
          Text("required")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .background(Capsule().stroke(Color.secondary.opacity(0.4)))
        }
        Spacer(minLength: 6)
        if let duration = check.duration {
          Text(duration.compactDuration).foregroundStyle(.tertiary).monospacedDigit()
        }
      }
      .font(.system(size: 12))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(check.url == nil)
    .help(check.url == nil ? check.displayName : "Open \(check.displayName)")
  }

  private var symbol: String {
    switch check.outcome {
    case .failed: "xmark.circle.fill"
    case .running: "circle.dotted"
    case .passed: "checkmark.circle.fill"
    case .neutral: "minus.circle"
    case .skipped: "arrow.uturn.right.circle"
    }
  }

  private var color: Color {
    switch check.outcome {
    case .failed: .red
    case .running: .orange
    case .passed: .green
    case .neutral, .skipped: .secondary
    }
  }
}
