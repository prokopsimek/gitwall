import Foundation

/// What the preset searches of one sync found out about the items of the accounts that ran them, for
/// ``SnapshotDiff/changes(from:to:accounts:searches:)``. A search returns only the open items that match, so an item
/// missing from it may be closed or may just no longer match, and the first result of a (preset, account) pair has
/// nothing to compare with. Items are named by ``WorkItem/id``, which carries its account.
public struct SearchFindings: Hashable, Sendable {
    /// Accounts that fetched through preset searches in the sync, whatever came of the searches. Every other account
    /// keeps the plain rules of ``SnapshotDiff``, unless the previous snapshot names it in
    /// ``Snapshot/searchedAccounts``: a full download reaches neither all nor only the items its searches had found, so
    /// what joined or left it since is a baseline and reports nothing.
    public var accounts: Set<UUID>
    /// Items that left a fresh result and that the provider then confirmed closed or merged.
    public var closedItemIDs: Set<String>
    /// For each item held by a result fetched in the sync whose pair had an earlier result of the same selection, the
    /// date that earlier result was fetched. An item of ``accounts`` that is new to the snapshot is news only when it is
    /// here or in ``comparedItemIDs``; otherwise it came with the first result of its pair, or of an edited preset, and
    /// is part of the baseline. It is a new item only when it was opened after the earlier result of its pair, less
    /// ``SnapshotDiff/searchIndexLag``. When several pairs compared the item, the oldest date is kept, so it is
    /// reported rather than missed.
    public private(set) var comparedSince: [String: Date]
    /// Compared items that carry no date: they are judged by the previous snapshot's date instead.
    private var comparedWithoutDate: Set<String>

    /// Every item that was compared with an earlier result, dated or not.
    public var comparedItemIDs: Set<String> { comparedWithoutDate.union(comparedSince.keys) }

    public init(
        accounts: Set<UUID>, closedItemIDs: Set<String>, comparedItemIDs: Set<String> = [],
        comparedSince: [String: Date] = [:]
    ) {
        self.accounts = accounts
        self.closedItemIDs = closedItemIDs
        self.comparedSince = comparedSince
        self.comparedWithoutDate = comparedItemIDs.subtracting(comparedSince.keys)
    }

    /// Adds items compared with an earlier result fetched at the date given for each; an item known already keeps the
    /// older of the two dates.
    public mutating func merge(compared dates: [String: Date]) {
        for (id, date) in dates {
            comparedWithoutDate.remove(id)
            comparedSince[id] = comparedSince[id].map { min($0, date) } ?? date
        }
    }

    /// A sync in which no account searched presets.
    public static let none = SearchFindings(accounts: [], closedItemIDs: [])
}
