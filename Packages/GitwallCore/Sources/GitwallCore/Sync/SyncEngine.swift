import Foundation

public struct SyncResult: Sendable {
    public let snapshot: Snapshot
    /// Snapshot that was current before this sync, for diffing and notifications.
    public let previous: Snapshot?
    /// What the preset searches of this sync found out, for ``SnapshotDiff/changes(from:to:accounts:searches:)``.
    public let searches: SearchFindings
}

/// Fetches every configured account through its provider and writes the merged snapshot.
/// Accounts that fail keep their previous items so the widget never goes blank because of one outage. A passing outage
/// (a gateway error or a lost connection) does not even show until it lasts for a third sync in a row; until then the
/// account keeps what it showed (`ok`, or an error it already had) and only ``FetchStatus/consecutiveFailures`` counts it.
/// Preset results carry over from the previous snapshot, except those of deleted presets and removed accounts, and so do
/// the items they hold. With a ``SyncSelection``, an account whose provider searches presets on the server searches only
/// the selected presets, asks the provider what became of the items that left those results, and reports what it
/// learned in ``SyncResult/searches``; see ``sync(selection:)``.
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

    /// Fetches every account and writes the snapshot.
    ///
    /// Without a `selection` every account downloads all its open items. With one, an account whose provider answers
    /// ``ProviderCapabilities/presetSearch`` for it sends one ``GitProvider/fetchPresetItems(account:token:search:)`` per
    /// selected preset of its scope, in the order of the configuration, and no other request for items; every other
    /// account downloads everything as without a selection. For a searching account:
    /// - A search the provider refuses on its own stays with its preset as a query failure, and the next one runs.
    /// - Any other failure stops the account's searches for this sync. The account's status comes from the quiet
    ///   period as for a full fetch, it keeps every item it had, and no priorities are looked up.
    /// - Otherwise the account is `ok` once at least one search succeeded; when none did, or none was selected for it,
    ///   it keeps the status it had and is not even asked for its token in the latter case.
    /// - Items that left a fresh result whose pair had an earlier result of the same selection, and that no search of
    ///   this sync returned, go to one ``GitProvider/fetchItemStates(account:token:items:)``. A closed or merged item
    ///   leaves every result of the account and is reported closed; one the provider does not find leaves them too,
    ///   without a word; an open one gets the provider's data. A failed lookup changes nothing and reports nothing.
    /// - The project priorities are looked up once, over everything the searches found and the lookup refreshed.
    /// - An item stays in the snapshot only while a search returned it or a preset result holds it.
    ///
    /// Each sync with a selection writes one line of counts to the unified log.
    public func sync(selection: SyncSelection? = nil) async throws -> SyncResult {
        let clock = ContinuousClock()
        let start = clock.now
        let config = try configStore.load()
        let previous = try snapshotStore.load()
        let timestamp = now()

        let plans = config.accounts.map { ($0, plan(for: $0, in: config, selection: selection)) }
        let outcomes = await withTaskGroup(of: AccountOutcome.self, returning: [AccountOutcome].self) { group in
            for (account, plan) in plans {
                let before = Before(account: account, previous: previous)
                group.addTask {
                    switch plan {
                    case .everything(let kinds):
                        await self.fetch(account: account, kinds: kinds, before: before, timestamp: timestamp)
                    case .presets(let queries, let provider):
                        await self.search(account: account, queries: queries, provider: provider, before: before,
                                          timestamp: timestamp)
                    }
                }
            }
            var collected: [AccountOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var items: [WorkItem] = []
        var status: [UUID: FetchStatus] = [:]
        var presetOutcomes: [PresetOutcome] = []
        var findings = SearchFindings.none
        var gone: Set<String> = []
        var refreshed: [String: WorkItem] = [:]
        for outcome in outcomes {
            items.append(contentsOf: outcome.items)
            status[outcome.accountID] = outcome.status
            presetOutcomes.append(contentsOf: outcome.presets)
            if outcome.searched { findings.accounts.insert(outcome.accountID) }
            findings.comparedItemIDs.formUnion(outcome.compared)
            findings.closedItemIDs.formUnion(outcome.lookup.closed)
            gone.formUnion(outcome.lookup.gone)
            for item in outcome.lookup.refreshed { refreshed[item.id] = item }
        }

        let presetIDs = Set(config.presets.map(\.id))
        let accountIDs = Set(config.accounts.map(\.id))
        let carried = (previous?.presetResults ?? []).filter {
            presetIDs.contains($0.presetID) && accountIDs.contains($0.accountID)
        }
        let presetResults = PresetResult.merged(carried, with: presetOutcomes, at: timestamp).map {
            Self.removing(gone, from: $0)
        }
        // A refreshed item takes the place of its previous copy, and stays only where a result still holds it.
        let earlier = (previous?.items ?? []).map { refreshed[$0.id] ?? $0 }
        let kept = Self.items(items, keepingFrom: earlier, heldBy: presetResults)

        let snapshot = Snapshot(
            fetchedAt: timestamp,
            items: FilterEngine.sort(kept, by: .lastActivity),
            accountStatus: status,
            presetResults: presetResults
        )
        try snapshotStore.save(snapshot)
        if let selection {
            SyncReport(
                selection: selection,
                searches: outcomes.reduce(0) { $0 + $1.searches },
                requests: outcomes.reduce(0) { $0 + $1.requests },
                items: snapshot.items.count,
                duration: clock.now - start
            ).write()
        }
        return SyncResult(snapshot: snapshot, previous: previous, searches: findings)
    }

    // MARK: - Internals

    /// How an account is fetched in one sync.
    private enum Plan: Sendable {
        /// Every open item of these kinds, through ``GitProvider/fetchItems(account:token:kinds:)``.
        case everything(Set<ItemKind>)
        /// One search per query, in this order, through ``GitProvider/fetchPresetItems(account:token:search:)``.
        case presets([PresetQuery], any GitProvider)
    }

    /// A selected preset and what it searches in one account.
    private struct PresetQuery: Sendable {
        let preset: Preset
        let search: PresetSearch
    }

    private func plan(for account: Account, in config: AppConfig, selection: SyncSelection?) -> Plan {
        guard let selection, let provider = providers[account.kind], provider.capabilities(for: account).presetSearch else {
            return .everything(Self.kindsNeeded(for: account, presets: config.presets))
        }
        let queries = selection.presetIDs.compactMap { id -> PresetQuery? in
            guard let preset = config.preset(id: id), let search = PresetSearch(preset: preset, accountID: account.id) else {
                return nil
            }
            return PresetQuery(preset: preset, search: search)
        }
        return .presets(queries, provider)
    }

    private struct AccountOutcome: Sendable {
        let accountID: UUID
        let items: [WorkItem]
        /// Nil leaves the account without a status: it had none, and this sync asked it nothing.
        let status: FetchStatus?
        /// What each preset search of the account came to.
        var presets: [PresetOutcome] = []
        /// Preset searches sent, a repeat after a token refresh included, and the requests the successful ones took.
        var searches = 0
        var requests = 0
        /// Whether the account fetched through preset searches, whatever came of them.
        var searched = false
        /// Items held by a result fetched now whose pair had an earlier result of the same selection.
        var compared: Set<String> = []
        /// What the provider said about the items that left a fresh result.
        var lookup = ItemLookup()
    }

    /// What ``GitProvider/fetchItemStates(account:token:items:)`` said about items that left a fresh result.
    private struct ItemLookup: Sendable {
        /// Confirmed closed or merged.
        var closed: Set<String> = []
        /// Closed, merged or not found: they leave every result of the account.
        var gone: Set<String> = []
        /// Still open, with the provider's current data and, once the priorities are read, theirs.
        var refreshed: [WorkItem] = []
    }

    /// What an account showed before this sync, which a failed fetch keeps.
    private struct Before: Sendable {
        let items: [WorkItem]
        let status: FetchStatus?
        let results: [PresetResult]

        init(account: Account, previous: Snapshot?) {
            items = previous?.items.filter { $0.accountID == account.id } ?? []
            status = previous?.accountStatus[account.id]
            results = previous?.presetResults.filter { $0.accountID == account.id } ?? []
        }

        /// The earlier result of `preset` in the account, when it was fetched for the selection the preset has now. A
        /// fresh result can only be compared with such a one; without it the fresh result is the baseline.
        func comparableResult(for preset: Preset) -> PresetResult? {
            results.first {
                $0.presetID == preset.id && $0.selection == preset.selectionFingerprint && $0.fetchedAt != nil
            }
        }

        /// `state` and `message`, with the last success and the project access the account had.
        func failed(_ state: FetchState, _ message: String?, consecutiveFailures: Int = 0) -> FetchStatus {
            FetchStatus(state: state, lastSuccessAt: status?.lastSuccessAt, message: message,
                        projectAccess: status?.projectAccess, consecutiveFailures: consecutiveFailures)
        }

        /// A gateway error or a lost connection usually heals by the next sync, so it counts quietly up to
        /// `quietFailures` and shows from the next one on. Anything else shows at once and ends the series.
        func failed(by error: any Error) -> FetchStatus {
            switch error as? ProviderError {
            case .unauthorized:
                return failed(.needsReauth, error.localizedDescription)
            case .rateLimited:
                return failed(.rateLimited, error.localizedDescription)
            case .network, .server(status: 502...504, message: _):
                let count = (status?.consecutiveFailures ?? 0) + 1
                if count > SyncEngine.quietFailures {
                    return failed(.error, error.localizedDescription, consecutiveFailures: count)
                }
                // Quiet means unchanged: a healthy account stays ok, and one that already shows an error keeps it,
                // because the outage says less about the account than the error does.
                guard let status, status.state != .ok else {
                    return failed(.ok, nil, consecutiveFailures: count)
                }
                return failed(status.state, status.message, consecutiveFailures: count)
            default:
                return failed(.error, error.localizedDescription)
            }
        }
    }

    /// Puts the outcome of a priority lookup on freshly fetched items. A lookup that failed for a passing reason keeps
    /// the previous project priorities and access state, so a list sorted by priority does not reshuffle on a hiccup.
    static func applying(
        _ lookup: PriorityLookup,
        to items: [WorkItem],
        previous: [WorkItem],
        previousAccess: ProjectAccess?
    ) -> (items: [WorkItem], access: ProjectAccess?) {
        switch lookup {
        case .unsupported:
            return (items, nil)
        case .found(let priorities):
            return (setting(on: items) { priorities[$0.id] }, .granted)
        case .missingPermission:
            return (setting(on: items) { _ in nil }, .denied)
        case .failed:
            return (keepingPriorities(on: items, from: previous), previousAccess)
        }
    }

    /// `items` with the project priority each had in `previous`; none for an item that is new.
    static func keepingPriorities(on items: [WorkItem], from previous: [WorkItem]) -> [WorkItem] {
        let kept = Dictionary(previous.map { ($0.id, $0.projectPriority) }, uniquingKeysWith: { first, _ in first })
        return setting(on: items) { kept[$0.id] ?? nil }
    }

    private static func setting(on items: [WorkItem], _ priority: (WorkItem) -> Priority?) -> [WorkItem] {
        items.map { item in
            var item = item
            item.projectPriority = priority(item)
            return item
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

    /// `result` without the items in `gone`, which the provider confirmed closed or merged or could not find, and with
    /// its count lowered by as many.
    static func removing(_ gone: Set<String>, from result: PresetResult) -> PresetResult {
        guard !gone.isEmpty else { return result }
        var result = result
        let count = result.itemIDs.count
        result.itemIDs.removeAll { gone.contains($0) }
        result.totalCount = max(0, result.totalCount - (count - result.itemIDs.count))
        return result
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

    private enum TokenRead {
        case token(String)
        /// Why the account has no token to send.
        case failed(FetchStatus)
    }

    private func readToken(for account: Account, before: Before) async -> TokenRead {
        let token: String?
        do {
            token = try await tokens.token(for: account.id)
        } catch {
            return .failed(before.failed(.error, "Could not read the token: \(error.localizedDescription)"))
        }
        guard let token, !token.isEmpty else {
            return .failed(before.failed(.needsReauth, "No token stored for this account."))
        }
        return .token(token)
    }

    /// Priorities are read after the list and cannot fail it; see `docs/adr/0012`.
    private func prioritized(
        _ items: [WorkItem], account: Account, provider: any GitProvider, token: String, before: Before
    ) async -> (items: [WorkItem], access: ProjectAccess?) {
        let lookup = await provider.projectPriorities(account: account, token: token, items: items)
        return Self.applying(lookup, to: items, previous: before.items, previousAccess: before.status?.projectAccess)
    }

    private func fetch(account: Account, kinds: Set<ItemKind>, before: Before, timestamp: Date) async -> AccountOutcome {
        func failure(_ status: FetchStatus) -> AccountOutcome {
            AccountOutcome(accountID: account.id, items: before.items, status: status)
        }

        let token: String
        switch await readToken(for: account, before: before) {
        case .token(let read): token = read
        case .failed(let status): return failure(status)
        }
        guard let provider = providers[account.kind] else {
            return failure(before.failed(.error, "No provider registered for \(account.kind.rawValue)."))
        }

        func succeed(_ items: [WorkItem], token: String) async -> AccountOutcome {
            let (items, access) = await prioritized(items, account: account, provider: provider, token: token, before: before)
            return AccountOutcome(
                accountID: account.id,
                items: items,
                status: FetchStatus(state: .ok, lastSuccessAt: timestamp, message: nil, projectAccess: access)
            )
        }

        do {
            return await succeed(try await provider.fetchItems(account: account, token: token, kinds: kinds), token: token)
        } catch ProviderError.unauthorized {
            // The token may just have expired. Give the reader one chance to refresh it silently.
            do {
                guard let refreshed = try await tokens.tokenAfterUnauthorized(for: account.id) else {
                    return failure(before.failed(by: ProviderError.unauthorized))
                }
                return await succeed(try await provider.fetchItems(account: account, token: refreshed, kinds: kinds), token: refreshed)
            } catch {
                return failure(before.failed(by: error))
            }
        } catch {
            return failure(before.failed(by: error))
        }
    }

    /// One preset search, with its error as a value so the caller can tell a refused query from a failed account.
    private static func attempt(
        _ search: PresetSearch, in account: Account, token: String, provider: any GitProvider
    ) async -> Result<PresetFetch, any Error> {
        do {
            return .success(try await provider.fetchPresetItems(account: account, token: token, search: search))
        } catch {
            return .failure(error)
        }
    }

    /// The searches of one account, in order; see ``sync(selection:)``.
    private func search(
        account: Account, queries: [PresetQuery], provider: any GitProvider, before: Before, timestamp: Date
    ) async -> AccountOutcome {
        // Nothing selected is in the account's scope: it is asked nothing, not even for its token.
        guard !queries.isEmpty else {
            return AccountOutcome(accountID: account.id, items: [], status: before.status, searched: true)
        }
        var token: String
        switch await readToken(for: account, before: before) {
        case .token(let read):
            token = read
        case .failed(let status):
            let presets = queries.map { PresetOutcome(preset: $0.preset, accountID: account.id, kind: .accountFailed) }
            return AccountOutcome(accountID: account.id, items: before.items, status: status, presets: presets,
                                  searched: true)
        }

        var found: [WorkItem] = []
        var foundIDs: Set<String> = []
        var presets: [PresetOutcome] = []
        var searches = 0
        var requests = 0
        var fetchedAny = false
        var mayRefresh = true
        var accountError: (any Error)?
        var compared: Set<String> = []
        // Items that left a fresh result which can be compared with an earlier one, in the order they left.
        var left: [String] = []

        searching: for query in queries {
            searches += 1
            var result = await Self.attempt(query.search, in: account, token: token, provider: provider)
            // The token may just have expired. Give the reader one chance per sync to refresh it silently.
            if case .failure(ProviderError.unauthorized) = result, mayRefresh {
                mayRefresh = false
                do {
                    guard let refreshed = try await tokens.tokenAfterUnauthorized(for: account.id) else {
                        accountError = ProviderError.unauthorized
                        break searching
                    }
                    token = refreshed
                    searches += 1
                    result = await Self.attempt(query.search, in: account, token: token, provider: provider)
                } catch {
                    accountError = error
                    break searching
                }
            }
            switch result {
            case .success(let fetch):
                fetchedAny = true
                requests += fetch.requests
                found += fetch.items.filter { foundIDs.insert($0.id).inserted }
                let fetchedIDs = fetch.items.map(\.id)
                if let earlier = before.comparableResult(for: query.preset) {
                    compared.formUnion(fetchedIDs)
                    let returned = Set(fetchedIDs)
                    left += earlier.itemIDs.filter { !returned.contains($0) }
                }
                let kind = PresetOutcome.Kind.fetched(
                    itemIDs: fetchedIDs, totalCount: fetch.totalCount, isComplete: fetch.isComplete
                )
                presets.append(PresetOutcome(preset: query.preset, accountID: account.id, kind: kind))
            case .failure(let error):
                switch PresetSearchFailure(error) {
                case .query(let code):
                    presets.append(PresetOutcome(preset: query.preset, accountID: account.id, kind: .queryFailed(code: code)))
                case .account:
                    accountError = error
                    break searching
                }
            }
        }

        if let accountError {
            // The preset that failed and those not searched keep their results, and the account keeps its items. What
            // was found before belongs to new results; with no lookup after the failure, it keeps the priorities it had.
            let searched = Set(presets.map(\.presetID))
            presets += queries.filter { !searched.contains($0.preset.id) }.map {
                PresetOutcome(preset: $0.preset, accountID: account.id, kind: .accountFailed)
            }
            let fresh = Self.keepingPriorities(on: found, from: before.items)
            let items = fresh + before.items.filter { !foundIDs.contains($0.id) }
            // Nothing is looked up: the account failed, and it keeps every item it had anyway.
            return AccountOutcome(accountID: account.id, items: items, status: before.failed(by: accountError),
                                  presets: presets, searches: searches, requests: requests, searched: true,
                                  compared: compared)
        }
        // Searches refused on their own say nothing about the account.
        guard fetchedAny else {
            return AccountOutcome(accountID: account.id, items: [], status: before.status,
                                  presets: presets, searches: searches, requests: requests, searched: true)
        }
        // An item another search of this sync returned is still open; only the others are in question.
        var asked: Set<String> = []
        var lookup = await lookUp(left.filter { !foundIDs.contains($0) && asked.insert($0).inserted },
                                  account: account, provider: provider, token: token, before: before)
        let (items, access) = await prioritized(found + lookup.refreshed, account: account, provider: provider,
                                                token: token, before: before)
        // `applying` keeps the order, so the refreshed items are the ones after those the searches found.
        lookup.refreshed = Array(items.dropFirst(found.count))
        return AccountOutcome(
            accountID: account.id,
            items: Array(items.prefix(found.count)),
            status: FetchStatus(state: .ok, lastSuccessAt: timestamp, message: nil, projectAccess: access),
            presets: presets,
            searches: searches,
            requests: requests,
            searched: true,
            compared: compared,
            lookup: lookup
        )
    }

    /// Asks the provider what became of the items `ids` names, which left a fresh result, by the copies the account had
    /// before. A failed lookup is logged with its count alone and says nothing about any of them.
    private func lookUp(
        _ ids: [String], account: Account, provider: any GitProvider, token: String, before: Before
    ) async -> ItemLookup {
        let copies = Dictionary(before.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = ids.compactMap { copies[$0] }
        guard !items.isEmpty else { return ItemLookup() }
        let states: [String: ItemState]
        do {
            states = try await provider.fetchItemStates(account: account, token: token, items: items)
        } catch {
            syncLog.info("""
                Could not look up \(items.count, privacy: .public) items that left a preset result; \
                they stay only where another result holds them
                """)
            return ItemLookup()
        }
        var lookup = ItemLookup()
        for item in items {
            switch states[item.id] {
            case .closed, .merged:
                lookup.closed.insert(item.id)
                lookup.gone.insert(item.id)
            case .notFound:
                lookup.gone.insert(item.id)
            case .open(let current):
                lookup.refreshed.append(current)
            case nil:
                continue
            }
        }
        return lookup
    }
}
