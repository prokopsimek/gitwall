import Foundation

public struct SyncResult: Sendable {
    public let snapshot: Snapshot
    /// Snapshot that was current before this sync, for diffing and notifications.
    public let previous: Snapshot?
}

/// Fetches every configured account through its provider and writes the merged snapshot.
/// Accounts that fail keep their previous items so the widget never goes blank because of one outage.
public actor SyncEngine {
    private let providers: [ProviderKind: any GitProvider]
    private let tokens: any TokenReading
    private let configStore: ConfigStore
    private let snapshotStore: SnapshotStore
    private let now: @Sendable () -> Date

    public init(
        providers: [ProviderKind: any GitProvider],
        tokens: any TokenReading,
        configStore: ConfigStore,
        snapshotStore: SnapshotStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.providers = providers
        self.tokens = tokens
        self.configStore = configStore
        self.snapshotStore = snapshotStore
        self.now = now
    }

    public func sync() async throws -> SyncResult {
        let config = try configStore.load()
        let previous = try snapshotStore.load()
        let timestamp = now()

        let outcomes = await withTaskGroup(of: AccountOutcome.self, returning: [AccountOutcome].self) { group in
            for account in config.accounts {
                let kinds = Self.kindsNeeded(for: account, presets: config.presets)
                group.addTask { await self.fetch(account: account, kinds: kinds, previous: previous, timestamp: timestamp) }
            }
            var collected: [AccountOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var items: [WorkItem] = []
        var status: [UUID: FetchStatus] = [:]
        for outcome in outcomes {
            items.append(contentsOf: outcome.items)
            status[outcome.accountID] = outcome.status
        }

        let snapshot = Snapshot(
            fetchedAt: timestamp,
            items: FilterEngine.sort(items, by: .lastActivity),
            accountStatus: status
        )
        try snapshotStore.save(snapshot)
        return SyncResult(snapshot: snapshot, previous: previous)
    }

    // MARK: - Internals

    private struct AccountOutcome: Sendable {
        let accountID: UUID
        let items: [WorkItem]
        let status: FetchStatus
    }

    /// Union of kinds requested by presets that can see the account; both kinds when no preset narrows it.
    static func kindsNeeded(for account: Account, presets: [Preset]) -> Set<ItemKind> {
        var kinds: Set<ItemKind> = []
        for preset in presets where preset.scopes.isEmpty || preset.scopes.contains(where: { $0.accountID == account.id }) {
            kinds.formUnion(preset.kinds)
        }
        return kinds.isEmpty ? Set(ItemKind.allCases) : kinds
    }

    private func fetch(account: Account, kinds: Set<ItemKind>, previous: Snapshot?, timestamp: Date) async -> AccountOutcome {
        let previousItems = previous?.items.filter { $0.accountID == account.id } ?? []
        let previousStatus = previous?.accountStatus[account.id]

        func failure(_ state: FetchState, _ message: String) -> AccountOutcome {
            AccountOutcome(
                accountID: account.id,
                items: previousItems,
                status: FetchStatus(state: state, lastSuccessAt: previousStatus?.lastSuccessAt, message: message)
            )
        }

        let token: String?
        do {
            token = try await tokens.token(for: account.id)
        } catch {
            return failure(.error, "Could not read the token: \(error.localizedDescription)")
        }
        guard let token, !token.isEmpty else {
            return failure(.needsReauth, "No token stored for this account.")
        }
        guard let provider = providers[account.kind] else {
            return failure(.error, "No provider registered for \(account.kind.rawValue).")
        }

        func succeed(_ items: [WorkItem]) -> AccountOutcome {
            AccountOutcome(
                accountID: account.id,
                items: items,
                status: FetchStatus(state: .ok, lastSuccessAt: timestamp, message: nil)
            )
        }

        do {
            return succeed(try await provider.fetchItems(account: account, token: token, kinds: kinds))
        } catch ProviderError.unauthorized {
            // The token may just have expired. Give the reader one chance to refresh it silently.
            do {
                guard let refreshed = try await tokens.tokenAfterUnauthorized(for: account.id) else {
                    return failure(.needsReauth, ProviderError.unauthorized.localizedDescription)
                }
                return succeed(try await provider.fetchItems(account: account, token: refreshed, kinds: kinds))
            } catch ProviderError.unauthorized {
                return failure(.needsReauth, ProviderError.unauthorized.localizedDescription)
            } catch {
                return failure(.error, error.localizedDescription)
            }
        } catch let error as ProviderError {
            switch error {
            case .rateLimited: return failure(.rateLimited, error.localizedDescription)
            default: return failure(.error, error.localizedDescription)
            }
        } catch {
            return failure(.error, error.localizedDescription)
        }
    }
}
