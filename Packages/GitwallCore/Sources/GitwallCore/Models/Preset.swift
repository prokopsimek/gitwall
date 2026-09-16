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
    /// Cloud agents open a draft and request a review on it, and cannot mark it ready themselves, so a draft
    /// that explicitly asks for my review counts as waiting for me even when `includeDrafts` is off.
    /// Only applies to presets that filter on ``Relation/reviewRequestedFromMe``.
    public var includeDraftsRequestingMyReview: Bool
    public var labelsAny: [String]
    public var labelsNone: [String]
    /// Author logins, matched case-insensitively and ignoring a trailing `[bot]`.
    public var authorsAny: [String]
    public var authorsNone: [String]
    public var reviewStates: Set<ReviewState>
    public var ciStates: Set<CIState>
    public var mergeStates: Set<MergeState>
    public var updatedWithinDays: Int?
    public var milestone: String?
    public var text: String?
    /// Free-form query in GitHub's search syntax, evaluated locally by ``SearchQuery``. Combines with every
    /// other field through AND. A query Gitwall cannot read matches nothing, so a typo cannot widen a preset.
    public var query: String?

    public init(
        relations: Set<Relation> = [],
        includeDrafts: Bool = true,
        includeDraftsRequestingMyReview: Bool = true,
        labelsAny: [String] = [],
        labelsNone: [String] = [],
        authorsAny: [String] = [],
        authorsNone: [String] = [],
        reviewStates: Set<ReviewState> = [],
        ciStates: Set<CIState> = [],
        mergeStates: Set<MergeState> = [],
        updatedWithinDays: Int? = nil,
        milestone: String? = nil,
        text: String? = nil,
        query: String? = nil
    ) {
        self.relations = relations
        self.includeDrafts = includeDrafts
        self.includeDraftsRequestingMyReview = includeDraftsRequestingMyReview
        self.labelsAny = labelsAny
        self.labelsNone = labelsNone
        self.authorsAny = authorsAny
        self.authorsNone = authorsNone
        self.reviewStates = reviewStates
        self.ciStates = ciStates
        self.mergeStates = mergeStates
        self.updatedWithinDays = updatedWithinDays
        self.milestone = milestone
        self.text = text
        self.query = query
    }

    private enum CodingKeys: String, CodingKey {
        case relations, includeDrafts, includeDraftsRequestingMyReview, labelsAny, labelsNone
        case authorsAny, authorsNone, reviewStates, ciStates, mergeStates, updatedWithinDays, milestone, text
        case query
    }

    /// Every key is optional so a `config.json` written by an older build keeps loading; missing keys fall back
    /// to the defaults above.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            relations: try container.decodeIfPresent(Set<Relation>.self, forKey: .relations) ?? [],
            includeDrafts: try container.decodeIfPresent(Bool.self, forKey: .includeDrafts) ?? true,
            includeDraftsRequestingMyReview:
                try container.decodeIfPresent(Bool.self, forKey: .includeDraftsRequestingMyReview) ?? true,
            labelsAny: try container.decodeIfPresent([String].self, forKey: .labelsAny) ?? [],
            labelsNone: try container.decodeIfPresent([String].self, forKey: .labelsNone) ?? [],
            authorsAny: try container.decodeIfPresent([String].self, forKey: .authorsAny) ?? [],
            authorsNone: try container.decodeIfPresent([String].self, forKey: .authorsNone) ?? [],
            reviewStates: try container.decodeIfPresent(Set<ReviewState>.self, forKey: .reviewStates) ?? [],
            ciStates: try container.decodeIfPresent(Set<CIState>.self, forKey: .ciStates) ?? [],
            mergeStates: try container.decodeIfPresent(Set<MergeState>.self, forKey: .mergeStates) ?? [],
            updatedWithinDays: try container.decodeIfPresent(Int.self, forKey: .updatedWithinDays),
            milestone: try container.decodeIfPresent(String.self, forKey: .milestone),
            text: try container.decodeIfPresent(String.self, forKey: .text),
            query: try container.decodeIfPresent(String.self, forKey: .query)
        )
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
        notifications: Set<NotificationEvent> = [],
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
    /// ``accountDefaults(for:label:pullRequestTerm:showCountInMenuBar:)``. Notifications default to none; the user
    /// switches on what they want.
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
