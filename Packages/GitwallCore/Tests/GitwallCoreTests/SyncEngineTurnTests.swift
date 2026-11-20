import Foundation
import os
import Testing
@testable import GitwallCore

/// Syncs and on-demand fetches take turns: each reads the snapshot, waits for its providers and writes the snapshot back.
/// The tests hold one provider call until they open a gate, and line the other calls up by ``SyncEngine/callCount``,
/// which counts a call as it arrives and before it waits, so no test waits for time to pass.
extension SyncEngineTests {
    /// Opens once; every call waiting before or after goes through.
    typealias Gate = DetailFetcherTests.Gate

    /// The scripted provider, with every call of one kind held until the test opens the gate, so the sync or the fetch
    /// that sent it keeps running for as long as the test needs.
    struct HeldProvider: GitProvider {
        enum Call: Sendable { case fetchItems, fetchPresetItems }

        let scripted: FakeProvider
        let held: Call
        let gate: Gate

        var kind: ProviderKind { scripted.kind }
        var capabilities: ProviderCapabilities { scripted.capabilities }
        func capabilities(for account: Account) -> ProviderCapabilities { scripted.capabilities(for: account) }
        func verify(baseURL: URL, token: String) async throws -> UserRef {
            try await scripted.verify(baseURL: baseURL, token: token)
        }
        func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] {
            try await scripted.discoverRepositories(baseURL: baseURL, token: token, query: query)
        }
        func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] {
            try await scripted.discoverContainers(baseURL: baseURL, token: token)
        }
        func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] {
            if held == .fetchItems { await gate.wait() }
            return try await scripted.fetchItems(account: account, token: token, kinds: kinds)
        }
        func fetchPresetItems(account: Account, token: String, search: PresetSearch) async throws -> PresetFetch {
            if held == .fetchPresetItems { await gate.wait() }
            return try await scripted.fetchPresetItems(account: account, token: token, search: search)
        }
        func fetchItemStates(account: Account, token: String, items: [WorkItem]) async throws -> [String: ItemState] {
            try await scripted.fetchItemStates(account: account, token: token, items: items)
        }
        func projectPriorities(account: Account, token: String, items: [WorkItem]) async -> PriorityLookup {
            await scripted.projectPriorities(account: account, token: token, items: items)
        }
    }

    /// An engine whose provider of `kind` holds every `held` call until `gate` opens, and whose clock reads `clock`,
    /// or `env.now` throughout without one.
    func engine(
        _ env: Env, holding held: HeldProvider.Call, of kind: ProviderKind = .github, until gate: Gate,
        clock: (@Sendable () -> Date)? = nil
    ) -> SyncEngine {
        let time = env.now
        let scripted = switch kind {
        case .github: env.githubProvider
        case .gitlab: env.gitlabProvider
        }
        var providers: [ProviderKind: any GitProvider] = [.github: env.githubProvider, .gitlab: env.gitlabProvider]
        providers[kind] = HeldProvider(scripted: scripted, held: held, gate: gate)
        return SyncEngine(
            providers: providers,
            tokens: StaticTokens(tokens: [env.github.id: "gh", env.gitlab.id: "gl"]),
            configStore: env.configStore,
            snapshotStore: env.snapshotStore,
            now: clock ?? { time }
        )
    }

    /// A clock that reads `start` and then one minute later on every further reading, so that a turn which runs after
    /// another one writes different times even when it fetches the same, and a snapshot it wrote shows.
    func steppingClock(from start: Date) -> @Sendable () -> Date {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        return {
            let earlier = readings.withLock { count in
                defer { count += 1 }
                return count
            }
            return start.addingTimeInterval(Double(earlier) * 60)
        }
    }

    /// Returns once `engine` has seen `count` calls, each of them running or waiting.
    func calls(_ count: Int, to engine: SyncEngine) async {
        while await engine.callCount < count { await Task.yield() }
    }

    /// GitHub searches presets, and a full sync finds one item in each account.
    func prepareTurns(_ env: Env, presets: [Preset]) throws {
        try preparePresetSearch(env, presets: presets,
                                status: [env.github.id: FetchStatus(state: .ok, lastSuccessAt: env.minutes(-5))])
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(2, account: env.gitlab)])
    }

    @Test("an on-demand fetch called while a sync runs waits for it and starts from the snapshot it wrote",
          .timeLimit(.minutes(1)))
    func fetchWaitsForSync() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareTurns(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        // A sync that selects no preset leaves the preset waiting for a fetch; GitLab downloads everything meanwhile.
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id])
        await calls(2, to: engine)
        await gate.open()
        let synced = try await syncing
        let fetched = try #require(try await fetching)

        #expect(fetched.previous == synced.snapshot)
        #expect(fetched.snapshot.items.map(\.number).sorted() == [2, 3])
        #expect(try env.snapshotStore.load() == fetched.snapshot)
    }

    @Test("a sync called while an on-demand fetch runs waits for it", .timeLimit(.minutes(1)))
    func syncWaitsForFetch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareTurns(env, presets: [review])
        let gate = Gate()
        let engine = engine(env, holding: .fetchPresetItems, until: gate)

        async let fetching = engine.syncPresets([review.id])
        await calls(1, to: engine)
        async let syncing = engine.sync()
        await calls(2, to: engine)
        await gate.open()
        let fetched = try #require(try await fetching)
        let synced = try await syncing

        #expect(synced.previous == fetched.snapshot)
        #expect(try env.snapshotStore.load() == synced.snapshot)
    }

    @Test("a sync called while another sync runs waits for it", .timeLimit(.minutes(1)))
    func syncWaitsForSync() async throws {
        let env = try Env()
        defer { env.cleanup() }
        try prepareTurns(env, presets: [review])
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, until: gate)

        async let first = engine.sync()
        await calls(1, to: engine)
        async let second = engine.sync()
        await calls(2, to: engine)
        await gate.open()
        let earlier = try await first
        let later = try await second

        #expect(later.previous == earlier.snapshot)
    }

    @Test("on-demand fetches that wait at the same time run once, over all their presets, and share the result",
          .timeLimit(.minutes(1)))
    func waitingFetchesCoalesce() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        try prepareTurns(env, presets: [review, docs])
        // A sync that selects no preset leaves both waiting for a fetch; GitLab downloads everything meanwhile.
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let first = engine.syncPresets([docs.id])
        await calls(2, to: engine)
        async let second = engine.syncPresets([review.id, docs.id])
        await calls(3, to: engine)
        await gate.open()
        let synced = try await syncing
        let one = try #require(try await first)
        let other = try #require(try await second)

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review), search(docs)])
        #expect(one.previous == synced.snapshot)
        #expect(other.previous == synced.snapshot)
        #expect(one.snapshot == other.snapshot)
        #expect(Set(one.snapshot.presetResults.map(\.presetID)) == [review.id, docs.id])
        #expect(one.searches == other.searches)
    }

    // MARK: - What a fetch that waited still fetches

    @Test("an on-demand fetch that waited for a sync asks nothing for a preset that sync searched, writes nothing and returns nil",
          .timeLimit(.minutes(1)))
    func fetchAfterSyncSkipsWhatItSearched() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareTurns(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        let selection = try showing([review], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchPresetItems, until: gate, clock: steppingClock(from: env.now))

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id])
        await calls(2, to: engine)
        await gate.open()
        let synced = try await syncing
        let fetched = try await fetching

        #expect(fetched == nil)
        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(try env.snapshotStore.load() == synced.snapshot)
    }

    @Test("an on-demand fetch that waited for a sync searches only the presets that sync left in need of a fetch",
          .timeLimit(.minutes(1)))
    func fetchAfterSyncSearchesTheRest() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        try prepareTurns(env, presets: [review, docs])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        env.githubProvider.presetFetches[search(docs)] = found([env.item(4, account: env.github)])
        let selection = try showing([review], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchPresetItems, until: gate, clock: steppingClock(from: env.now))

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id, docs.id])
        await calls(2, to: engine)
        await gate.open()
        let synced = try await syncing
        let fetched = try #require(try await fetching)

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review), search(docs)])
        #expect(fetched.previous == synced.snapshot)
        #expect(fetched.snapshot.result(for: review, account: env.github.id)?.fetchedAt == env.now)
        #expect(fetched.snapshot.result(for: docs, account: env.github.id)?.fetchedAt == env.minutes(1))
        #expect(fetched.report?.origin == .onDemand(presets: 1, failedAccounts: 0))
    }

    @Test("requests that joined a waiting fetch with nothing left to fetch get nil as well", .timeLimit(.minutes(1)))
    func joinedRequestsGetNil() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareTurns(env, presets: [review])
        let selection = try showing([review], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchPresetItems, until: gate, clock: steppingClock(from: env.now))

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let first = engine.syncPresets([review.id])
        await calls(2, to: engine)
        async let second = engine.syncPresets([review.id])
        await calls(3, to: engine)
        await gate.open()
        _ = try await syncing
        let one = try await first
        let other = try await second

        #expect(one == nil)
        #expect(other == nil)
        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
    }

    @Test("an on-demand fetch that did not wait searches every preset it is given, even one whose result is fresh",
          .timeLimit(.minutes(1)))
    func fetchWithoutWaitSearchesFreshPresets() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try preparePresetSearch(env, presets: [review], results: [fetchedResult(review, holding: [], env: env)],
                                searched: [env.github.id])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        let later = env.minutes(1)
        let snapshot = try #require(try env.snapshotStore.load())
        #expect(!PresetFreshness.needsFetchOnOpen(review, in: snapshot, accounts: [env.github, env.gitlab], now: later,
                                                  interval: AppSettings().refreshInterval))

        let fetched = try #require(try await env.engine(at: later).syncPresets([review.id]))

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(fetched.snapshot.result(for: review, account: env.github.id)?.fetchedAt == later)
    }

    // MARK: - A forced fetch is never left out

    /// GitHub searched presets and the last search of `presets` was refused a minute before `env.now`, which is well
    /// inside the sync interval, so ``PresetFreshness`` counts each of them as asked just now.
    func prepareRefused(_ env: Env, presets: [Preset]) throws {
        let refused = presets.map {
            PresetResult(presetID: $0.id, accountID: env.github.id, itemIDs: [], fetchedAt: nil, totalCount: 0,
                         isComplete: false, selection: $0.selectionFingerprint,
                         failure: PresetQueryFailure(code: "422", at: env.minutes(-1)))
        }
        try preparePresetSearch(env, presets: presets, results: refused, searched: [env.github.id])
        env.githubProvider.results[env.github.id] = .success([env.item(1, account: env.github)])
        env.gitlabProvider.results[env.gitlab.id] = .success([env.item(2, account: env.gitlab)])
    }

    @Test("a forced fetch that waited for a sync searches its preset although the query was refused a minute ago",
          .timeLimit(.minutes(1)))
    func forcedFetchSearchesRefusedPreset() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareRefused(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id], force: [review.id])
        await calls(2, to: engine)
        await gate.open()
        _ = try await syncing
        let fetched = try #require(try await fetching)

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(fetched.snapshot.result(for: review, account: env.github.id)?.fetchedAt == env.now)
        #expect(fetched.snapshot.items.contains { $0.number == 3 })
    }

    @Test("a forced fetch that joined another caller's waiting fetch of the same preset searches it for both",
          .timeLimit(.minutes(1)))
    func forcedFetchJoinsPendingFetch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareRefused(env, presets: [review])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let first = engine.syncPresets([review.id])
        await calls(2, to: engine)
        async let second = engine.syncPresets([review.id], force: [review.id])
        await calls(3, to: engine)
        await gate.open()
        _ = try await syncing
        let one = try #require(try await first)
        let other = try #require(try await second)

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(one.snapshot == other.snapshot)
        #expect(one.snapshot.result(for: review, account: env.github.id)?.fetchedAt == env.now)
    }

    @Test("a fetch that is not forced still drops a preset whose query was refused a minute ago after waiting",
          .timeLimit(.minutes(1)))
    func unforcedFetchDropsRefusedPreset() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review
        try prepareRefused(env, presets: [review])
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id])
        await calls(2, to: engine)
        await gate.open()
        _ = try await syncing
        let fetched = try await fetching

        #expect(fetched == nil)
        #expect(env.githubProvider.presetSearches.isEmpty)
    }

    @Test("in one joined fetch only the preset that is not forced and not in need of a fetch is dropped",
          .timeLimit(.minutes(1)))
    func forcedAndUnforcedInOneFetch() async throws {
        let env = try Env()
        defer { env.cleanup() }
        let review = review, docs = docs
        try prepareRefused(env, presets: [review, docs])
        env.githubProvider.presetFetches[search(review)] = found([env.item(3, account: env.github)])
        env.githubProvider.presetFetches[search(docs)] = found([env.item(4, account: env.github)])
        let selection = try showing([], env: env)
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, of: .gitlab, until: gate)

        async let syncing = engine.sync(selection: selection)
        await calls(1, to: engine)
        async let first = engine.syncPresets([docs.id])
        await calls(2, to: engine)
        async let second = engine.syncPresets([review.id], force: [review.id])
        await calls(3, to: engine)
        await gate.open()
        _ = try await syncing
        let one = try #require(try await first)
        let other = try #require(try await second)

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review)])
        #expect(one.snapshot == other.snapshot)
        #expect(one.snapshot.result(for: review, account: env.github.id)?.fetchedAt == env.now)
        #expect(one.snapshot.result(for: docs, account: env.github.id)?.fetchedAt == nil)
    }
}
