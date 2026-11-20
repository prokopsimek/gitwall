import Foundation

public enum FetchState: String, Codable, Sendable, Hashable {
    case ok
    case error
    case rateLimited
    case needsReauth
}

/// Whether the credential could read the provider's planning boards, the source of ``WorkItem/projectPriority``.
public enum ProjectAccess: String, Codable, Sendable, Hashable {
    case granted
    /// Priorities come from labels only until the account signs in again or gets a token that may read projects.
    case denied
}

public struct FetchStatus: Hashable, Sendable {
    public var state: FetchState
    public var lastSuccessAt: Date?
    public var message: String?
    /// Nil when the provider has no planning boards or the account has not synced since this was added.
    public var projectAccess: ProjectAccess?
    /// Syncs in a row that failed for a passing reason: a gateway error (502, 503, 504) or a lost connection. The first
    /// two leave state and message as they were, `ok` without a message for a healthy account, so a short outage neither
    /// looks like a broken account nor hides an error already shown; from the third on the state is `error`. A success
    /// or any other failure sets it back to 0. See ``SyncEngine``.
    public var consecutiveFailures: Int

    public init(
        state: FetchState,
        lastSuccessAt: Date? = nil,
        message: String? = nil,
        projectAccess: ProjectAccess? = nil,
        consecutiveFailures: Int = 0
    ) {
        self.state = state
        self.lastSuccessAt = lastSuccessAt
        self.message = message
        self.projectAccess = projectAccess
        self.consecutiveFailures = consecutiveFailures
    }
}

extension FetchStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, lastSuccessAt, message, projectAccess, consecutiveFailures
    }

    /// A status written by a build that did not count failures yet reads as none in a row. Encoding is synthesized from
    /// the same keys: it always writes `state` and `consecutiveFailures`, and leaves out `lastSuccessAt`, `message` and
    /// `projectAccess` while they are nil.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(FetchState.self, forKey: .state)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        projectAccess = try container.decodeIfPresent(ProjectAccess.self, forKey: .projectAccess)
        consecutiveFailures = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
    }
}

/// Everything the widget needs, written by the app into the App Group container.
public struct Snapshot: Hashable, Sendable {
    /// 2 added ``presetResults`` and ``searchedAccounts``. A snapshot of version 1 has neither and loads as it is,
    /// without a migration.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var fetchedAt: Date
    public var items: [WorkItem]
    public var accountStatus: [UUID: FetchStatus]
    /// The last search per preset and account, for accounts that fetch each preset with its own search. Written in the
    /// order of preset, then account. Read one through ``result(for:account:)``, which applies the selection check.
    public var presetResults: [PresetResult]
    /// Accounts whose items go by ``presetResults``: they fetched through preset searches in the sync that wrote the
    /// snapshot, whatever came of the searches. Every other account fetched all its items, and its results, if it has
    /// any, say nothing about what a preset shows. Readers learn this here and never from the provider kind, because
    /// the widget has no providers. Written in the order of the ids.
    public var searchedAccounts: Set<UUID>

    public init(
        schemaVersion: Int = Snapshot.currentSchemaVersion,
        fetchedAt: Date,
        items: [WorkItem],
        accountStatus: [UUID: FetchStatus] = [:],
        presetResults: [PresetResult] = [],
        searchedAccounts: Set<UUID> = []
    ) {
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.items = items
        self.accountStatus = accountStatus
        self.presetResults = presetResults
        self.searchedAccounts = searchedAccounts
    }
}

extension Snapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, fetchedAt, items, accountStatus, presetResults, searchedAccounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        items = try container.decode([WorkItem].self, forKey: .items)
        let raw = try container.decodeIfPresent([String: FetchStatus].self, forKey: .accountStatus) ?? [:]
        var status: [UUID: FetchStatus] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .accountStatus, in: container,
                    debugDescription: "Account status key '\(key)' is not a UUID"
                )
            }
            status[id] = value
        }
        accountStatus = status
        presetResults = try container.decodeIfPresent([PresetResult].self, forKey: .presetResults) ?? []
        searchedAccounts = Set(try container.decodeIfPresent([UUID].self, forKey: .searchedAccounts) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(items, forKey: .items)
        let raw = Dictionary(uniqueKeysWithValues: accountStatus.map { ($0.key.uuidString, $0.value) })
        try container.encode(raw, forKey: .accountStatus)
        try container.encode(presetResults.sorted(by: PresetResult.precedes), forKey: .presetResults)
        try container.encode(searchedAccounts.sorted { $0.uuidString < $1.uuidString }, forKey: .searchedAccounts)
    }
}

extension Snapshot {
    /// The result of `preset` in `account`, or nil when this pair has none or it was fetched for another selection of
    /// the preset. An edited filter, kinds, scopes or sort make the old items say nothing about the preset, so such a
    /// result reads as never fetched for every reader, until a sync searches the preset again and replaces it. A result
    /// that is returned can still be empty and without ``PresetResult/fetchedAt``, when every search of this selection
    /// failed; its ``PresetResult/failure`` says so.
    public func result(for preset: Preset, account: UUID) -> PresetResult? {
        result(presetID: preset.id, account: account, selection: preset.selectionFingerprint)
    }

    /// The items `preset` shows, before ``FilterEngine`` runs over them. An account in `searchedAccounts` fetches the
    /// preset with a search of its own, so only the items of that pair's result count, and none while it has no
    /// result for the preset's selection. Every other account fetches all its items, and they all stay in, as before
    /// preset results. The items keep the order of ``items``.
    public func items(for preset: Preset, searchedAccounts: Set<UUID>) -> [WorkItem] {
        guard !searchedAccounts.isEmpty else { return items }
        let selection = preset.selectionFingerprint
        var found: [UUID: Set<String>] = [:]
        for account in searchedAccounts {
            found[account] = Set(result(presetID: preset.id, account: account, selection: selection)?.itemIDs ?? [])
        }
        return items.filter { item in
            guard let ids = found[item.accountID] else { return true }
            return ids.contains(item.id)
        }
    }

    private func result(presetID: UUID, account: UUID, selection: String) -> PresetResult? {
        guard let result = presetResults.first(where: { $0.presetID == presetID && $0.accountID == account }),
              result.selection == selection else { return nil }
        return result
    }
}
