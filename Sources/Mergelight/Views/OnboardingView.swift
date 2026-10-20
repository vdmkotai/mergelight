import MergelightKit
import SwiftUI

struct OnboardingView: View {
  let model: AppModel
  @State private var token = ""
  @State private var working = false

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "arrow.triangle.pull")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(.green)
      VStack(spacing: 4) {
        Text("Connect GitHub").font(.title3.weight(.semibold))
        Text("See CI, reviews and merge state of your pull requests, and merge from the menu bar.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      if case .waiting(let code) = model.deviceFlow {
        deviceCode(code)
      } else {
        VStack(spacing: 8) {
          if AppInfo.gitHubClientID != nil {
            Button {
              model.startDeviceFlow()
            } label: {
              Label("Sign in with GitHub", systemImage: "person.badge.key").frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.deviceFlow != nil)
          }
          Button {
            run { await model.signInWithGitHubCLI() }
          } label: {
            Label("Use GitHub CLI login", systemImage: "terminal").frame(maxWidth: 260)
          }
          .buttonStyle(.bordered)
          .help("Uses the token of `gh auth login`")
        }
        .controlSize(.large)

        HStack {
          VStack { Divider() }
          Text("or paste a token").font(.system(size: 11)).foregroundStyle(.tertiary)
          VStack { Divider() }
        }

        HStack {
          SecureField("ghp_… or github_pat_…", text: $token)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
          Button("Save", action: save).disabled(token.isEmpty || working)
        }
        Text("Classic token scopes: repo, read:org")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }

      if working { ProgressView().controlSize(.small) }
      if let error = model.signInError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
          .buttonStyle(.link)
          .font(.system(size: 11))
      }
    }
    .padding(.horizontal, 60)
    .padding(.top, 28)
    .padding(.bottom, 14)
  }

  private func deviceCode(_ code: DeviceFlow.Code) -> some View {
    VStack(spacing: 8) {
      Text(code.userCode)
        .font(.system(size: 26, weight: .semibold, design: .monospaced))
        .textSelection(.enabled)
      Text("The code is copied. Paste it on the GitHub page that just opened.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      HStack {
        Button("Open GitHub again") { model.open(code.verificationURL) }
        Button("Cancel") { model.cancelDeviceFlow() }
      }
      .controlSize(.small)
      ProgressView().controlSize(.small)
    }
  }

  private func save() {
    let token = token
    run { await model.signIn(withPastedToken: token) }
  }

  private func run(_ operation: @escaping @MainActor () async -> Void) {
    working = true
    Task {
      await operation()
      working = false
    }
  }
}
