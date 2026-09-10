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
    /// Nothing is reported for the very first sync (`previous == nil`), so a fresh install never produces a burst.
    public static func changes(from previous: Snapshot?, to current: Snapshot, accounts: [Account]) -> [ItemChange] {
        guard let previous else { return [] }
        let identities = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.me) })
        let previousByID = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.id, $0) })
        var changes: [ItemChange] = []

        for item in current.items {
            let me = identities[item.accountID] ?? nil
            let requestedNow = isRequested(me, in: item)
            guard let old = previousByID[item.id] else {
                changes.append(ItemChange(item: item, event: .newItem))
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
