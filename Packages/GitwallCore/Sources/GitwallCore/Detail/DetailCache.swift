import Foundation

/// The recent details, one per item, for whoever shows Detail. A detail is valid while its item keeps the
/// `updatedAt` it was fetched for. One with a part that failed in passing is not kept, so opening the item again
/// tries again; a missing permission is kept until ``forget(accountID:)``, which the app calls when the account's
/// credential changes (Try Again bypasses the cache too).
public struct DetailCache: Sendable {
    private struct Entry: Sendable {
        var detail: ItemDetail
        var accountID: UUID
    }

    private let limit: Int
    private var entries: [String: Entry] = [:]
    /// Item ids, least recently stored first.
    private var order: [String] = []

    public init(limit: Int = 100) {
        self.limit = limit
    }

    public func detail(for item: WorkItem) -> ItemDetail? {
        guard let entry = entries[item.id], entry.detail.itemUpdatedAt == item.updatedAt else { return nil }
        return entry.detail
    }

    public mutating func store(_ detail: ItemDetail, accountID: UUID) {
        guard !detail.failures.contains(where: \.isPassing) else {
            forget(itemID: detail.itemID)
            return
        }
        entries[detail.itemID] = Entry(detail: detail, accountID: accountID)
        order.removeAll { $0 == detail.itemID }
        order.append(detail.itemID)
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    /// Everything fetched with an account's credential, after the credential or its scopes changed.
    public mutating func forget(accountID: UUID) {
        let ids = entries.filter { $0.value.accountID == accountID }.map(\.key)
        for id in ids { forget(itemID: id) }
    }

    public mutating func forget(itemID: String) {
        entries[itemID] = nil
        order.removeAll { $0 == itemID }
    }
}
