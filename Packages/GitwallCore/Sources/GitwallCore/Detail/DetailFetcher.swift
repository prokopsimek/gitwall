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

/// Fetches ``ItemDetail`` on demand. Requests for the same state of an item while it loads share one fetch; keeping
/// what was fetched is ``DetailCache``'s job. Nothing here touches the App Group.
public actor DetailFetcher {
    private let providers: [ProviderKind: any GitProvider]
    private let tokens: any TokenReading
    private var inFlight: [String: Task<DetailLoad, Never>] = [:]
    /// Calls to ``detail(for:account:)`` so far; lets tests line up concurrent requests.
    private(set) var requestCount = 0

    public init(providers: [ProviderKind: any GitProvider], tokens: any TokenReading) {
        self.providers = providers
        self.tokens = tokens
    }

    public func detail(for item: WorkItem, account: Account) async -> DetailLoad {
        requestCount += 1
        let key = "\(item.id)@\(item.updatedAt.timeIntervalSinceReferenceDate)"
        if let running = inFlight[key] { return await running.value }

        let task = Task { await self.fetch(item, account: account) }
        inFlight[key] = task
        let load = await task.value
        inFlight[key] = nil
        return load
    }

    private func fetch(_ item: WorkItem, account: Account) async -> DetailLoad {
        guard let provider = providers[account.kind], provider.capabilities.fetchesItemDetail else { return .unsupported }
        guard let token = try? await tokens.token(for: account.id), !token.isEmpty else { return .noCredential }
        guard let detail = await provider.itemDetail(account: account, token: token, item: item) else { return .unsupported }
        return .loaded(detail)
    }
}

extension DetailError {
    /// A failure that may be gone on the next try.
    var isPassing: Bool {
        if case .failed = self { return true }
        return false
    }
}
