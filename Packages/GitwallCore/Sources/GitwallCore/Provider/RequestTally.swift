import Foundation
import os

/// Counts the HTTP requests a piece of work sends, whatever sends them. A provider's HTTP client records every attempt
/// it hands to its transport, a repeat after a gateway error included, and the work that wants the number runs inside
/// ``counting(_:)``. Nothing in the provider protocol carries the count, so a request the protocol does not return
/// (a failed search, the project priorities, every batch of a lookup, a download of everything) is still in it.
public final class RequestTally: Sendable {
    /// The tally the running task records into, nil outside ``counting(_:)``.
    @TaskLocal private static var current: RequestTally?

    private let own = OSAllocatedUnfairLock(initialState: 0)
    private let parent: RequestTally?

    public init() { parent = nil }

    private init(parent: RequestTally?) { self.parent = parent }

    /// The requests recorded so far, those of nested ``counting(_:)`` calls included.
    public var count: Int { own.withLock { $0 } }

    /// Records `requests` requests sent by the running task; a task outside ``counting(_:)`` records nothing.
    public static func record(_ requests: Int = 1) {
        var tally = current
        while let counting = tally {
            counting.own.withLock { $0 += requests }
            tally = counting.parent
        }
    }

    /// Runs `body` and returns what it returned with the number of requests it sent, which also count in the tally
    /// that is running around it, so a count taken for one fetch does not take the requests away from the sync.
    public static func counting<T: Sendable>(_ body: () async throws -> T) async rethrows -> (value: T, requests: Int) {
        let tally = RequestTally(parent: current)
        let value = try await $current.withValue(tally) { try await body() }
        return (value, tally.count)
    }

    /// Runs `body` with this tally as the one that is recording, for work that is counted by an owner of its own.
    func run<T: Sendable>(_ body: () async -> T) async -> T {
        await Self.$current.withValue(self) { await body() }
    }
}
