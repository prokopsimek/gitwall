import Foundation
import Testing
@testable import GitwallCore

@Suite("DetailFetcher")
struct DetailFetcherTests {
    typealias S = DetailSupport

    /// Opens once; everyone waiting before or after goes through.
    actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    actor Calls {
        private(set) var items: [String] = []
        private(set) var tokens: [String] = []
        func record(_ item: WorkItem, token: String) {
            items.append(item.id)
            tokens.append(token)
        }
    }

    /// Answers every item with a detail stamped with the item's `updatedAt`; `failing` makes the checks part fail.
    struct DetailProvider: GitProvider {
        let kind: ProviderKind = .github
        var supportsDetail = true
        var failing = false
        var gate: Gate?
        let calls = Calls()

        var capabilities: ProviderCapabilities {
            ProviderCapabilities(pullRequestTerm: "Pull request", pullRequestAbbreviation: "PR", supportsOrganizationSources: true,
                                 supportsGroupSources: false, resolvesTeamReviewRequests: false, hostName: "GitHub",
                                 fetchesItemDetail: supportsDetail)
        }
        func verify(baseURL: URL, token: String) async throws -> UserRef { S.me }
        func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
        func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
        func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] { [] }

        func itemDetail(account: Account, token: String, item: WorkItem) async -> ItemDetail? {
            await calls.record(item, token: token)
            await gate?.wait()
            guard supportsDetail else { return nil }
            var detail = S.detail(for: item)
            if failing { detail.checks = .failure(.failed("Bad gateway")) }
            return detail
        }
    }

    struct Tokens: TokenReading {
        var tokens: [UUID: String]
        func token(for accountID: UUID) async throws -> String? { tokens[accountID] }
    }

    private func fetcher(_ provider: DetailProvider, tokens: [UUID: String]? = nil, cacheLimit: Int = 100) -> DetailFetcher {
        DetailFetcher(providers: [.github: provider], tokens: Tokens(tokens: tokens ?? [S.account.id: "t0ken"]), cacheLimit: cacheLimit)
    }

    @Test("fetches with the account's token and hands the detail back")
    func fetches() async throws {
        let provider = DetailProvider()
        let item = S.pull()

        let load = await fetcher(provider).detail(for: item, account: S.account)

        #expect(load == .loaded(S.detail(for: item)))
        #expect(await provider.calls.tokens == ["t0ken"])
    }

    @Test("the same item, unchanged, comes from the cache")
    func cached() async throws {
        let provider = DetailProvider()
        let fetcher = fetcher(provider)
        let item = S.pull()

        _ = await fetcher.detail(for: item, account: S.account)
        _ = await fetcher.detail(for: item, account: S.account)

        #expect(await provider.calls.items.count == 1)
        #expect(await fetcher.cached(item) == S.detail(for: item))
    }

    @Test("a newer updatedAt fetches again, and so does a forced refresh")
    func stale() async throws {
        let provider = DetailProvider()
        let fetcher = fetcher(provider)
        var item = S.pull()

        _ = await fetcher.detail(for: item, account: S.account)
        item.updatedAt = S.now
        #expect(await fetcher.cached(item) == nil)
        let load = await fetcher.detail(for: item, account: S.account)
        _ = await fetcher.detail(for: item, account: S.account, forceRefresh: true)

        #expect(load == .loaded(S.detail(for: item)))
        #expect(await provider.calls.items.count == 3)
    }

    @Test("a part that failed in passing is not cached, so the next open tries again")
    func failuresAreNotCached() async throws {
        let provider = DetailProvider(failing: true)
        let fetcher = fetcher(provider)
        let item = S.pull()

        _ = await fetcher.detail(for: item, account: S.account)
        _ = await fetcher.detail(for: item, account: S.account)

        #expect(await provider.calls.items.count == 2)
    }

    @Test("a missing permission is cached: asking again would give the same answer")
    func missingPermissionIsCached() async throws {
        struct Refusing: GitProvider {
            let kind: ProviderKind = .github
            let calls = Calls()
            var capabilities: ProviderCapabilities { DetailProvider().capabilities }
            func verify(baseURL: URL, token: String) async throws -> UserRef { S.me }
            func discoverRepositories(baseURL: URL, token: String, query: String?) async throws -> [RepoRef] { [] }
            func discoverContainers(baseURL: URL, token: String) async throws -> [ContainerRef] { [] }
            func fetchItems(account: Account, token: String, kinds: Set<ItemKind>) async throws -> [WorkItem] { [] }
            func itemDetail(account: Account, token: String, item: WorkItem) async -> ItemDetail? {
                await calls.record(item, token: token)
                var detail = S.detail(for: item)
                detail.checks = .failure(.missingPermission)
                return detail
            }
        }
        let provider = Refusing()
        let fetcher = DetailFetcher(providers: [.github: provider], tokens: Tokens(tokens: [S.account.id: "t"]))
        let item = S.pull()

        _ = await fetcher.detail(for: item, account: S.account)
        _ = await fetcher.detail(for: item, account: S.account)

        #expect(await provider.calls.items.count == 1)
    }

    @Test("two requests for the same item while it loads share one fetch")
    func sharesInFlight() async throws {
        let gate = Gate()
        let provider = DetailProvider(failing: true, gate: gate)
        let fetcher = fetcher(provider)
        let item = S.pull()

        async let first = fetcher.detail(for: item, account: S.account)
        async let second = fetcher.detail(for: item, account: S.account)
        while await fetcher.requestCount < 2 { await Task.yield() }
        await gate.open()

        let loads = await [first, second]
        #expect(loads[0] == loads[1])
        #expect(await provider.calls.items.count == 1)
    }

    @Test("without a token there is nothing to fetch")
    func noCredential() async throws {
        let provider = DetailProvider()

        let load = await fetcher(provider, tokens: [:]).detail(for: S.pull(), account: S.account)

        #expect(load == .noCredential)
        #expect(await provider.calls.items.isEmpty)
    }

    @Test("a provider without Detail is unsupported and is not asked")
    func unsupported() async throws {
        let provider = DetailProvider(supportsDetail: false)

        let load = await fetcher(provider).detail(for: S.pull(), account: S.account)

        #expect(load == .unsupported)
        #expect(await provider.calls.items.isEmpty)
    }

    @Test("the cache keeps the most recent fetches only")
    func cacheLimit() async throws {
        let provider = DetailProvider()
        let fetcher = fetcher(provider, cacheLimit: 2)
        let items = [S.pull(1), S.pull(2), S.pull(3)]

        for item in items { _ = await fetcher.detail(for: item, account: S.account) }

        #expect(await fetcher.cached(items[0]) == nil)
        #expect(await fetcher.cached(items[1]) != nil)
        #expect(await fetcher.cached(items[2]) != nil)
    }
}
