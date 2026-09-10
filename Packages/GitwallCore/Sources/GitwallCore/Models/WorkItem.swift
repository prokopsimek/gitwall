import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case github
    case gitlab
}

public enum ItemKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pullRequest
    case issue
}

public enum ReviewState: String, Codable, Sendable, CaseIterable, Hashable {
    case approved
    case changesRequested
    case pending
    case none
}

public enum CIState: String, Codable, Sendable, CaseIterable, Hashable {
    case success
    case failure
    case running
    case none
}

public enum MergeState: String, Codable, Sendable, CaseIterable, Hashable {
    case clean
    case conflict
    case unknown
}

public struct UserRef: Codable, Hashable, Sendable {
    public var login: String
    public var displayName: String?
    public var avatarURL: URL?

    public init(login: String, displayName: String? = nil, avatarURL: URL? = nil) {
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public struct Label: Codable, Hashable, Sendable {
    public var name: String
    public var colorHex: String?

    public init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// Provider-agnostic pull request / merge request / issue.
public struct WorkItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var accountID: UUID
    public var kind: ItemKind
    public var repoFullName: String
    public var number: Int
    public var title: String
    public var url: URL
    public var author: UserRef
    public var createdAt: Date
    /// Last activity on the item. Primary sort key.
    public var updatedAt: Date
    public var isDraft: Bool
    public var labels: [Label]
    public var assignees: [UserRef]
    public var milestone: String?
    public var commentCount: Int
    // Pull requests only; nil for issues.
    public var reviewState: ReviewState?
    public var ciState: CIState?
    public var mergeState: MergeState?
    public var reviewers: [UserRef]
    public var requestedReviewers: [UserRef]
    public var additions: Int?
    public var deletions: Int?

    public init(
        accountID: UUID,
        kind: ItemKind,
        repoFullName: String,
        number: Int,
        title: String,
        url: URL,
        author: UserRef,
        createdAt: Date,
        updatedAt: Date,
        isDraft: Bool = false,
        labels: [Label] = [],
        assignees: [UserRef] = [],
        milestone: String? = nil,
        commentCount: Int = 0,
        reviewState: ReviewState? = nil,
        ciState: CIState? = nil,
        mergeState: MergeState? = nil,
        reviewers: [UserRef] = [],
        requestedReviewers: [UserRef] = [],
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.id = Self.makeID(accountID: accountID, repoFullName: repoFullName, number: number, kind: kind)
        self.accountID = accountID
        self.kind = kind
        self.repoFullName = repoFullName
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.labels = labels
        self.assignees = assignees
        self.milestone = milestone
        self.commentCount = commentCount
        self.reviewState = reviewState
        self.ciState = ciState
        self.mergeState = mergeState
        self.reviewers = reviewers
        self.requestedReviewers = requestedReviewers
        self.additions = additions
        self.deletions = deletions
    }

    public static func makeID(accountID: UUID, repoFullName: String, number: Int, kind: ItemKind) -> String {
        "\(accountID.uuidString)/\(repoFullName)#\(number)/\(kind.rawValue)"
    }
}
