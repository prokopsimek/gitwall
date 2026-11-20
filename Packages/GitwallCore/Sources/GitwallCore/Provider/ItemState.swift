import Foundation

/// What ``GitProvider/fetchItemStates(account:token:items:)`` learned about one item. A preset search returns only the
/// open items that match, so an item missing from a fresh result may be closed, merged, deleted or just no longer
/// matching; this tells them apart.
public enum ItemState: Hashable, Sendable {
    /// Still open, as the provider maps the item in a list, so its data is current.
    case open(WorkItem)
    case closed
    /// A pull request or merge request that was merged.
    case merged
    /// The provider has no such item, or the credential may no longer see it.
    case notFound
}
