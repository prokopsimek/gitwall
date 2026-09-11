import Foundation

/// Relationship between the token owner and an item.
public enum Relation: String, Codable, Hashable, Sendable, CaseIterable {
    case authoredByMe
    case reviewRequestedFromMe
    case assignedToMe
}

public enum SortOrder: String, Codable, Hashable, Sendable, CaseIterable {
    case lastActivity
    case newestCreated
    case oldestCreated
}

public enum NotificationEvent: String, Codable, Hashable, Sendable, CaseIterable {
    case newItem
    case reviewRequested
    case approved
    case changesRequested
    case ciFailed
    case merged
    case closed
}

/// Which items of an account a preset looks at. `repositories == nil` means every item of the account.
public struct PresetScope: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var repositories: Set<String>?

    public init(accountID: UUID, repositories: Set<String>? = nil) {
        self.accountID = accountID
        self.repositories = repositories
    }
}

/// Provider-agnostic filter. Empty sets mean "no restriction".
public struct ItemFilter: Codable, Hashable, Sendable {
    public var relations: Set<Relation>
    public var includeDrafts: Bool
    public var labelsAny: [String]
    public var labelsNone: [String]
    public var reviewStates: Set<ReviewState>
    public var ciStates: Set<CIState>
    public var mergeStates: Set<MergeState>
    public var updatedWithinDays: Int?
    public var milestone: String?
    public var text: String?

    public init(
        relations: Set<Relation> = [],
        includeDrafts: Bool = true,
        labelsAny: [String] = [],
        labelsNone: [String] = [],
        reviewStates: Set<ReviewState> = [],
        ciStates: Set<CIState> = [],
        mergeStates: Set<MergeState> = [],
        updatedWithinDays: Int? = nil,
        milestone: String? = nil,
        text: String? = nil
    ) {
        self.relations = relations
        self.includeDrafts = includeDrafts
        self.labelsAny = labelsAny
        self.labelsNone = labelsNone
        self.reviewStates = reviewStates
        self.ciStates = ciStates
        self.mergeStates = mergeStates
        self.updatedWithinDays = updatedWithinDays
        self.milestone = milestone
        self.text = text
    }

    public static let any = ItemFilter()
}

/// A named, user-defined query ("preset"). Widgets and the popover show one preset at a time.
public struct Preset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var icon: String
    /// Empty means every account.
    public var scopes: [PresetScope]
    public var kinds: Set<ItemKind>
    public var filter: ItemFilter
    public var sort: SortOrder
    public var notifications: Set<NotificationEvent>
    public var showCountInMenuBar: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "tray.full",
        scopes: [PresetScope] = [],
        kinds: Set<ItemKind> = [.pullRequest],
        filter: ItemFilter = .any,
        sort: SortOrder = .lastActivity,
        notifications: Set<NotificationEvent> = Set(NotificationEvent.allCases),
        showCountInMenuBar: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.scopes = scopes
        self.kinds = kinds
        self.filter = filter
        self.sort = sort
        self.notifications = notifications
        self.showCountInMenuBar = showCountInMenuBar
    }

    /// Presets shared by all accounts, created with the first account. Per-account presets come from
    /// ``accountDefaults(for:label:pullRequestTerm:showCountInMenuBar:)``. Notifications default to all events.
    public static func defaults() -> [Preset] {
        [
            Preset(
                name: "All open",
                icon: "tray.full",
                kinds: [.pullRequest, .issue]
            ),
        ]
    }

    /// The three presets every account starts with: pull requests assigned to me, issues assigned to me, and pull
    /// requests waiting for my review. Scoped to `account`; ordinary presets that the user can edit or delete.
    /// - Parameters:
    ///   - label: Short account name for the titles, see ``Account/shortLabel(among:)``.
    ///   - pullRequestTerm: The provider's word, "Pull request" or "Merge request".
    public static func accountDefaults(for account: Account, label: String, pullRequestTerm: String, showCountInMenuBar: Bool) -> [Preset] {
        let scope = [PresetScope(accountID: account.id)]
        let plural = pullRequestTerm.lowercased() + "s"
        return [
            Preset(
                name: "\(label) · Assigned \(plural)",
                icon: "arrow.triangle.pull",
                scopes: scope,
                kinds: [.pullRequest],
                filter: ItemFilter(relations: [.assignedToMe])
            ),
            Preset(
                name: "\(label) · Assigned issues",
                icon: "smallcircle.filled.circle",
                scopes: scope,
                kinds: [.issue],
                filter: ItemFilter(relations: [.assignedToMe])
            ),
            Preset(
                name: "\(label) · Waiting for my review",
                icon: "eye",
                scopes: scope,
                kinds: [.pullRequest],
                // A draft is not asking for a review yet.
                filter: ItemFilter(relations: [.reviewRequestedFromMe], includeDrafts: false),
                showCountInMenuBar: showCountInMenuBar
            ),
        ]
    }

    /// Same selection regardless of name, icon, sort and notification choices. Used to avoid adding a default
    /// preset the user already has under another name.
    public func isEquivalent(to other: Preset) -> Bool {
        kinds == other.kinds && filter == other.filter && Set(scopes) == Set(other.scopes)
    }

}
