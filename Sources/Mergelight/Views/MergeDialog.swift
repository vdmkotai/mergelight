import MergelightKit
import SwiftUI

/// Confirmation shown over the panel before a merge.
struct MergeDialog: View {
  @Binding var draft: AppModel.MergeDraft
  let onCancel: () -> Void
  let onConfirm: () -> Void

  private var pr: PullRequest { draft.pr }

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .onTapGesture(perform: onCancel)

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: draft.asAdmin ? "Merge #\(pr.number) as admin?" : "Merge #\(pr.number)?")
            .font(.headline)
          Text(pr.title).font(.system(size: 13)).lineLimit(2)
          Text("\(pr.headRefName) → \(pr.baseRefName) · \(pr.repository.nameWithOwner)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        if pr.repository.allowedMergeMethods.count > 1 {
          Picker("Method", selection: $draft.method) {
            ForEach(pr.repository.allowedMergeMethods) { Text($0.actionTitle).tag($0) }
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
        }

        if pr.repository.deletesBranchOnMerge {
          Label("GitHub deletes the branch after merging.", systemImage: "trash")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else if !pr.isCrossRepository {
          Toggle("Delete branch \(pr.headRefName)", isOn: $draft.deleteBranch)
            .font(.system(size: 12))
        }

        ForEach(warnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        }

        HStack {
          Spacer()
          Button("Cancel", role: .cancel, action: onCancel)
            .keyboardShortcut(.cancelAction)
          Button(draft.method.actionTitle, action: onConfirm)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(draft.asAdmin ? .red : .green)
        }
      }
      .padding(16)
      .frame(width: 380)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
      .shadow(radius: 20)
    }
  }

  private var warnings: [String] {
    var warnings: [String] = []
    if draft.asAdmin { warnings.append("This bypasses branch protection rules.") }
    if pr.ci.failed > 0 { warnings.append("\(pr.ci.failed) check\(pr.ci.failed == 1 ? "" : "s") failed.") }
    if pr.ci.running > 0 { warnings.append("\(pr.ci.running) check\(pr.ci.running == 1 ? " is" : "s are") still running.") }
    if pr.review.decision == .changesRequested { warnings.append("Changes were requested.") }
    return warnings
  }
}
