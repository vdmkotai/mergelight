import MergelightKit
import SwiftUI

/// One PR: title and branch on the left, then the CI, review and merge columns.
/// Hovering swaps the merge pill for the action that unblocks the PR, if any.
struct PullRequestRow: View {
  let pr: PullRequest
  let color: Color
  let model: AppModel
  @State private var hovering = false

  private var busy: AppModel.Busy? { model.busy[pr.id] }
  private var isExpanded: Bool { model.expanded.contains(pr.id) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ColorStrip(color: color).padding(.vertical, 3)
        titleBlock.padding(.leading, 8)
        CICell(ci: pr.ci).frame(width: Layout.ciColumn)
        ReviewCell(review: pr.review).frame(width: Layout.reviewColumn)
        mergeCell.frame(width: Layout.mergeColumn)
      }
      .padding(.vertical, 5)
      .padding(.horizontal, Layout.rowInset)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(Color.primary.opacity(hovering ? 0.07 : isExpanded ? 0.035 : 0)))
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture { model.rowClicked(pr) }
      .contextMenu { RowContextMenu(pr: pr, model: model) }

      if isExpanded {
        PullRequestDetailView(pr: pr, model: model)
          .padding(.leading, 19)
          .padding(.trailing, Layout.rowInset)
          .padding(.bottom, 6)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 6)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        // Verbatim: a localized Int would render #2591 as "#2 591".
        Text(verbatim: "#\(pr.number)").foregroundStyle(.secondary).monospacedDigit()
        Text(pr.title).lineLimit(1).truncationMode(.tail)
      }
      .font(.system(size: 13))
      .opacity(pr.isDraft ? 0.7 : 1)
      TimelineView(.periodic(from: .now, by: 60)) { context in
        Text("\(pr.repository.name) · \(pr.headRefName) · \(pr.updatedAt.compactAge(now: context.date))")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .trailing) {
      if hovering && busy == nil { quickActions }
    }
    .help("\(pr.repository.nameWithOwner)#\(pr.number)\n\(pr.title)\n\(pr.headRefName) → \(pr.baseRefName)")
  }

  private var quickActions: some View {
    HStack(spacing: 0) {
      IconButton("doc.on.doc", help: "Copy branch name") { model.copyBranch(pr) }
      IconButton(isExpanded ? "chevron.up" : "chevron.down", help: isExpanded ? "Hide details" : "Show checks and reviewers (⌥-click)") {
        model.toggleExpanded(pr)
      }
    }
    .padding(2)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    .padding(.trailing, 4)
  }

  @ViewBuilder private var mergeCell: some View {
    if let busy {
      HStack(spacing: 4) {
        ProgressView().controlSize(.mini)
        Text(busy.title).font(.system(size: 11)).foregroundStyle(.secondary)
      }
    } else if hovering && pr.canMergeNow {
      MergeButton(pr: pr, model: model)
    } else if hovering && pr.readiness == .behind {
      Button("Update") { model.updateBranch(pr) }
        .controlSize(.small)
        .help("Merge \(pr.baseRefName) into \(pr.headRefName)")
    } else if hovering && pr.isDraft {
      Button("Ready") { model.markReady(pr) }
        .controlSize(.small)
        .help("Mark ready for review")
    } else {
      ReadinessPill(readiness: pr.readiness)
    }
  }
}

/// Split button: the main part merges with the default method, the arrow picks another one.
struct MergeButton: View {
  let pr: PullRequest
  let model: AppModel

  var body: some View {
    let method = pr.defaultMergeMethod(preferred: model.settings.preferredMergeMethod)
    Menu {
      ForEach(pr.repository.allowedMergeMethods) { option in
        Button(option.actionTitle) { model.requestMerge(pr, method: option) }
      }
    } label: {
      Text(method.shortTitle)
    } primaryAction: {
      model.requestMerge(pr, method: method)
    }
    .menuStyle(.button)
    .buttonStyle(.borderedProminent)
    .tint(pr.readiness == .ready ? .green : .orange)
    .controlSize(.small)
    .fixedSize()
    .help(model.settings.mergeConfirmation == .oneClick && pr.readiness == .ready
      ? "\(method.actionTitle) now" : "\(method.actionTitle)…")
  }
}

struct RowContextMenu: View {
  let pr: PullRequest
  let model: AppModel

  var body: some View {
    Button("Open on GitHub") { model.open(pr) }
    Button("Copy Link") { model.copyURL(pr) }
    Button("Copy Branch Name") { model.copyBranch(pr) }
    Divider()
    if pr.canMergeNow {
      ForEach(pr.repository.allowedMergeMethods) { method in
        Button("\(method.actionTitle)…") { model.requestMerge(pr, method: method) }
      }
    }
    if pr.merge.status == .behind {
      Button("Update Branch") { model.updateBranch(pr) }
    }
    if pr.ci.failed > 0 {
      Button("Re-run Failed Checks") { model.rerunFailedChecks(pr) }
    }
    if pr.isDraft {
      Button("Mark Ready for Review") { model.markReady(pr) }
    }
    if pr.merge.autoMerge != nil {
      Button("Disable Auto-merge") { model.setAutoMerge(pr, enabled: false) }
    } else if pr.repository.autoMergeAllowed && !pr.canMergeNow && !pr.isDraft {
      Button("Enable Auto-merge") { model.setAutoMerge(pr, enabled: true) }
    }
  }
}

struct IconButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  init(_ symbol: String, help: String, action: @escaping () -> Void) {
    self.symbol = symbol
    self.help = help
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .medium))
        .frame(width: 22, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
  }
}
