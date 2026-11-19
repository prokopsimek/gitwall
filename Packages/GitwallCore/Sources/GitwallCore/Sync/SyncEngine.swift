import Foundation

public struct SyncResult: Sendable {
    public let snapshot: Snapshot
    /// Snapshot that was current before this sync, for diffing and notifications.
    public let previous: Snapshot?
    /// What the preset searches of this sync found out, for ``SnapshotDiff/changes(from:to:accounts:searches:)``.
    public let searches: SearchFindings
    /// The counts this sync wrote to the log.
    let report: SyncReport?
    /// The accounts this sync could not fetch but left showing what they showed, as it logged them. None for an
    /// on-demand fetch, which changes no account's status.
    let quietFailures: [QuietFailure]
}

/// Fetches every configured account through its provider and writes the merged snapshot.
/// Accounts that fail keep their previous items so the widget never goes blank because of one outage. A passing outage
/// (a gateway error, a lost connection or an answer that could not be read) does not even show until it lasts for a
/// third sync in a row; until then the account keeps what it showed (`ok`, or an error it already had), only
/// ``FetchStatus/consecutiveFailures`` counts it, and the unified log gets a line about it.
/// Preset results carry over from the previous snapshot, except those of deleted presets and removed accounts. In an
/// account that searched presets in the sync, so do the items they hold; an account that downloaded everything keeps
/// only what it downloaded. With a ``SyncSelection``, an account whose provider searches presets on the server
/// searches only the selected presets, asks the provider what became of the items that left those results, and
/// reports what it learned in ``SyncResult/searches``; see ``sync(selection:)``. ``syncPresets(_:)`` fetches presets
/// a window opens the same way, between syncs.
///
/// One sync or on-demand fetch runs at a time. Each reads the snapshot, waits for its providers and writes the snapshot
/// back, and the actor alone would let another one start during those waits and lose what the first one wrote.
public actor SyncEngine {
    /// Failed syncs in a row, for a passing reason, that an account rides out without showing an error.
    static let quietFailures = 2

    private let providers: [ProviderKind: any GitProvider]
    private let tokens: any TokenReading
    private let configStore: ConfigStore
    private let snapshotStore: SnapshotStore
    private let now: @Sendable () -> Date

    /// Whether a sync or an on-demand fetch has its turn now.
    private var isRunning = false
    /// Calls waiting for their turn, in the order they came.
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The on-demand fetch that waits for its turn, which every later request joins until the turn comes.
    private var pendingFetch: PendingFetch?
    /// Calls to ``sync(selection:)`` and ``syncPresets(_:)`` so far, counted as they arrive and before they wait; lets
    /// tests line up concurrent calls.
    private(set) var callCount = 0

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
    /// The searching accounts become the snapshot's ``Snapshot/searchedAccounts``; a sync without a selection names none.
    /// It waits while another sync or an on-demand fetch runs. Every sync writes one line of counts to the unified log,
    /// failed accounts and the requests of every account included (see ``SyncReport``), and one line per account that
    /// failed quietly.
    public func sync(selection: SyncSelection? = nil) async throws -> SyncResult {
        callCount += 1
        await takeTurn()
        defer { endTurn() }

        let clock = ContinuousClock()
        let start = clock.now
        let config = try configStore.load()
        let previous = try snapshotStore.load()
        let timestamp = now()

        let plans = config.accounts.map { ($0, plan(for: $0, in: config, selection: selection)) }
        let outcomes = await outcomes(of: plans, previous: previous, timestamp: timestamp)
        let merged = Merged(outcomes, config: config, previous: previous, timestamp: timestamp)
        var status: [UUID: FetchStatus] = [:]
        for outcome in outcomes { status[outcome.accountID] = outcome.status }

        let snapshot = Snapshot(
            fetchedAt: timestamp,
            items: merged.items,
            accountStatus: status,
            presetResults: merged.results,
            searchedAccounts: merged.findings.accounts
        )
        try snapshotStore.save(snapshot)
        let quietFailures = outcomes.compactMap(\.quietFailure)
        for failure in quietFailures { failure.write() }
        let failedAccounts = outcomes.filter(\.failed).count
        let requests = outcomes.reduce(0) { $0 + $1.requests }
        let report = if let selection {
            SyncReport(selection: selection, failedAccounts: failedAccounts,
                       searches: outcomes.reduce(0) { $0 + $1.searches }, requests: requests,
                       items: snapshot.items.count, duration: clock.now - start)
        } else {
            SyncReport(everything: failedAccounts, requests: requests, items: snapshot.items.count,
                       duration: clock.now - start)
        }
        report.write()
        return SyncResult(snapshot: snapshot, previous: previous, searches: merged.findings, report: report,
                          quietFailures: quietFailures)
    }

    /// Fetches `presetIDs` now, for a window that opens them, and writes the snapshot.
    ///
    /// Each account whose provider answers ``ProviderCapabilities/presetSearch`` for it searches the given presets that
    /// exist and are in its scope, in the order of the configuration, exactly as ``sync(selection:)`` searches selected
    /// ones: the same refused queries, the same lookup of the items that left a fresh result, the same priorities,
    /// results and items, and the same ``SyncResult/searches`` for the diff and the notifications, so a preset's first
    /// result reports nothing. What differs:
    /// - No account's ``FetchStatus`` changes, whatever the searches come to. This is no sync of the account: it neither
    ///   counts in the quiet period nor shows an error. An account error leaves the presets the account did not fetch
    ///   yet as they were and only counts in the log line.
    /// - Every other account is asked nothing and keeps its items, and so does a searching account that none of the
    ///   presets covers.
    /// - ``Snapshot/fetchedAt`` stays as it was, and ``Snapshot/searchedAccounts`` gains the accounts that searched.
    ///
    /// It waits while a sync or another on-demand fetch runs. Requests that wait at the same time run as one fetch of
    /// all their presets, and each of them gets that fetch's result. What ran during the wait may have fetched those
    /// presets already, so a fetch that had to wait fetches only the ones that, by the snapshot it starts from, still
    /// need it (``PresetFreshness/needsFetchOnOpen(_:in:accounts:now:interval:)``). Each fetch writes one line of counts
    /// to the unified log, marked as on demand.
    /// - Returns: Nil when the fetch waited and none of its presets was left to fetch: no provider was asked and neither
    ///   the snapshot nor the log was written.
    public func syncPresets(_ presetIDs: [UUID]) async throws -> SyncResult? {
        callCount += 1
        if pendingFetch != nil {
            pendingFetch?.presetIDs.formUnion(presetIDs)
            return try await withCheckedThrowingContinuation { pendingFetch?.callers.append($0) }
        }
        pendingFetch = PendingFetch(presetIDs: Set(presetIDs))
        let waited = await takeTurn()
        defer { endTurn() }
        // From here on a new request waits for the next turn instead of joining this fetch.
        guard let fetch = pendingFetch else { preconditionFailure("The fetch waiting for its turn was taken by another") }
        pendingFetch = nil

        let result: Result<SyncResult?, any Error>
        do {
            result = .success(try await fetchPresets(fetch.presetIDs, waited: waited))
        } catch {
            result = .failure(error)
        }
        for caller in fetch.callers { caller.resume(with: result) }
        return try result.get()
    }

    // MARK: - Turns

    /// An on-demand fetch waiting for its turn: every preset asked for so far, and the requests that joined it.
    private struct PendingFetch {
        var presetIDs: Set<UUID>
        var callers: [CheckedContinuation<SyncResult?, any Error>] = []
    }

    /// Returns once nothing else runs, in the order the calls came: true when another call ran first and this one waited.
    @discardableResult
    private func takeTurn() async -> Bool {
        guard isRunning else {
            isRunning = true
            return false
        }
        await withCheckedContinuation { waiting.append($0) }
        return true
    }

    /// Hands the turn straight to the next waiting call, so that nothing can start in between.
    private func endTurn() {
        guard !waiting.isEmpty else {
            isRunning = false
            return
        }
        waiting.removeFirst().resume()
    }

    // MARK: - Internals

    /// See ``syncPresets(_:)``. Without a wait nothing is left out: the presets were picked by the same rule right
    /// before, and nothing ran since.
    private func fetchPresets(_ presetIDs: Set<UUID>, waited: Bool) async throws -> SyncResult? {
        let clock = ContinuousClock()
        let start = clock.now
        let config = try configStore.load()
        let previous = try snapshotStore.load()
        let timestamp = now()

        var presets = config.presets.filter { presetIDs.contains($0.id) }
        if waited, let previous {
            presets = presets.filter {
                PresetFreshness.needsFetchOnOpen($0, in: previous, accounts: config.accounts, now: timestamp,
                                                 interval: config.settings.refreshInterval)
            }
            guard !presets.isEmpty else { return nil }
        }
        let plans = config.accounts.compactMap { account in onDemandPlan(for: account, presets: presets).map { (account, $0) } }
        let outcomes = await outcomes(of: plans, previous: previous, timestamp: timestamp)
        let merged = Merged(outcomes, config: config, previous: previous, timestamp: timestamp)
        let accountIDs = Set(config.accounts.map(\.id))

        let snapshot = Snapshot(
            // A few presets were fetched, not the accounts, so the date of the data and every status stay as they were.
            fetchedAt: previous?.fetchedAt ?? timestamp,
            items: merged.items,
            accountStatus: (previous?.accountStatus ?? [:]).filter { accountIDs.contains($0.key) },
            presetResults: merged.results,
            searchedAccounts: (previous?.searchedAccounts ?? []).intersection(accountIDs).union(merged.findings.accounts)
        )
        try snapshotStore.save(snapshot)
        let report = SyncReport(
            onDemand: presets.count, failedAccounts: outcomes.filter(\.failed).count,
            searches: outcomes.reduce(0) { $0 + $1.searches }, requests: outcomes.reduce(0) { $0 + $1.requests },
            items: snapshot.items.count, duration: clock.now - start
        )
        report.write()
        return SyncResult(snapshot: snapshot, previous: previous, searches: merged.findings, report: report,
                          quietFailures: [])
    }

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
        guard let selection, let provider = presetSearcher(for: account) else {
            return .everything(Self.kindsNeeded(for: account, presets: config.presets))
        }
        return .presets(Self.queries(for: selection.presetIDs.compactMap(config.preset(id:)), in: account), provider)
    }

    /// The searches of `presets` in an account whose provider searches presets. Nil for every other account, and for
    /// one that none of the presets covers: an on-demand fetch asks them nothing.
    private func onDemandPlan(for account: Account, presets: [Preset]) -> Plan? {
        guard let provider = presetSearcher(for: account) else { return nil }
        let queries = Self.queries(for: presets, in: account)
        return queries.isEmpty ? nil : .presets(queries, provider)
    }

    /// The provider of `account` when it searches each preset on the server for this account.
    private func presetSearcher(for account: Account) -> (any GitProvider)? {
        guard let provider = providers[account.kind], provider.capabilities(for: account).presetSearch else { return nil }
        return provider
    }

    /// What each of `presets` that covers `account` searches there, in their order.
    private static func queries(for presets: [Preset], in account: Account) -> [PresetQuery] {
        presets.compactMap { preset in
            PresetSearch(preset: preset, accountID: account.id).map { PresetQuery(preset: preset, search: $0) }
        }
    }

    /// Fetches every account of `plans` at the same time.
    private func outcomes(of plans: [(Account, Plan)], previous: Snapshot?, timestamp: Date) async -> [AccountOutcome] {
        await withTaskGroup(of: AccountOutcome.self, returning: [AccountOutcome].self) { group in
            for (account, plan) in plans {
                let before = Before(account: account, previous: previous)
                group.addTask {
                    // Every request the account sends in this sync lands in one tally, whichever provider call sends it
                    // and however that call ends.
                    let tally = RequestTally()
                    var outcome = await tally.run {
                        switch plan {
                        case .everything(let kinds):
                            await self.fetch(account: account, kinds: kinds, before: before, timestamp: timestamp)
                        case .presets(let queries, let provider):
                            await self.search(account: account, queries: queries, provider: provider, before: before,
                                              timestamp: timestamp)
                        }
                    }
                    outcome.requests = tally.count
                    return outcome
                }
            }
            var collected: [AccountOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
    }

    /// The snapshot's items and preset results once the accounts of `outcomes` fetched, and what their searches found
    /// out. An account of the configuration without an outcome was asked nothing and keeps its items as they were.
    private struct Merged {
        let items: [WorkItem]
        let results: [PresetResult]
        let findings: SearchFindings

        init(_ outcomes: [AccountOutcome], config: AppConfig, previous: Snapshot?, timestamp: Date) {
            var fresh: [WorkItem] = []
            var presetOutcomes: [PresetOutcome] = []
            var findings = SearchFindings.none
            var gone: Set<String> = []
            var refreshed: [String: WorkItem] = [:]
            for outcome in outcomes {
                fresh.append(contentsOf: outcome.items)
                presetOutcomes.append(contentsOf: outcome.presets)
                if outcome.searched { findings.accounts.insert(outcome.accountID) }
                findings.comparedItemIDs.formUnion(outcome.compared)
                findings.closedItemIDs.formUnion(outcome.lookup.closed)
                gone.formUnion(outcome.lookup.gone)
                for item in outcome.lookup.refreshed { refreshed[item.id] = item }
            }
            let asked = Set(outcomes.map(\.accountID))
            let untouched = Set(config.accounts.map(\.id)).subtracting(asked)
            fresh += (previous?.items ?? []).filter { untouched.contains($0.accountID) }

            let presetIDs = Set(config.presets.map(\.id))
            let accountIDs = Set(config.accounts.map(\.id))
            let carried = (previous?.presetResults ?? []).filter {
                presetIDs.contains($0.presetID) && accountIDs.contains($0.accountID)
            }
            results = PresetResult.merged(carried, with: presetOutcomes, at: timestamp).map {
                SyncEngine.removing(gone, from: $0)
            }
            // A refreshed item takes the place of its previous copy, and stays only where a result still holds it. Only
            // the results of an account that searched now hold items: one that downloaded everything returned every
            // item it still has, and one that was asked nothing kept all of them above.
            let earlier = (previous?.items ?? []).map { refreshed[$0.id] ?? $0 }
            let holding = results.filter { findings.accounts.contains($0.accountID) }
            items = FilterEngine.sort(SyncEngine.items(fresh, keepingFrom: earlier, heldBy: holding), by: .lastActivity)
            self.findings = findings
        }
    }

    private struct AccountOutcome: Sendable {
        let accountID: UUID
        let items: [WorkItem]
        /// Nil leaves the account without a status: it had none, and this sync asked it nothing.
        let status: FetchStatus?
        /// What each preset search of the account came to.
        var presets: [PresetOutcome] = []
        /// Preset searches sent, a repeat after a token refresh included.
        var searches = 0
        /// Every HTTP request the account sent in this sync, whatever came of it; set once the account is done.
        var requests = 0
        /// Whether the account fetched through preset searches, whatever came of them.
        var searched = false
        /// Whether an account error stopped the fetch, its token could not be read included.
        var failed = false
        /// The line for the log when an account error stopped the fetch and the account rides it out unseen.
        var quietFailure: QuietFailure?
        /// Items held by a result fetched now whose pair had an earlier result of the same selection.
        var compared: Set<String> = []
        /// What the provider said about the items that left a fresh result.
        var lookup = ItemLookup()
    }

    /// The level of the line a failed lookup writes; see ``SyncReport/logLevel``.
    static let lookupFailureLogLevel = SyncReport.logLevel

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
        /// `quietFailures` and shows from the next one on. Anything else shows at once and ends the series. A provider
        /// reports an answer it could not read as a network error, so such an answer counts the same way.
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
            AccountOutcome(accountID: account.id, items: before.items, status: status, failed: true)
        }
        func failure(by error: any Error) -> AccountOutcome {
            let status = before.failed(by: error)
            var outcome = failure(status)
            outcome.quietFailure = Self.quietFailure(of: account, by: error, leaving: status)
            return outcome
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
                    return failure(by: ProviderError.unauthorized)
                }
                return await succeed(try await provider.fetchItems(account: account, token: refreshed, kinds: kinds), token: refreshed)
            } catch {
                return failure(by: error)
            }
        } catch {
            return failure(by: error)
        }
    }

    /// What the log gets when `error` left `account` with `status`: a quiet failure while the account rides it out,
    /// nothing when the failure shows or is no passing one.
    private static func quietFailure(
        of account: Account, by error: any Error, leaving status: FetchStatus
    ) -> QuietFailure? {
        // Only a passing failure counts, and it shows once the count passes `quietFailures`.
        guard (1...quietFailures).contains(status.consecutiveFailures) else { return nil }
        return QuietFailure(provider: account.kind, error: error, failure: status.consecutiveFailures)
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
                                  searched: true, failed: true)
        }

        var found: [WorkItem] = []
        var foundIDs: Set<String> = []
        var presets: [PresetOutcome] = []
        var searches = 0
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
            let status = before.failed(by: accountError)
            let quiet = Self.quietFailure(of: account, by: accountError, leaving: status)
            return AccountOutcome(accountID: account.id, items: items, status: status,
                                  presets: presets, searches: searches, searched: true,
                                  failed: true, quietFailure: quiet, compared: compared)
        }
        // Searches refused on their own say nothing about the account.
        guard fetchedAny else {
            return AccountOutcome(accountID: account.id, items: [], status: before.status,
                                  presets: presets, searches: searches, searched: true)
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
            syncLog.log(level: Self.lookupFailureLogLevel, """
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
