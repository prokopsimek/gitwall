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

public struct FetchStatus: Codable, Hashable, Sendable {
    public var state: FetchState
    public var lastSuccessAt: Date?
    public var message: String?
    /// Nil when the provider has no planning boards or the account has not synced since this was added.
    public var projectAccess: ProjectAccess?

    public init(state: FetchState, lastSuccessAt: Date? = nil, message: String? = nil, projectAccess: ProjectAccess? = nil) {
        self.state = state
        self.lastSuccessAt = lastSuccessAt
        self.message = message
        self.projectAccess = projectAccess
    }
}

/// Everything the widget needs, written by the app into the App Group container.
public struct Snapshot: Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var fetchedAt: Date
    public var items: [WorkItem]
    public var accountStatus: [UUID: FetchStatus]

    public init(
        schemaVersion: Int = Snapshot.currentSchemaVersion,
        fetchedAt: Date,
        items: [WorkItem],
        accountStatus: [UUID: FetchStatus] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.fetchedAt = fetchedAt
        self.items = items
        self.accountStatus = accountStatus
    }
}

extension Snapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, fetchedAt, items, accountStatus
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(items, forKey: .items)
        let raw = Dictionary(uniqueKeysWithValues: accountStatus.map { ($0.key.uuidString, $0.value) })
        try container.encode(raw, forKey: .accountStatus)
    }
}
