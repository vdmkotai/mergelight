import Foundation
import os

/// Borrows the token of an already signed-in GitHub CLI (`gh auth token`).
///
/// Apps launched from Finder get a minimal PATH, so the usual install locations are probed
/// directly before falling back to a login shell.
public enum GitHubCLI {
  public enum Failure: Error, LocalizedError {
    case notInstalled
    case notSignedIn(String)
    case timedOut

    public var errorDescription: String? {
      switch self {
      case .notInstalled: "GitHub CLI (gh) isn't installed."
      case .notSignedIn(let output):
        output.isEmpty ? "GitHub CLI isn't signed in. Run `gh auth login` first." : output
      case .timedOut: "GitHub CLI didn't respond."
      }
    }
  }

  static let candidatePaths = [
    "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
    NSHomeDirectory() + "/.local/bin/gh", "/run/current-system/sw/bin/gh",
  ]

  public static func token(hostname: String = "github.com") async throws -> String {
    let arguments = ["auth", "token", "--hostname", hostname]
    let result: ProcessResult
    if let path = candidatePaths.first(where: FileManager.default.isExecutableFile(atPath:)) {
      result = try await run(URL(filePath: path), arguments)
    } else {
      let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
      let command = "command -v gh >/dev/null || exit 127; gh " + arguments.joined(separator: " ")
      result = try await run(URL(filePath: shell), ["-l", "-c", command])
      if result.status == 127 { throw Failure.notInstalled }
    }
    // A login shell's profile may print to stdout too; the token is the last line.
    let token = result.stdout.split(whereSeparator: \.isNewline).last
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    guard result.status == 0, !token.isEmpty else {
      throw Failure.notSignedIn(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return token
  }

  struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10)
    async throws -> ProcessResult
  {
    let child = Child(executable: executable, arguments: arguments)
    return try await withCheckedThrowingContinuation { continuation in
      child.process.terminationHandler = { process in
        let stdout = String(decoding: child.out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: child.err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if child.timedOut.withLock({ $0 }) {
          continuation.resume(throwing: Failure.timedOut)
        } else {
          continuation.resume(
            returning: ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr))
        }
      }
      do {
        try child.process.run()
      } catch {
        continuation.resume(throwing: error)
        return
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        guard child.process.isRunning else { return }
        child.timedOut.withLock { $0 = true }
        child.process.terminate()
      }
    }
  }

  /// `Process` and `Pipe` are documented thread-safe for the calls made here (run, isRunning,
  /// terminate, reading after exit); the flag is lock-protected.
  private final class Child: @unchecked Sendable {
    let process = Process()
    let out = Pipe()
    let err = Pipe()
    let timedOut = OSAllocatedUnfairLock(initialState: false)

    init(executable: URL, arguments: [String]) {
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = out
      process.standardError = err
      process.standardInput = FileHandle.nullDevice
    }
  }
}
