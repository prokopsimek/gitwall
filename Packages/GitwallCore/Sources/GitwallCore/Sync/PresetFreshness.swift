import Foundation

/// What a preset shows, read from the snapshot alone, and whether opening it should fetch it first. The app's windows,
/// its counts and the widget all ask here, so they agree; nothing here needs a provider, a token or the network.
///
/// A preset covers the accounts its ``Preset/scopes`` name, every account when it has none, and each of them is one
/// part of the preset. The part of an account in ``Snapshot/searchedAccounts`` goes by the preset's result there
/// (``Snapshot/result(for:account:)``, so a result of another selection counts as none): its items, its fetch time,
/// whether it is complete and its query failure. Every other account fetches all its items with each of its syncs, so
/// its part is dated by the account's ``FetchStatus/lastSuccessAt`` and is never fetched on open.
public enum PresetFreshness {
    /// The items `preset` shows: the items of its results in the searched accounts and every item of the other
    /// accounts, filtered and sorted by ``FilterEngine`` as the preset says.
    public static func items(for preset: Preset, in snapshot: Snapshot, accounts: [Account], now: Date) -> [WorkItem] {
        let candidates = snapshot.items(for: preset, searchedAccounts: snapshot.searchedAccounts)
        return FilterEngine.items(matching: preset, in: candidates, accounts: accounts, now: now)
    }

    /// The count of `preset` with what goes with it, for a count shown beside the preset's name.
    public static func display(for preset: Preset, in snapshot: Snapshot, accounts: [Account], now: Date) -> PresetCountDisplay {
        display(for: preset, in: snapshot, accounts: accounts,
                itemCount: items(for: preset, in: snapshot, accounts: accounts, now: now).count)
    }

    /// The same for a caller that already has the preset's items, such as from ``FilterCache``. `itemCount` must be
    /// the number ``items(for:in:accounts:now:)`` gives for the same snapshot.
    public static func display(
        for preset: Preset, in snapshot: Snapshot, accounts: [Account], itemCount: Int
    ) -> PresetCountDisplay {
        let parts = parts(of: preset, in: snapshot, accounts: accounts)
        let times = parts.compactMap(\.fetchedAt)
        // A preset without a part, scoped to an account that is gone, has nothing to wait for.
        let isWaiting = !parts.isEmpty && times.isEmpty
        return PresetCountDisplay(
            count: isWaiting ? nil : itemCount,
            isCapped: parts.contains(where: \.isCapped),
            fetchedAt: times.min(),
            failure: parts.compactMap(\.failure).max { $0.at < $1.at },
            isWaitingForSync: isWaiting
        )
    }

    /// Whether a window that opens `preset` should fetch it first: some searched account in its scope has no result
    /// for the preset's selection, or asked its provider for it longer than `interval` ago. The time asked is the later
    /// of the result's fetch and its query failure, so a preset whose query the provider refuses is tried again once
    /// per interval, not on every open. A part of an account that fetches everything never asks for a fetch.
    /// - Parameter interval: The sync interval, ``AppSettings/refreshInterval``.
    public static func needsFetchOnOpen(
        _ preset: Preset, in snapshot: Snapshot, accounts: [Account], now: Date, interval: TimeInterval
    ) -> Bool {
        parts(of: preset, in: snapshot, accounts: accounts).contains { part in
            guard part.isSearched else { return false }
            guard let asked = part.lastAsked else { return true }
            return now.timeIntervalSince(asked) > interval
        }
    }

    /// The ids a window that opens `presets` should fetch now, in the order of `presets` and each once (a wall can show
    /// a preset on two tiles): those ``needsFetchOnOpen(_:in:accounts:now:interval:)`` says so for, leaving out
    /// `inFlight`, the presets a fetch on open is already running for, so a second window opening one asks nothing.
    public static func presetsToFetchOnOpen(
        _ presets: [Preset], in snapshot: Snapshot, accounts: [Account], now: Date, interval: TimeInterval,
        inFlight: Set<UUID>
    ) -> [UUID] {
        var seen = inFlight
        return presets.compactMap { preset in
            guard seen.insert(preset.id).inserted,
                  needsFetchOnOpen(preset, in: snapshot, accounts: accounts, now: now, interval: interval) else { return nil }
            return preset.id
        }
    }

    /// One account's share of a preset.
    private struct Part {
        let isSearched: Bool
        /// When the items this part shows were fetched; nil while it has none.
        let fetchedAt: Date?
        /// The part's search stopped before the end of what the provider counted.
        let isCapped: Bool
        let failure: PresetQueryFailure?

        /// When the part last asked its provider, successfully or not.
        var lastAsked: Date? { [fetchedAt, failure?.at].compactMap(\.self).max() }
    }

    private static func parts(of preset: Preset, in snapshot: Snapshot, accounts: [Account]) -> [Part] {
        let covered = accounts.filter { account in
            preset.scopes.isEmpty || preset.scopes.contains { $0.accountID == account.id }
        }
        return covered.map { account in
            guard snapshot.searchedAccounts.contains(account.id) else {
                return Part(isSearched: false, fetchedAt: snapshot.accountStatus[account.id]?.lastSuccessAt,
                            isCapped: false, failure: nil)
            }
            guard let result = snapshot.result(for: preset, account: account.id) else {
                return Part(isSearched: true, fetchedAt: nil, isCapped: false, failure: nil)
            }
            let isCapped = result.fetchedAt != nil && !result.isComplete && result.totalCount > result.itemIDs.count
            return Part(isSearched: true, fetchedAt: result.fetchedAt, isCapped: isCapped, failure: result.failure)
        }
    }
}

/// What the count of one preset shows, from ``PresetFreshness``. Data only: the popover, the main window's sidebar,
/// Settings › Presets, onboarding and the widget turn it into words through the String Catalog.
public struct PresetCountDisplay: Hashable, Sendable {
    /// How many items ``PresetFreshness/items(for:in:accounts:now:)`` gives; nil shows "–", because no part of the
    /// preset was fetched yet.
    public var count: Int?
    /// Shows "+" after the count: a search of the preset stopped before the end of what its provider counted, as a
    /// GitHub search does above 1000 results.
    public var isCapped: Bool
    /// The oldest fetch time among the parts that were fetched, for the tooltip; nil while none was.
    public var fetchedAt: Date?
    /// The latest query failure among the searched parts, shown as "Query failed". ``count`` and ``fetchedAt`` still
    /// describe what the parts fetched before it.
    public var failure: PresetQueryFailure?
    /// No part of the preset was fetched yet: a widget shows "Waiting for sync" and a window its loading indicator.
    public var isWaitingForSync: Bool
}
