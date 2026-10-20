import Foundation
import MergelightKit

/// Runs refreshes one at a time and decides when the next one starts.
///
/// - Triggers that arrive while a refresh is in flight collapse into one follow-up; a pending full
///   refresh wins over a status one.
/// - After each refresh the timer is re-armed from the current policy, so opening the panel or a
///   CI run starting shortens the wait right away.
@MainActor
final class RefreshScheduler {
  enum Trigger: Equatable {
    /// Timer fired: the model picks full or status from the policy.
    case scheduled
    case status
    case full
  }

  private let perform: @MainActor (Trigger) async -> Void
  private let nextDelay: @MainActor () -> TimeInterval

  private var timer: Task<Void, Never>?
  private var inFlight = false
  private var pending: Trigger?
  private(set) var isRunning = false

  init(
    perform: @escaping @MainActor (Trigger) async -> Void,
    nextDelay: @escaping @MainActor () -> TimeInterval
  ) {
    self.perform = perform
    self.nextDelay = nextDelay
  }

  func start(with trigger: Trigger = .full) {
    isRunning = true
    fire(trigger)
  }

  func stop() {
    isRunning = false
    timer?.cancel()
    timer = nil
    pending = nil
  }

  /// Refreshes now, plus quick status re-checks after `followUps` seconds. Follow-ups catch
  /// GitHub settling after a mutation (mergeability, auto-merge, search index).
  func fire(_ trigger: Trigger, followUps: [TimeInterval] = []) {
    guard isRunning else { return }
    for delay in followUps {
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        self?.fire(.status)
      }
    }
    if inFlight {
      pending = Self.stronger(pending, trigger)
      return
    }
    timer?.cancel()
    inFlight = true
    Task {
      await perform(trigger)
      inFlight = false
      if let next = pending {
        pending = nil
        fire(next)
      } else {
        armTimer()
      }
    }
  }

  /// Re-arms the timer from the current policy, e.g. after the panel opens or closes.
  func reschedule() {
    guard isRunning, !inFlight else { return }
    armTimer()
  }

  private func armTimer() {
    guard isRunning else { return }
    timer?.cancel()
    let delay = nextDelay()
    // ContinuousClock keeps counting through sleep, so an overdue refresh fires right after wake.
    timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay), clock: .continuous)
      guard !Task.isCancelled else { return }
      self?.fire(.scheduled)
    }
  }

  private static func stronger(_ a: Trigger?, _ b: Trigger) -> Trigger {
    if a == .full || b == .full { return .full }
    if a == .status || b == .status { return .status }
    return .scheduled
  }
}
