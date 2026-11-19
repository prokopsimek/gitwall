import Foundation

/// What the preset searches of one sync found out about the items of the accounts that ran them, for
/// ``SnapshotDiff/changes(from:to:accounts:searches:)``. A search returns only the open items that match, so an item
/// missing from it may be closed or may just no longer match, and the first result of a (preset, account) pair has
/// nothing to compare with. Items are named by ``WorkItem/id``, which carries its account.
public struct SearchFindings: Hashable, Sendable {
    /// Accounts that fetched through preset searches in the sync, whatever came of the searches. Every other account
    /// downloaded all its items and keeps the plain rules of ``SnapshotDiff``.
    public var accounts: Set<UUID>
    /// Items that left a fresh result and that the provider then confirmed closed or merged.
    public var closedItemIDs: Set<String>
    /// Items held by a result fetched in the sync whose pair had an earlier result of the same selection. An item of
    /// ``accounts`` that is new to the snapshot is news only when it is here; otherwise it came with the first result of
    /// its pair, or of an edited preset, and is part of the baseline.
    public var comparedItemIDs: Set<String>

    public init(accounts: Set<UUID>, closedItemIDs: Set<String>, comparedItemIDs: Set<String>) {
        self.accounts = accounts
        self.closedItemIDs = closedItemIDs
        self.comparedItemIDs = comparedItemIDs
    }

    /// A sync in which no account searched presets.
    public static let none = SearchFindings(accounts: [], closedItemIDs: [], comparedItemIDs: [])
}
