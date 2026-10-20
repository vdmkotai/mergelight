import Foundation

/// Maps `items` concurrently with at most `maxConcurrent` operations in flight, preserving order.
/// The first error cancels the remaining work and is rethrown.
func concurrentMap<Item: Sendable, Output: Sendable>(
  _ items: [Item], maxConcurrent: Int,
  _ transform: @escaping @Sendable (Item) async throws(GitHubError) -> Output
) async throws(GitHubError) -> [Output] {
  let results = await withTaskGroup(
    of: (Int, Result<Output, GitHubError>).self, returning: [Result<Output, GitHubError>?].self
  ) { group in
    var results = [Result<Output, GitHubError>?](repeating: nil, count: items.count)
    var next = 0
    func startNext() {
      guard next < items.count else { return }
      let index = next
      let item = items[index]
      next += 1
      group.addTask {
        do throws(GitHubError) {
          return (index, .success(try await transform(item)))
        } catch {
          return (index, .failure(error))
        }
      }
    }
    for _ in 0..<min(maxConcurrent, items.count) { startNext() }
    while let (index, result) = await group.next() {
      results[index] = result
      if case .failure = result {
        group.cancelAll()
        break
      }
      startNext()
    }
    return results
  }

  var outputs: [Output] = []
  outputs.reserveCapacity(items.count)
  for result in results {
    switch result {
    case .success(let output): outputs.append(output)
    case .failure(let error): throw error
    // Only possible after a failure cancelled the group; that failure is thrown above or below.
    case nil: continue
    }
  }
  if outputs.count != items.count {
    throw results.lazy.compactMap { result -> GitHubError? in
      if case .failure(let error) = result { return error }
      return nil
    }.first ?? .network("Cancelled")
  }
  return outputs
}

extension RateLimit {
  init(_ dto: RateLimitDTO) {
    self.init(remaining: dto.remaining, limit: dto.limit, resetAt: dto.resetAt, cost: dto.cost)
  }
}
