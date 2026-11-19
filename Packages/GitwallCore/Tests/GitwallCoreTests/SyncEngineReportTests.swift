import Foundation
import Testing
@testable import GitwallCore

/// The line of counts a sync with presets writes to the unified log.
extension SyncEngineTests {
    @Test("the requests of a sync count the item state lookup beside those of the searches, a failed lookup too",
          arguments: [false, true])
    func requestsCountTheLookup(lookupFails: Bool) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let left = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [left, kept],
                                results: [earlierResult(review, holding: [left, kept], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([kept], requests: 3)
        env.githubProvider.itemStates = [left.id: .closed]
        if lookupFails { env.githubProvider.itemStateFailure = .rateLimited(resetAt: nil) }

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.count == 1)
        let report = try #require(result.report)
        #expect(report.searches == 1)
        #expect(report.requests == 4)
    }

    @Test("a sync without a lookup counts the requests of its searches alone")
    func requestsWithoutLookup() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(1, account: env.github)], requests: 3)

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(env.githubProvider.itemStateLookups.isEmpty)
        #expect(result.report?.requests == 3)
    }

    @Test("an on-demand fetch reports its counts as on demand: the presets it fetched, its searches and requests, a lookup included")
    func onDemandReport() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        let left = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review, docs], items: [left, kept],
                                results: [earlierResult(review, holding: [left, kept], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([kept], requests: 2)
        env.githubProvider.presetFetches[search(docs)] = found([], requests: 1)
        env.githubProvider.itemStates = [left.id: .closed]

        let result = try await env.engine().syncPresets([review.id, docs.id, UUID()])

        let report = try #require(result.report)
        #expect(report.origin == .onDemand(presets: 2, failedAccounts: 0))
        #expect(report.searches == 2)
        #expect(report.requests == 4)
        #expect(report.items == 1)
    }

    @Test("an account error in an on-demand fetch shows in its counts alone")
    func onDemandFailureIsCounted() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 502, message: "Bad Gateway"))

        let result = try await env.engine().syncPresets([review.id])

        #expect(result.report?.origin == .onDemand(presets: 1, failedAccounts: 1))
        #expect(result.report?.requests == 0)
    }

    @Test("the log line of a sync says what selected its presets, the one of an on-demand fetch says so, and both hold counts alone")
    func logLines() {
        let config = AppConfig(presets: [review, docs])
        let selection = SyncSelection.presets(in: config, widgets: [config.presets[0].id], open: [config.presets[1].id],
                                              shownWall: nil)
        let synced = SyncReport(selection: selection, searches: 2, requests: 5, items: 40, duration: .milliseconds(12))
        let fetched = SyncReport(onDemand: 2, failedAccounts: 1, searches: 3, requests: 4, items: 7,
                                 duration: .milliseconds(3))

        #expect(synced.message
            == "Synced presets of widgets 1, menu bar 0, notifications 0, windows 1, wall 0: 2 searches, 5 requests, 40 items, 12 ms")
        #expect(fetched.message == "Fetched 2 presets on demand, failed accounts 1: 3 searches, 4 requests, 7 items, 3 ms")
    }
}
