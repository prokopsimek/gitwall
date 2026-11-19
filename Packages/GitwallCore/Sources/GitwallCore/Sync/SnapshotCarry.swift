import Foundation

/// What the app keeps of the "new" dots and the previous snapshot when a new snapshot arrives.
///
/// A sync starts a new round: its dots and its previous snapshot replace the old ones. A fetch on open runs between
/// syncs, whenever a list opens, so it must not wipe what the last sync showed and the user has not seen yet: its dots
/// are added to the old ones, and the previous snapshot keeps the items the earlier one held, because a click on a
/// "Closed or merged" notification looks the closed item up there.
public enum SnapshotCarry {
    /// What wrote the new snapshot.
    public enum Origin: Sendable {
        case sync
        case fetchOnOpen
    }

    public struct Kept: Equatable, Sendable {
        public let newItemIDs: Set<String>
        public let previous: Snapshot?
    }

    /// - Parameters:
    ///   - current: the snapshot that was just written.
    ///   - replaced: the snapshot it replaced (``SyncResult/previous``).
    ///   - newItemIDs: the items the diff of this snapshot reports as new.
    ///   - earlierPrevious: the previous snapshot the app kept so far.
    ///   - earlierNewItemIDs: the dots shown so far.
    public static func kept(
        after origin: Origin, current: Snapshot, replaced: Snapshot?, newItemIDs: Set<String>,
        earlierPrevious: Snapshot?, earlierNewItemIDs: Set<String>
    ) -> Kept {
        switch origin {
        case .sync:
            return Kept(newItemIDs: newItemIDs, previous: replaced)
        case .fetchOnOpen:
            let present = Set(current.items.map(\.id))
            let dots = earlierNewItemIDs.union(newItemIDs).intersection(present)
            return Kept(newItemIDs: dots, previous: merged(replaced, earlierPrevious))
        }
    }

    /// `replaced` with the items of `earlier` it lacks. Its other fields stay; without it, `earlier` is all there is.
    private static func merged(_ replaced: Snapshot?, _ earlier: Snapshot?) -> Snapshot? {
        guard var merged = replaced else { return earlier }
        guard let earlier else { return merged }
        let known = Set(merged.items.map(\.id))
        merged.items += earlier.items.filter { !known.contains($0.id) }
        return merged
    }
}
