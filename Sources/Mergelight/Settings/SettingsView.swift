import MergelightKit
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
      SectionsSettings(model: model)
        .tabItem { Label("Sections", systemImage: "rectangle.grid.1x2") }
      MergeSettings(model: model)
        .tabItem { Label("Merge", systemImage: "arrow.triangle.merge") }
      NotificationsSettings(model: model)
        .tabItem { Label("Notifications", systemImage: "bell") }
      AccountSettings(model: model)
        .tabItem { Label("Account", systemImage: "person.crop.circle") }
    }
    .frame(width: 680, height: 500)
  }
}

private struct GeneralSettings: View {
  @Bindable var model: AppModel
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var loginItemError: String?

  private let intervals: [Double] = [15, 30, 60, 120, 300, 600]

  var body: some View {
    Form {
      Section {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .onChange(of: launchAtLogin) { _, enabled in
            do {
              try LoginItem.setEnabled(enabled)
              loginItemError = nil
            } catch {
              loginItemError = error.localizedDescription
              launchAtLogin = LoginItem.isEnabled
            }
          }
        if let loginItemError {
          Text(loginItemError).font(.caption).foregroundStyle(.red)
        }
      }

      Section("Menu bar") {
        Picker("Show", selection: $model.settings.menuBarStyle) {
          ForEach(AppSettings.MenuBarStyle.allCases) { Text($0.title).tag($0) }
        }
        Text("Counts include sections with “Count in menu bar” turned on.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("Refresh every", selection: $model.settings.refreshInterval) {
          ForEach(intervals, id: \.self) { seconds in
            Text(seconds < 60 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minute\(seconds == 60 ? "" : "s")")
              .tag(seconds)
          }
        }
        Text(
          "Statuses refresh on this schedule, faster while CI runs or the panel is open. New pull requests are searched for at least every \(Int(RefreshPolicy(baseInterval: model.settings.refreshInterval).searchInterval)) seconds and whenever you open the panel."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Updates")
      }

      Section("Pull requests") {
        Toggle("Show drafts", isOn: $model.settings.showDrafts)
      }
    }
    .formStyle(.grouped)
  }
}

private struct MergeSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section {
        Picker("Merge button", selection: $model.settings.mergeConfirmation) {
          ForEach(AppSettings.MergeConfirmation.allCases) { Text($0.title).tag($0) }
        }
        Text(
          "In one-click mode a PR that's fully ready merges as soon as you click. PRs with failing or running checks, and admin merges, still ask first."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section {
        Picker("Default method", selection: $model.settings.preferredMergeMethod) {
          Text("Repository default").tag(MergeMethod?.none)
          Divider()
          ForEach(MergeMethod.allCases) { Text($0.actionTitle).tag(MergeMethod?.some($0)) }
        }
        Text("“Repository default” is the method you last used in that repository on GitHub. A method the repository doesn't allow falls back to it too.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Toggle("Delete the branch after merging", isOn: $model.settings.deleteBranchAfterMerge)
        Text("Skipped for forks and for repositories that delete merged branches themselves.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct NotificationsSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("My pull requests") {
        Toggle("CI failed", isOn: $model.settings.notifications.ciFailed)
        Toggle("CI passed", isOn: $model.settings.notifications.ciPassed)
        Toggle("Approved", isOn: $model.settings.notifications.approved)
        Toggle("Changes requested", isOn: $model.settings.notifications.changesRequested)
        Toggle("Merge conflict", isOn: $model.settings.notifications.conflicts)
        Toggle("Merged by someone else or by auto-merge", isOn: $model.settings.notifications.merged)
      }
      Section("Reviews") {
        Toggle("New review request", isOn: $model.settings.notifications.reviewRequested)
      }
      Section {
        Button("Open System Notification Settings…") {
          model.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct AccountSettings: View {
  let model: AppModel

  var body: some View {
    Form {
      Section("GitHub") {
        LabeledContent("Signed in as") {
          Text(model.viewerLogin.map { "@\($0)" } ?? "—")
        }
        if let rateLimit = model.dashboard?.rateLimit {
          LabeledContent("API budget") {
            Text("\(rateLimit.remaining) of \(rateLimit.limit) left, resets \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))")
          }
        }
        if model.isSignedIn {
          Button("Sign Out", role: .destructive) { model.signOut() }
        } else {
          Text("Sign in from the menu bar panel.").foregroundStyle(.secondary)
        }
      }
      Section {
        Text("The token is stored in your login keychain. Mergelight talks only to api.github.com and caches the last dashboard in ~/Library/Application Support/Mergelight.")
          .font(.caption)
          .foregroundStyle(.secondary)
        LabeledContent("Version", value: AppInfo.version)
      }
    }
    .formStyle(.grouped)
  }
}
