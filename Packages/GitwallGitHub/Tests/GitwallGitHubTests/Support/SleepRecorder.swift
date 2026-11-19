import Foundation

/// Stands in for `Task.sleep` in the GitHub client: notes every wait and returns at once, so no test really sleeps.
actor SleepRecorder {
    private(set) var delays: [Duration] = []

    /// Hand this to the client as its `sleep`.
    nonisolated var sleep: @Sendable (Duration) async throws -> Void {
        { [self] delay in await record(delay) }
    }

    private func record(_ delay: Duration) {
        delays.append(delay)
    }
}
