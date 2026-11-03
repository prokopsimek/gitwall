import Foundation

/// What Detail can show beyond the snapshot for one item.
public enum DetailLoad: Hashable, Sendable {
    /// The provider answered; single parts may still have failed.
    case loaded(ItemDetail)
    /// The provider has no Detail (GitLab for now).
    case unsupported
    /// No credential for the account, such as a removed token.
    case noCredential
}

/// Fetches ``ItemDetail`` on demand and keeps the recent ones, one per item, valid while the item's `updatedAt` is
/// unchanged. Requests for the same item while it loads share one fetch. Nothing here touches the App Group.
public actor DetailFetcher {
    private let providers: [ProviderKind: any GitProvider]
    private let tokens: any TokenReading
    private let cacheLimit: Int
    private var cache: [String: ItemDetail] = [:]
    /// Item ids, least recently stored first.
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<DetailLoad, Never>] = [:]
    /// Calls to ``detail(for:account:forceRefresh:)`` so far; lets tests line up concurrent requests.
    private(set) var requestCount = 0

    public init(providers: [ProviderKind: any GitProvider], tokens: any TokenReading, cacheLimit: Int = 100) {
        self.providers = providers
        self.tokens = tokens
        self.cacheLimit = cacheLimit
    }

    /// The cached detail when it belongs to this state of the item.
    public func cached(_ item: WorkItem) -> ItemDetail? {
        guard let detail = cache[item.id], detail.itemUpdatedAt == item.updatedAt else { return nil }
        return detail
    }

    /// From the cache when the item has not changed since, otherwise one fetch. A detail with a part that failed in
    /// passing is not kept, so opening the item again tries again; a missing permission is kept, since asking again
    /// gives the same answer until the token changes.
    public func detail(for item: WorkItem, account: Account, forceRefresh: Bool = false) async -> DetailLoad {
        requestCount += 1
        if !forceRefresh, let cached = cached(item) { return .loaded(cached) }
        let key = "\(item.id)@\(item.updatedAt.timeIntervalSinceReferenceDate)"
        if let running = inFlight[key] { return await running.value }

        let task = Task { await self.fetch(item, account: account) }
        inFlight[key] = task
        let load = await task.value
        inFlight[key] = nil
        if case .loaded(let detail) = load, !detail.failures.contains(where: \.isPassing) {
            store(detail)
        }
        return load
    }

    private func fetch(_ item: WorkItem, account: Account) async -> DetailLoad {
        guard let provider = providers[account.kind], provider.capabilities.fetchesItemDetail else { return .unsupported }
        guard let token = try? await tokens.token(for: account.id), !token.isEmpty else { return .noCredential }
        guard let detail = await provider.itemDetail(account: account, token: token, item: item) else { return .unsupported }
        return .loaded(detail)
    }

    private func store(_ detail: ItemDetail) {
        cache[detail.itemID] = detail
        cacheOrder.removeAll { $0 == detail.itemID }
        cacheOrder.append(detail.itemID)
        while cacheOrder.count > cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}

extension DetailError {
    /// A failure that may be gone on the next try.
    var isPassing: Bool {
        if case .failed = self { return true }
        return false
    }
}
