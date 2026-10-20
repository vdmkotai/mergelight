import AppKit
import MergelightKit
@preconcurrency import UserNotifications

/// Posts PR notifications; clicking one opens the PR.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  /// UserNotifications needs a real app bundle; `swift run` has none and would crash.
  private let center: UNUserNotificationCenter? =
    Bundle.main.bundleIdentifier == nil ? nil : .current()

  override init() {
    super.init()
    center?.delegate = self
  }

  func requestAuthorization() {
    center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func post(_ event: PullRequestEvent, settings: NotificationSettings) {
    let pr = event.pullRequest
    let title: String
    switch event {
    case .ciFailed:
      guard settings.ciFailed else { return }
      title = "CI failed · #\(pr.number)"
    case .ciPassed:
      guard settings.ciPassed else { return }
      title = "CI passed · #\(pr.number)"
    case .approved(_, let by):
      guard settings.approved else { return }
      title = "Approved by \(by.formatted(.list(type: .and))) · #\(pr.number)"
    case .changesRequested(_, let by):
      guard settings.changesRequested else { return }
      title = "Changes requested by \(by.formatted(.list(type: .and))) · #\(pr.number)"
    case .conflicts:
      guard settings.conflicts else { return }
      title = "Merge conflict · #\(pr.number)"
    case .reviewRequested:
      guard settings.reviewRequested else { return }
      title = "Review requested · #\(pr.number) by \(pr.author?.login ?? "someone")"
    case .disappeared:
      return
    }
    post(title: title, pr: pr)
  }

  func postMerged(_ pr: PullRequest, by login: String?) {
    let title = login.map { "Merged by \($0) · #\(pr.number)" } ?? "Merged · #\(pr.number)"
    post(title: title, pr: pr)
  }

  private func post(title: String, pr: PullRequest) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = pr.repository.nameWithOwner
    content.body = pr.title
    content.threadIdentifier = pr.id
    content.userInfo = ["url": pr.url.absoluteString]
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let string = response.notification.request.content.userInfo["url"] as? String,
      let url = URL(string: string)
    else { return }
    await MainActor.run { _ = NSWorkspace.shared.open(url) }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}
