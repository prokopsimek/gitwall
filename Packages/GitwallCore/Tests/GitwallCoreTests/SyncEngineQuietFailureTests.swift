import Foundation
import Testing
@testable import GitwallCore

/// What the unified log learns about an account that failed for a passing reason and still shows what it showed before.
/// Without a line of its own such a sync would look like a success in the log.
extension SyncEngineTests {
    @Test("a failure the account rides out quietly leaves a line with the provider, the kind of error and its place in the series",
          arguments: [
              (ProviderError.server(status: 502, message: "Bad Gateway"), "server 502"),
              (.network("The network connection was lost."), "network"),
          ])
    func quietFailureIsLogged(error: ProviderError, kind: String) async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(error)

        let first = try await env.engine().sync()
        let second = try await env.engine(at: env.minutes(5)).sync()
        let third = try await env.engine(at: env.minutes(10)).sync()

        #expect(first.quietFailures.map(\.message) == ["A github account failed quietly (\(kind)), 1 of 2"])
        #expect(second.quietFailures.map(\.message) == ["A github account failed quietly (\(kind)), 2 of 2"])
        // The third failure shows on screen, so it is no quiet one.
        #expect(third.snapshot.accountStatus[env.github.id]?.state == .error)
        #expect(third.quietFailures.isEmpty)
    }

    @Test("every account that fails quietly in a sync gets its own line, GitLab too")
    func everyQuietAccountIsLogged() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.server(status: 504, message: "Gateway Timeout"))
        env.gitlabProvider.results[env.gitlab.id] = .failure(.network("The request timed out."))

        let result = try await env.engine().sync()

        #expect(Set(result.quietFailures.map(\.message)) == [
            "A github account failed quietly (server 504), 1 of 2",
            "A gitlab account failed quietly (network), 1 of 2",
        ])
    }

    @Test("a sync whose accounts worked, or failed in a way that shows at once, leaves no line about a quiet failure")
    func shownFailureIsNoQuietOne() async throws {
        let env = try Env()
        defer { env.cleanup() }
        env.githubProvider.results[env.github.id] = .failure(.unauthorized)
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(1, account: env.gitlab)])

        let result = try await env.engine().sync()

        #expect(result.snapshot.accountStatus[env.github.id]?.state == .needsReauth)
        #expect(result.quietFailures.isEmpty)
    }

    @Test("an account that searches presets and fails quietly leaves the line too, and the line of the sync counts it")
    func quietSearchFailureIsLoggedAndCounted() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 503, message: "Service Unavailable"))

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(result.snapshot.accountStatus[env.github.id]?.state == .ok)
        #expect(result.quietFailures.map(\.message) == ["A github account failed quietly (server 503), 1 of 2"])
        #expect(result.report?.origin
            == .selection(widgets: 1, menuBar: 0, notifications: 0, windows: 0, wall: 0, failedAccounts: 1))
    }

    @Test("the line of a sync in which every account worked counts no failed account")
    func healthySyncCountsNoFailedAccount() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(result.report?.origin
            == .selection(widgets: 1, menuBar: 0, notifications: 0, windows: 0, wall: 0, failedAccounts: 0))
    }

    @Test("an on-demand fetch leaves no line about a quiet failure, because it changes no account's status")
    func onDemandFailureIsNoQuietOne() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 502, message: "Bad Gateway"))

        let result = try await env.engine().syncPresets([review.id])

        #expect(result.quietFailures.isEmpty)
    }

    @Test("the log line of a sync with failed accounts counts them, in counts alone")
    func logLineCountsFailedAccounts() {
        let config = AppConfig(presets: [review, docs])
        let selection = SyncSelection.presets(in: config, widgets: [config.presets[0].id], open: [config.presets[1].id],
                                              shownWall: nil)
        let synced = SyncReport(selection: selection, failedAccounts: 2, searches: 2, requests: 5, items: 40,
                                duration: .milliseconds(12))

        #expect(synced.message == "Synced presets of widgets 1, menu bar 0, notifications 0, windows 1, wall 0, "
            + "failed accounts 2: 2 searches, 5 requests, 40 items, 12 ms")
    }
}
