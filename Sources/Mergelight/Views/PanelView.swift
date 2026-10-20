import MergelightKit
import SwiftUI

/// Root of the dropdown panel.
struct PanelView: View {
  @Bindable var model: AppModel
  let onSettings: () -> Void
  let onSizeChange: (CGSize) -> Void

  var body: some View {
    Group {
      switch model.session {
      case .loading:
        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
      case .signedOut:
        OnboardingView(model: model)
      case .signedIn:
        DashboardView(model: model, onSettings: onSettings)
      }
    }
    .frame(width: Layout.panelWidth)
    // Room for the dialog even when the list is short.
    .frame(minHeight: model.mergeDraft == nil ? 0 : 330, alignment: .top)
    .overlay {
      if let draft = model.mergeDraft {
        MergeDialog(
          draft: Binding(get: { model.mergeDraft ?? draft }, set: { model.mergeDraft = $0 }),
          onCancel: { model.mergeDraft = nil },
          onConfirm: { model.confirmMerge() })
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
  }
}

struct DashboardView: View {
  @Bindable var model: AppModel
  let onSettings: () -> Void
  @State private var listHeight: CGFloat = 0
  @State private var topHeight: CGFloat = 0
  @State private var bottomHeight: CGFloat = 0
  @FocusState private var filterFocused: Bool

  /// The list gets whatever the screen allows after header, banner and footer.
  private var listMaxHeight: CGFloat {
    max(160, model.panelMaxHeight - topHeight - bottomHeight)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        header
        if let banner = model.banner { BannerView(banner: banner) { model.dismissBanner() } }
        Divider()
      }
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { topHeight = $0 }
      list
      VStack(spacing: 0) {
        Divider()
        FooterView(model: model, onSettings: onSettings)
      }
      .onGeometryChange(for: CGFloat.self, of: \.size.height) { bottomHeight = $0 }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Picker("", selection: $model.selectedTab) {
        ForEach(SectionConfig.Tab.allCases) { tab in
          Text("\(tab.title) \(model.count(in: tab))").tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
        TextField("Filter", text: $model.filter)
          .textFieldStyle(.plain)
          .focused($filterFocused)
        if !model.filter.isEmpty {
          IconButton("xmark.circle.fill", help: "Clear filter") { model.filter = "" }
        }
      }
      .font(.system(size: 12))
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

      Button {
        model.refreshNow()
      } label: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
          .animation(
            model.isRefreshing ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
            value: model.isRefreshing)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .keyboardShortcut("r")
      .help("Refresh (⌘R)")

      // Hidden shortcut target: ⌘F focuses the filter.
      Button("") { filterFocused = true }
        .keyboardShortcut("f")
        .hidden()
        .frame(width: 0, height: 0)
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  @ViewBuilder private var list: some View {
    let sections = model.visibleSections(for: model.selectedTab)
    if sections.allSatisfy({ $0.pullRequests.isEmpty && $0.error == nil && !$0.isLoading }) {
      EmptyStateView(model: model)
    } else {
      ScrollView {
        // Plain VStack: the panel sizes itself to the measured list height, which a lazy stack can't report.
        VStack(alignment: .leading, spacing: 0) {
          ColumnHeader()
          ForEach(sections) { section in
            SectionView(section: section, model: model)
          }
        }
        .padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
      }
      .scrollIndicators(.automatic)
      .frame(height: min(max(listHeight, 40), listMaxHeight))
    }
  }
}

private struct ColumnHeader: View {
  var body: some View {
    HStack(spacing: 0) {
      Spacer()
      Text("CI").frame(width: Layout.ciColumn)
      Text("Review").frame(width: Layout.reviewColumn)
      Text("Merge").frame(width: Layout.mergeColumn)
    }
    .font(.system(size: 9.5, weight: .semibold))
    .textCase(.uppercase)
    .tracking(0.5)
    .foregroundStyle(.tertiary)
    .padding(.horizontal, Layout.rowInset + 6)
    .padding(.top, 8)
  }
}

struct SectionView: View {
  let section: Dashboard.Section
  let model: AppModel

  private var collapsed: Bool { model.settings.collapsedSectionIDs.contains(section.id) && model.filter.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Button {
        withAnimation(.snappy(duration: 0.2)) { model.toggleCollapsed(section.id) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(collapsed ? 0 : 90))
            .foregroundStyle(.tertiary)
          Circle().fill(section.color.color).frame(width: 7, height: 7)
          Text(section.name.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text("\(section.pullRequests.count)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.tertiary)
          if section.isLoading { ProgressView().controlSize(.mini) }
          Spacer()
          Text(section.summary.text).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 14)
      .padding(.top, 10)
      .padding(.bottom, 3)

      if let error = section.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.red)
          .lineLimit(2)
          .padding(.horizontal, 16)
          .padding(.bottom, 4)
      }

      if !collapsed {
        ForEach(section.pullRequests) { pr in
          PullRequestRow(pr: pr, color: section.color.color, model: model)
        }
        if section.moreCount > 0 {
          Button("\(section.moreCount) more on GitHub") { model.open(section.webSearchURL) }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.leading, 30)
            .padding(.top, 2)
        }
      }
    }
  }
}

private struct EmptyStateView: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 8) {
      if model.dashboard == nil {
        ProgressView().controlSize(.small)
        Text("Loading pull requests…").foregroundStyle(.secondary)
      } else if !model.filter.isEmpty {
        Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 24)).foregroundStyle(.tertiary)
        Text("Nothing matches “\(model.filter)”").foregroundStyle(.secondary)
      } else {
        Image(systemName: model.selectedTab == .mine ? "checkmark.seal" : "eyes")
          .font(.system(size: 26))
          .foregroundStyle(.tertiary)
        Text(model.selectedTab == .mine ? "No open pull requests" : "No reviews waiting for you")
          .foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 12))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
  }
}

