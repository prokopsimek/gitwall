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

    /// Puts the outcome of a priority lookup on freshly fetched items. A lookup that failed for a passing reason keeps
    /// the previous project priorities and access state, so a list sorted by priority does not reshuffle on a hiccup.
    static func applying(
        _ lookup: PriorityLookup,
        to items: [WorkItem],
        previous: [WorkItem],
        previousAccess: ProjectAccess?
    ) -> (items: [WorkItem], access: ProjectAccess?) {
        func setting(_ priority: (WorkItem) -> Priority?) -> [WorkItem] {
            items.map { item in
                var item = item
                item.projectPriority = priority(item)
                return item
            }
        }
        switch lookup {
        case .unsupported:
            return (items, nil)
        case .found(let priorities):
            return (setting { priorities[$0.id] }, .granted)
        case .missingPermission:
            return (setting { _ in nil }, .denied)
        case .failed:
            let kept = Dictionary(previous.map { ($0.id, $0.projectPriority) }, uniquingKeysWith: { first, _ in first })
            return (setting { kept[$0.id] ?? nil }, previousAccess)
        }
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
                status: FetchStatus(state: state, lastSuccessAt: previousStatus?.lastSuccessAt, message: message,
                                    projectAccess: previousStatus?.projectAccess)
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

        // Priorities are read after the list and cannot fail it; see `docs/adr/0012`.
        func succeed(_ items: [WorkItem], token: String) async -> AccountOutcome {
            let lookup = await provider.projectPriorities(account: account, token: token, items: items)
            let (prioritized, access) = Self.applying(
                lookup, to: items, previous: previousItems, previousAccess: previousStatus?.projectAccess
            )
            return AccountOutcome(
                accountID: account.id,
                items: prioritized,
                status: FetchStatus(state: .ok, lastSuccessAt: timestamp, message: nil, projectAccess: access)
            )
        }

        do {
            return await succeed(try await provider.fetchItems(account: account, token: token, kinds: kinds), token: token)
        } catch ProviderError.unauthorized {
            // The token may just have expired. Give the reader one chance to refresh it silently.
            do {
                guard let refreshed = try await tokens.tokenAfterUnauthorized(for: account.id) else {
                    return failure(.needsReauth, ProviderError.unauthorized.localizedDescription)
                }
                return await succeed(try await provider.fetchItems(account: account, token: refreshed, kinds: kinds), token: refreshed)
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
