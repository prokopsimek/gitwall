import Foundation
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

    /// An engine whose GitHub provider holds every `held` call until `gate` opens.
    func engine(_ env: Env, holding held: HeldProvider.Call, until gate: Gate) -> SyncEngine {
        let time = env.now
        return SyncEngine(
            providers: [.github: HeldProvider(scripted: env.githubProvider, held: held, gate: gate), .gitlab: env.gitlabProvider],
            tokens: StaticTokens(tokens: [env.github.id: "gh", env.gitlab.id: "gl"]),
            configStore: env.configStore,
            snapshotStore: env.snapshotStore,
            now: { time }
        )
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
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, until: gate)

        async let syncing = engine.sync()
        await calls(1, to: engine)
        async let fetching = engine.syncPresets([review.id])
        await calls(2, to: engine)
        await gate.open()
        let synced = try await syncing
        let fetched = try await fetching

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
        let fetched = try await fetching
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
        let gate = Gate()
        let engine = engine(env, holding: .fetchItems, until: gate)

        async let syncing = engine.sync()
        await calls(1, to: engine)
        async let first = engine.syncPresets([docs.id])
        await calls(2, to: engine)
        async let second = engine.syncPresets([review.id, docs.id])
        await calls(3, to: engine)
        await gate.open()
        let synced = try await syncing
        let one = try await first
        let other = try await second

        #expect(env.githubProvider.presetSearches.map(\.search) == [search(review), search(docs)])
        #expect(one.previous == synced.snapshot)
        #expect(other.previous == synced.snapshot)
        #expect(one.snapshot == other.snapshot)
        #expect(Set(one.snapshot.presetResults.map(\.presetID)) == [review.id, docs.id])
        #expect(one.searches == other.searches)
    }
}