private struct BannerView: View {
  let banner: AppModel.Banner
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: banner.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .foregroundStyle(banner.kind == .error ? .red : .green)
      Text(banner.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
      Spacer()
      IconButton("xmark", help: "Dismiss", action: onDismiss)
    }
    .font(.system(size: 12))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 7).fill((banner.kind == .error ? Color.red : .green).opacity(0.12)))
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .transition(.opacity)
  }
}

private struct FooterView: View {
  let model: AppModel
  let onSettings: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      TimelineView(.periodic(from: .now, by: 5)) { context in
        status(now: context.date)
      }
      Spacer()
      if let rateLimit = model.dashboard?.rateLimit, rateLimit.remaining < rateLimit.limit / 4 {
        Text("API \(rateLimit.remaining)/\(rateLimit.limit)")
          .foregroundStyle(.orange)
          .help("GitHub GraphQL budget left this hour")
      }
      Menu {
        Button("Settings…", action: onSettings).keyboardShortcut(",")
        Button("Refresh") { model.refreshNow() }
        Divider()
        Button("Quit Mergelight") { NSApp.terminate(nil) }.keyboardShortcut("q")
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .foregroundStyle(.secondary)
    }
    .font(.system(size: 11))
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  @ViewBuilder private func status(now: Date) -> some View {
    if let error = model.lastError {
      let label =
        if let fetchedAt = model.dashboard?.fetchedAt {
          "\(error == .offline ? "Offline" : "Can't refresh") · showing data from \(fetchedAt.formatted(date: .omitted, time: .shortened))"
        } else {
          error.localizedDescription
        }
      Label(label, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .lineLimit(1)
        .help(error.localizedDescription)
    } else if let fetchedAt = model.dashboard?.fetchedAt {
      let age = now.timeIntervalSince(fetchedAt)
      Text(age < 10 ? "Updated just now" : "Updated \(fetchedAt.compactAge(now: now)) ago")
        .help(model.viewerLogin.map { "Signed in as \($0)" } ?? "")
    }
  }
}
