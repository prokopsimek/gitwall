import Foundation

/// What selects one preset's items in one account, for ``GitProvider/fetchPresetItems(account:token:search:)``.
public struct PresetSearch: Hashable, Sendable {
    public var filter: ItemFilter
    /// The repositories of the account the preset looks at, by full name; nil for every source of the account.
    public var repositories: Set<String>?
    public var sort: SortOrder
    public var kinds: Set<ItemKind>

    public init(filter: ItemFilter, repositories: Set<String>?, sort: SortOrder, kinds: Set<ItemKind>) {
        self.filter = filter
        self.repositories = repositories
        self.sort = sort
        self.kinds = kinds
    }

    /// The search of `preset` in the account `accountID`, with the scope the local filter applies there: a preset of
    /// every account, or a scope of the account without repositories, covers every source; scopes with repositories
    /// cover those of all of them. Nil when the preset is scoped to other accounts only.
    public init?(preset: Preset, accountID: UUID) {
        var repositories: Set<String>?
        if !preset.scopes.isEmpty {
            let scopes = preset.scopes.filter { $0.accountID == accountID }
            guard !scopes.isEmpty else { return nil }
            // One scope without repositories covers the whole account, as in `FilterEngine`.
            if scopes.allSatisfy({ $0.repositories != nil }) {
                repositories = scopes.reduce(into: []) { $0.formUnion($1.repositories ?? []) }
            }
        }
        self.init(filter: preset.filter, repositories: repositories, sort: preset.sort, kinds: preset.kinds)
    }
}

/// What ``GitProvider/fetchPresetItems(account:token:search:)`` found.
public struct PresetFetch: Hashable, Sendable {
    /// Each item once, from the account's sources only.
    public var items: [WorkItem]
    /// How many items the provider counted over all its searches, which can be more than ``items``.
    public var totalCount: Int
    /// False when a search stopped before its end, for example at the provider's cap of 1000 results.
    public var isComplete: Bool
    /// How many HTTP requests the fetch sent, for the log.
    public var requests: Int

    public init(items: [WorkItem], totalCount: Int, isComplete: Bool, requests: Int) {
        self.items = items
        self.totalCount = totalCount
        self.isComplete = isComplete
        self.requests = requests
    }
}
