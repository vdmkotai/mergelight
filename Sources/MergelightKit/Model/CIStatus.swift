import Foundation

/// Check runs and commit statuses on the head commit, reduced to counts.
///
/// Counts come from `checkRunCountsByState` / `statusContextCountsByState`, so the list query never
/// downloads individual checks.
public struct CIStatus: Hashable, Sendable, Codable {
  public enum Rollup: String, Sendable, Codable {
    case none, pending, success, failure
  }

  public let rollup: Rollup
  public let passed: Int
  public let failed: Int
  public let running: Int

  public var total: Int { passed + failed + running }
  public var finished: Int { passed + failed }

  public static let none = CIStatus(rollup: .none, passed: 0, failed: 0, running: 0)

  public init(rollup: Rollup, passed: Int, failed: Int, running: Int) {
    self.rollup = rollup
    self.passed = passed
    self.failed = failed
    self.running = running
  }

  /// Builds the status from GitHub's per-state counters.
  ///
  /// Our own counts decide the rollup: a single failed check shows red even while others still
  /// run, which is what the row needs. GitHub's rollup is the fallback when no counters came back.
  public init(
    checkRunCounts: [String: Int], statusContextCounts: [String: Int], githubRollup: String?
  ) {
    var passed = 0
    var failed = 0
    var running = 0
    for (state, count) in checkRunCounts {
      switch Self.checkRunOutcome(state) {
      case .passed: passed += count
      case .failed: failed += count
      case .running: running += count
      }
    }
    for (state, count) in statusContextCounts {
      switch Self.statusContextOutcome(state) {
      case .passed: passed += count
      case .failed: failed += count
      case .running: running += count
      }
    }

    let rollup: Rollup
    if failed > 0 {
      rollup = .failure
    } else if running > 0 {
      rollup = .pending
    } else if passed > 0 {
      rollup = .success
    } else {
      switch githubRollup {
      case "SUCCESS": rollup = .success
      case "FAILURE", "ERROR": rollup = .failure
      case "PENDING", "EXPECTED": rollup = .pending
      default: rollup = .none
      }
    }
    self.init(rollup: rollup, passed: passed, failed: failed, running: running)
  }

  enum Outcome { case passed, failed, running }

  /// `CheckRunState` mixes run status and conclusion into one enum.
  static func checkRunOutcome(_ state: String) -> Outcome {
    switch state {
    case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "ERROR":
      .failed
    case "IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED":
      .running
    // SUCCESS, NEUTRAL, SKIPPED, STALE, COMPLETED and anything GitHub adds later.
    default:
      .passed
    }
  }

  static func statusContextOutcome(_ state: String) -> Outcome {
    switch state {
    case "FAILURE", "ERROR": .failed
    case "PENDING", "EXPECTED": .running
    default: .passed
    }
  }
}
