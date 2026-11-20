import Foundation

/// A preset query that the provider refused on its own, while the account as a whole worked: GraphQL errors in a 200
/// answer, or a search the provider rejected. It belongs to the preset ("Query failed") and never changes the account's
/// ``FetchStatus``.
public struct PresetQueryFailure: Codable, Hashable, Sendable {
    /// The provider's error code, kept for the log and for telling one refusal from another.
    public var code: String
    public var at: Date

    public init(code: String, at: Date) {
        self.code = code
        self.at = at
    }
}

/// The last search of one preset in one account: which items it found and how far it got. Results are keyed by the
/// pair, so a preset that covers two accounts has two results. See ``Snapshot/result(for:account:)`` for reading one.
public struct PresetResult: Codable, Hashable, Sendable {
    public var presetID: UUID
    public var accountID: UUID
    /// ``WorkItem/id`` of every item the search returned; the items themselves are in ``Snapshot/items``.
    public var itemIDs: [String]
    /// Nil until a search of this selection succeeded once.
    public var fetchedAt: Date?
    /// How many items the provider counted, which can be more than ``itemIDs`` when the search stopped early.
    public var totalCount: Int
    /// False when the search did not reach the end, for example because the provider caps a search at 1000 items.
    public var isComplete: Bool
    /// ``Preset/selectionFingerprint`` of the preset the search ran for. A result whose fingerprint differs from the
    /// preset's current one describes another selection and counts as never fetched.
    public var selection: String
    /// The last search of this selection failed on its own; the fields above still describe the one before it.
    public var failure: PresetQueryFailure?

    public init(
        presetID: UUID,
        accountID: UUID,
        itemIDs: [String],
        fetchedAt: Date?,
        totalCount: Int,
        isComplete: Bool,
        selection: String,
        failure: PresetQueryFailure? = nil
    ) {
        self.presetID = presetID
        self.accountID = accountID
        self.itemIDs = itemIDs
        self.fetchedAt = fetchedAt
        self.totalCount = totalCount
        self.isComplete = isComplete
        self.selection = selection
        self.failure = failure
    }

    /// The order results are kept and written in: by preset, then by account.
    static func precedes(_ lhs: PresetResult, _ rhs: PresetResult) -> Bool {
        (lhs.presetID.uuidString, lhs.accountID.uuidString) < (rhs.presetID.uuidString, rhs.accountID.uuidString)
    }
}
