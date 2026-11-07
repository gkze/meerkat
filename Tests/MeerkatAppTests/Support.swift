import Testing

/// Polls until `condition` holds, and records an issue if it does not within
/// `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}
