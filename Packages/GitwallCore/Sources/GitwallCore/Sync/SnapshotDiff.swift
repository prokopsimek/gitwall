import Foundation

public struct ItemChange: Hashable, Sendable {
    public let item: WorkItem
    public let event: NotificationEvent

    public init(item: WorkItem, event: NotificationEvent) {
        self.item = item
        self.event = event
    }
}

public struct RoutedNotification: Hashable, Sendable {
    public let change: ItemChange
    public let preset: Preset
}

/// Detects what changed between two syncs and which presets want to be told about it.
public enum SnapshotDiff {
    /// How long before the previous sync an item of a searching account may have been opened and still be a new item.
    /// GitHub's search index can lag behind, so an item opened just before the previous sync may first show up in a
    /// search now.
    static let searchIndexLag: TimeInterval = 10 * 60

    /// Nothing is reported for the very first sync (`previous == nil`), so a fresh install never produces a burst.
    ///
    /// An item that left the snapshot is `.closed`, one that joined it `.newItem` (and `.reviewRequested` when it asks
    /// me), and an item in both gets an event for each change it went through. For the items of an account in
    /// ``SearchFindings/accounts`` two of these rules are narrower, because its searches return only the open items that
    /// match: an item that left is `.closed` only when it is in ``SearchFindings/closedItemIDs``, and one that joined is
    /// news only when it is in ``SearchFindings/comparedItemIDs``. Even then it is `.newItem` only when it was opened
    /// after the previous sync, less ``searchIndexLag``: an older item joined because it started to match, through a
    /// review request, a label or recent activity, so it reports only `.reviewRequested`, when it asks me. An account in
    /// the previous snapshot's ``Snapshot/searchedAccounts`` that did not search now has a baseline instead: it
    /// downloaded the open items its download reaches, which are neither all nor only those its searches had found, so
    /// neither an item that joined it nor one that left it says anything. Closed and merged are both `.closed`.
    public static func changes(
        from previous: Snapshot?, to current: Snapshot, accounts: [Account], searches: SearchFindings = .none
    ) -> [ItemChange] {
        guard let previous else { return [] }
        let identities = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.me) })
        let previousByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        let stoppedSearching = previous.searchedAccounts.subtracting(searches.accounts)
        var changes: [ItemChange] = []

        for item in current.items {
            let me = identities[item.accountID] ?? nil
            let requestedNow = isRequested(me, in: item)
            guard let old = previousByID[item.id] else {
                // The first result of a pair, or of an edited preset, is the baseline its later results are compared
                // to, and so is the first full download after the account searched.
                let searched = searches.accounts.contains(item.accountID)
                if searched, !searches.comparedItemIDs.contains(item.id) { continue }
                if stoppedSearching.contains(item.accountID) { continue }
                if !searched || item.createdAt > previous.fetchedAt.addingTimeInterval(-searchIndexLag) {
                    changes.append(ItemChange(item: item, event: .newItem))
                }
                if requestedNow { changes.append(ItemChange(item: item, event: .reviewRequested)) }
                continue
            }
            if requestedNow, !isRequested(me, in: old) {
                changes.append(ItemChange(item: item, event: .reviewRequested))
            }
            if item.reviewState == .approved, old.reviewState != .approved {
                changes.append(ItemChange(item: item, event: .approved))
            }
            if item.reviewState == .changesRequested, old.reviewState != .changesRequested {
                changes.append(ItemChange(item: item, event: .changesRequested))
            }
            if item.ciState == .failure, old.ciState != .failure {
                changes.append(ItemChange(item: item, event: .ciFailed))
            }
        }

        let currentIDs = Set(current.items.map(\.id))
        for old in previous.items where !currentIDs.contains(old.id) {
            // It may only have stopped matching, or belong to a preset this sync did not search, or lie beyond the
            // reach of the first full download after the account searched.
            if searches.accounts.contains(old.accountID), !searches.closedItemIDs.contains(old.id) { continue }
            if stoppedSearching.contains(old.accountID) { continue }
            changes.append(ItemChange(item: old, event: .closed))
        }
        return changes
    }

    /// Pairs each change with the first preset that both shows the item and subscribes to the event.
    public static func notifications(
        for changes: [ItemChange],
        presets: [Preset],
        accounts: [Account],
        previous: Snapshot?,
        now: Date
    ) -> [RoutedNotification] {
        let identities = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.me) })
        return changes.compactMap { change in
            let preset = presets.first { preset in
                preset.notifications.contains(change.event)
                    && FilterEngine.matches(change.item, preset: preset, identities: identities, now: now)
            }
            return preset.map { RoutedNotification(change: change, preset: $0) }
        }
    }

    private static func isRequested(_ me: UserRef?, in item: WorkItem) -> Bool {
        guard let me else { return false }
        return item.requestedReviewers.contains { $0.login.caseInsensitiveCompare(me.login) == .orderedSame }
    }
}
