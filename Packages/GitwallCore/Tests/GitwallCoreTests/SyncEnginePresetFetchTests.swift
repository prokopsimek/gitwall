import Foundation
import Testing
@testable import GitwallCore

/// Which accounts go by preset results, and fetching presets on demand when a window opens them.
extension SyncEngineTests {
    // MARK: - Searched accounts

    @Test("a sync with a selection names the accounts that searched presets, a failed one too, and not those that fetched everything",
          arguments: [Result<PresetFetch, ProviderError>.success(PresetFetch(items: [], totalCount: 0, isComplete: true, requests: 1)),
                      .failure(.server(status: 422, message: "Validation Failed")),
                      .failure(.server(status: 502, message: "Bad Gateway"))])
    func selectionNamesSearchedAccounts(outcome: Result<PresetFetch, ProviderError>) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = outcome

        let result = try await env.engine().sync(selection: try showing([review], env: env))

        #expect(result.snapshot.searchedAccounts == [env.github.id])
        #expect(try env.snapshotStore.load()?.searchedAccounts == [env.github.id])
    }

    @Test("a sync without a selection names no searched account, so every account reads all its items again")
    func fullSyncNamesNone() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try preparePresetSearch(env, presets: [review])
        var previous = try #require(try env.snapshotStore.load())
        previous.searchedAccounts = [env.github.id]
        try env.snapshotStore.save(previous)

        let result = try await env.engine().sync()

        #expect(result.snapshot.searchedAccounts.isEmpty)
    }

    // MARK: - Fetching presets on demand

    @Test("an on-demand fetch searches the given presets in the order of the configuration, in the accounts that search presets, and nothing else")
    func fetchesGivenPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs, blockers = blockers
        let gitlabOnly = Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue])
        let gitlabItems = [env.item(5, account: env.gitlab), env.item(6, account: env.gitlab)]
        try preparePresetSearch(env, presets: [review, docs, blockers, gitlabOnly], items: gitlabItems)
        env.githubProvider.presetFetches[search(docs)] = found([env.item(1, account: env.github)])

        let result = try await env.engine().syncPresets([gitlabOnly.id, docs.id, UUID(), review.id])

        #expect(env.githubProvider.presetSearches == [
            .init(accountID: env.github.id, token: "gh", search: search(review)),
            .init(accountID: env.github.id, token: "gh", search: search(docs)),
        ])
        #expect(env.githubProvider.requestedKinds.isEmpty)
        #expect(env.gitlabProvider.presetSearches.isEmpty)
        #expect(env.gitlabProvider.requestedKinds.isEmpty)
        #expect(env.gitlabProvider.priorityTokens.isEmpty)
        #expect(result.snapshot.presetResults == [fetchedResult(review, holding: [], env: env),
                                                  fetchedResult(docs, holding: [env.item(1, account: env.github)], env: env)]
            .sorted(by: PresetResult.precedes))
        #expect(result.snapshot.items.map(\.number).sorted() == [1, 5, 6])
        #expect(try env.snapshotStore.load() == result.snapshot)
    }

    @Test("an account none of whose given presets is in its scope is asked nothing and keeps every item")
    func accountWithoutGivenPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let gitlabOnly = Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue])
        let items = [env.item(1, account: env.github), env.item(2, account: env.github)]
        try preparePresetSearch(env, presets: [review, gitlabOnly], items: items,
                                results: [earlierResult(review, holding: [items[0]], env: env)])

        let result = try await env.engine().syncPresets([gitlabOnly.id])

        #expect(env.githubProvider.presetSearches.isEmpty)
        #expect(env.githubProvider.priorityTokens.isEmpty)
        #expect(result.snapshot.items == items)
        #expect(result.snapshot.searchedAccounts.isEmpty)
    }

    @Test("a successful on-demand fetch leaves every account's status exactly as it was")
    func successKeepsStatus() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let status = [
            env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5), projectAccess: .denied, consecutiveFailures: 1),
            env.gitlab.id: FetchStatus(state: .error, lastSuccessAt: env.minutes(-30), message: "Server error 500: boom"),
        ]
        try preparePresetSearch(env, presets: [review], status: status)
        env.githubProvider.presetFetches[search(review)] = found([env.item(1, account: env.github)])
        env.githubProvider.priorityLookup = .found([:])

        let result = try await env.engine().syncPresets([review.id])

        #expect(result.snapshot.accountStatus == status)
        #expect(result.snapshot.presetResults == [fetchedResult(review, holding: [env.item(1, account: env.github)], env: env)])
    }

    @Test("an account failure leaves every status, the preset's result and the items as they were",
          arguments: [ProviderError.server(status: 502, message: "Bad Gateway"), .unauthorized, .rateLimited(resetAt: nil),
                      .network("The network connection was lost.")])
    func accountFailureKeepsEverything(error: ProviderError) async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let held = env.item(1, account: env.github), unheld = env.item(2, account: env.github)
        let results = [earlierResult(review, holding: [held], env: env)]
        let status = [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5), consecutiveFailures: 1)]
        try preparePresetSearch(env, presets: [review], items: [held, unheld], results: results, status: status)
        env.githubProvider.presetFetches[search(review)] = .failure(error)

        let result = try await env.engine().syncPresets([review.id])

        #expect(result.snapshot.accountStatus == status)
        #expect(result.snapshot.presetResults == results)
        #expect(result.snapshot.items == [held, unheld])
        #expect(events(result, env: env).isEmpty)
    }

    @Test("a query the provider refuses stays with its preset as a failure, beside the items it had")
    func queryFailureStaysWithPreset() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let held = env.item(1, account: env.github)
        let earlier = earlierResult(review, holding: [held], env: env)
        let status = [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))]
        try preparePresetSearch(env, presets: [review], items: [held], results: [earlier], status: status)
        env.githubProvider.presetFetches[search(review)] = .failure(.server(status: 422, message: "Validation Failed"))

        let result = try await env.engine().syncPresets([review.id])

        var failed = earlier
        failed.failure = PresetQueryFailure(code: "422", at: env.now)
        #expect(result.snapshot.presetResults == [failed])
        #expect(result.snapshot.items == [held])
        #expect(result.snapshot.accountStatus == status)
    }

    @Test("an item that left a fresh result is verified as in a sync: a closed one leaves and is reported closed")
    func verifiesVanishedItems() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let gone = env.item(1, account: env.github), kept = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], items: [gone, kept],
                                results: [earlierResult(review, holding: [gone, kept], env: env)])
        env.githubProvider.presetFetches[search(review)] = found([kept])
        env.githubProvider.itemStates = [gone.id: .closed]

        let result = try await env.engine().syncPresets([review.id])

        #expect(env.githubProvider.itemStateLookups == [lookup([gone], env: env)])
        #expect(result.snapshot.presetResults == [fetchedResult(review, holding: [kept], env: env)])
        #expect(result.snapshot.items == [kept])
        #expect(result.searches.closedItemIDs == [gone.id])
        #expect(events(result, env: env) == [1: [.closed]])
    }

    @Test("the first result of a preset fetched on demand reports nothing new; a later one reports what it brought")
    func firstResultIsBaseline() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        let one = env.item(1, account: env.github), two = env.item(2, account: env.github)
        try preparePresetSearch(env, presets: [review], status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        env.githubProvider.presetFetches[search(review)] = found([one])

        let first = try await env.engine().syncPresets([review.id])

        #expect(first.searches == SearchFindings(accounts: [env.github.id], closedItemIDs: [], comparedItemIDs: []))
        #expect(events(first, env: env).isEmpty)

        env.githubProvider.presetFetches[search(review)] = found([one, two])
        let second = try await env.engine(at: env.minutes(5)).syncPresets([review.id])

        #expect(events(second, env: env) == [2: [.newItem]])
    }

    @Test("an on-demand fetch adds the accounts it searched to those the snapshot named and keeps the snapshot's date")
    func namesSearchedAccountsAndKeepsDate() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review])

        let result = try await env.engine().syncPresets([review.id])

        #expect(result.snapshot.searchedAccounts == [env.github.id])
        #expect(result.snapshot.fetchedAt == env.minutes(-5))
    }

    @Test("an on-demand fetch that searches nothing keeps the searched accounts of the snapshot, except one that was removed")
    func keepsSearchedAccounts() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let gitlabOnly = Preset(name: "GitLab issues", scopes: [PresetScope(accountID: env.gitlab.id)], kinds: [.issue])
        try preparePresetSearch(env, presets: [review, gitlabOnly])
        var previous = try #require(try env.snapshotStore.load())
        previous.searchedAccounts = [env.github.id, UUID()]
        try env.snapshotStore.save(previous)

        let result = try await env.engine().syncPresets([gitlabOnly.id])

        #expect(env.githubProvider.presetSearches.isEmpty)
        #expect(result.snapshot.searchedAccounts == [env.github.id])
    }
}
