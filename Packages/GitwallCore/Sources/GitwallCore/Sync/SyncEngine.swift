import Foundation

public struct SyncResult: Sendable {
    public let snapshot: Snapshot
    /// Snapshot that was current before this sync, for diffing and notifications.
    public let previous: Snapshot?
}

/// Fetches every configured account through its provider and writes the merged snapshot.
/// Accounts that fail keep their previous items so the widget never goes blank because of one outage. A passing outage
/// (a gateway error or a lost connection) does not even show until it lasts for a third sync in a row; until then the
/// account keeps what it showed (`ok`, or an error it already had) and only ``FetchStatus/consecutiveFailures`` counts it.
/// Preset results carry over from the previous snapshot, except those of deleted presets and removed accounts, and so do
/// the items they hold.
public actor SyncEngine {
    /// Failed syncs in a row, for a passing reason, that an account rides out without showing an error.
    private static let quietFailures = 2

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

        let presetIDs = Set(config.presets.map(\.id))
        let accountIDs = Set(config.accounts.map(\.id))
        let presetResults = (previous?.presetResults ?? []).filter {
            presetIDs.contains($0.presetID) && accountIDs.contains($0.accountID)
        }
        let kept = Self.items(items, keepingFrom: previous?.items ?? [], heldBy: presetResults)

        let snapshot = Snapshot(
            fetchedAt: timestamp,
            items: FilterEngine.sort(kept, by: .lastActivity),
            accountStatus: status,
            presetResults: presetResults
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

    /// `fresh` and every previous item that one of `results` still holds although no account fetch returned it this
    /// time. A preset this sync did not search keeps its result, so the snapshot must keep the items that result
    /// names. An item is matched by its account and id together; an item in both lists is the fresh copy, once.
    static func items(
        _ fresh: [WorkItem], keepingFrom previous: [WorkItem], heldBy results: [PresetResult]
    ) -> [WorkItem] {
        let held = Set(results.flatMap { result in
            result.itemIDs.map { ItemKey(accountID: result.accountID, itemID: $0) }
        })
        guard !held.isEmpty else { return fresh }
        var present = Set(fresh.map { ItemKey(accountID: $0.accountID, itemID: $0.id) })
        var items = fresh
        for item in previous {
            let key = ItemKey(accountID: item.accountID, itemID: item.id)
            if held.contains(key), present.insert(key).inserted { items.append(item) }
        }
        return items
    }

    private struct ItemKey: Hashable {
        let accountID: UUID
        let itemID: String
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

        func failure(_ state: FetchState, _ message: String?, consecutiveFailures: Int = 0) -> AccountOutcome {
            AccountOutcome(
                accountID: account.id,
                items: previousItems,
                status: FetchStatus(state: state, lastSuccessAt: previousStatus?.lastSuccessAt, message: message,
                                    projectAccess: previousStatus?.projectAccess, consecutiveFailures: consecutiveFailures)
            )
        }

        /// A gateway error or a lost connection usually heals by the next sync, so it counts quietly up to
        /// `quietFailures` and shows from the next one on. Anything else shows at once and ends the series.
        func failure(for error: any Error) -> AccountOutcome {
            switch error as? ProviderError {
            case .unauthorized:
                return failure(.needsReauth, error.localizedDescription)
            case .rateLimited:
                return failure(.rateLimited, error.localizedDescription)
            case .network, .server(status: 502...504, message: _):
                let count = (previousStatus?.consecutiveFailures ?? 0) + 1
                if count > Self.quietFailures {
                    return failure(.error, error.localizedDescription, consecutiveFailures: count)
                }
                // Quiet means unchanged: a healthy account stays ok, and one that already shows an error keeps it,
                // because the outage says less about the account than the error does.
                guard let previousStatus, previousStatus.state != .ok else {
                    return failure(.ok, nil, consecutiveFailures: count)
                }
                return failure(previousStatus.state, previousStatus.message, consecutiveFailures: count)
            default:
                return failure(.error, error.localizedDescription)
            }
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
                    return failure(for: ProviderError.unauthorized)
                }
                return await succeed(try await provider.fetchItems(account: account, token: refreshed, kinds: kinds), token: refreshed)
            } catch {
                return failure(for: error)
            }
        } catch {
            return failure(for: error)
        }
    }
}
